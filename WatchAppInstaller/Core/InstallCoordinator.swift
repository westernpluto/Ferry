import Foundation
import UIKit

enum InstallTarget {
    case local(host: String, port: Int)
    case remote(baseURL: String)
}

/// Signs (optionally) and installs an IPA over the air, including the watch app inside it.
@MainActor
final class InstallCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case signing
        case serving
        case waitingForInstaller
        case transferring(Double)
        case readyToUpload
        case handedOff
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .signing, .serving, .waitingForInstaller, .transferring: return true
            default: return false
            }
        }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detail: String?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var exportedFiles: [URL] = []
    @Published private(set) var remoteInstallURL: URL?

    private let server = LocalHTTPSServer()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    init() {
        server.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - Entry point

    /// Signs the package when `signing` is given, then installs it.
    func start(_ package: AppPackage, fileURL: URL, signing: SigningJob?, target: InstallTarget) {
        reset()
        runTask = Task { [weak self] in
            guard let self else { return }
            var package = package
            var fileURL = fileURL

            if let signing {
                self.phase = .signing
                self.append("Signing \(package.title)…")
                do {
                    package = try await SigningService.sign(signing) { message, isError in
                        Task { @MainActor [weak self] in self?.signingLog(message, isError: isError) }
                    }
                    fileURL = signing.outputURL
                } catch {
                    self.fail("Signing failed: \(error.localizedDescription)")
                    return
                }
                guard !Task.isCancelled else { return }
                self.detail = nil
                self.append("Signed.")
                if let problem = package.issues.first(where: { $0.severity == .error }) {
                    self.fail("After signing: \(problem.message)")
                    return
                }
            }

            switch target {
            case .local(let host, let port):
                self.serveLocally(package, fileURL: fileURL, host: host, port: port)
            case .remote(let baseURL):
                self.prepareRemote(package, fileURL: fileURL, baseURL: baseURL)
            }
        }
    }

    // MARK: - Local install

    private func serveLocally(_ package: AppPackage, fileURL: URL, host: String, port: Int) {
        guard let identity = TLSIdentityStore.loadIdentity() else {
            fail("No HTTPS certificate is set up. Add one in Settings › Install Method.")
            return
        }
        guard let port = UInt16(exactly: port), port > 0 else {
            fail("The port must be between 1 and 65535.")
            return
        }

        let prefix = "/\(UUID().uuidString)"
        let hostPart = host.contains(":") ? "[\(host)]" : host
        guard let ipaURL = URL(string: "https://\(hostPart):\(port)\(prefix)/app.ipa"),
              let manifestURL = URL(string: "https://\(hostPart):\(port)\(prefix)/manifest.plist"),
              let installURL = ManifestBuilder.installURL(manifestURL: manifestURL) else {
            fail("Couldn't build the install link for host \(host).")
            return
        }

        do {
            let manifest = try ManifestBuilder.manifest(for: package, ipaURL: ipaURL)
            server.removeAllRoutes()
            server.setRoute("\(prefix)/manifest.plist", .init(contentType: "text/xml", source: .data(manifest)))
            server.setRoute("\(prefix)/app.ipa", .init(contentType: "application/octet-stream", source: .file(fileURL)))
            try server.start(identity: identity, port: port)
        } catch {
            fail(error.localizedDescription)
            return
        }

        append("Serving \(package.title) on this iPhone.")
        phase = .serving
        beginBackgroundTask()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.openInstallLink(installURL)
        }
    }

    // MARK: - Remote install

    private func prepareRemote(_ package: AppPackage, fileURL: URL, baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var base = URL(string: trimmed), base.scheme?.lowercased() == "https", base.host != nil else {
            fail("Enter an https:// address in Settings › Install Method. iOS only installs from HTTPS.")
            return
        }
        if !base.absoluteString.hasSuffix("/") {
            base = URL(string: base.absoluteString + "/") ?? base
        }

        let ipaName = Self.safeFileName(package.title) + ".ipa"
        let manifestURL = base.appendingPathComponent("manifest.plist")

        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Export-\(package.id.uuidString)", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let manifestFile = folder.appendingPathComponent("manifest.plist")
            try ManifestBuilder.manifest(for: package, ipaURL: base.appendingPathComponent(ipaName)).write(to: manifestFile)
            let ipaFile = folder.appendingPathComponent(ipaName)
            try FileManager.default.copyItem(at: fileURL, to: ipaFile)

            exportedFiles = [manifestFile, ipaFile]
            remoteInstallURL = ManifestBuilder.installURL(manifestURL: manifestURL)
            phase = .readyToUpload
            append("Upload manifest.plist and \(ipaName) to \(base.absoluteString), then tap Install.")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func openRemoteInstallLink() {
        guard let url = remoteInstallURL else { return }
        openInstallLink(url)
    }

    // MARK: - Common

    func stop() {
        runTask?.cancel()
        runTask = nil
        stopTask?.cancel()
        stopTask = nil
        server.stop()
        server.removeAllRoutes()
        endBackgroundTask()
        if phase.isBusy { phase = .idle }
    }

    func reset() {
        stop()
        phase = .idle
        detail = nil
        log.removeAll()
        exportedFiles.removeAll()
        remoteInstallURL = nil
    }

    func openWatchApp() {
        // Undocumented URL scheme for the Watch app; iOS may ignore it.
        guard let url = URL(string: "itms-watchs://") else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened {
                self?.append("Couldn't open the Watch app. Open it from the Home Screen.")
            }
        }
    }

    private func openInstallLink(_ url: URL) {
        append("Asking iOS to install…")
        UIApplication.shared.open(url) { [weak self] opened in
            guard let self else { return }
            if opened {
                if self.phase == .serving { self.phase = .waitingForInstaller }
                if self.phase == .readyToUpload { self.phase = .handedOff }
                self.append("Tap Install if iOS asks.")
            } else {
                self.fail("iOS refused the install link.")
            }
        }
    }

    private func signingLog(_ message: String, isError: Bool) {
        let text = message.replacingOccurrences(of: ">>> ", with: "")
        if isError {
            append(text)
        } else {
            detail = text.components(separatedBy: .newlines).first
        }
    }

    private func handle(_ event: LocalHTTPSServer.Event) {
        switch event {
        case .ready:
            break
        case .stopped:
            break
        case .failed(let message):
            fail("Server error: \(message)")
        case .request(_, let path, let status):
            let file = path.split(separator: "/").last.map(String.init) ?? path
            if status >= 400 {
                append("Request for \(file) failed (\(status)).")
            } else if file == "manifest.plist" {
                append("iOS accepted the install.")
            }
        case .transfer(_, let sent, let total):
            guard total > 0 else { return }
            phase = .transferring(Double(sent) / Double(total))
        case .transferFinished:
            phase = .handedOff
            append("Sent to iOS. It installs on your iPhone, then your Apple Watch.")
            scheduleStop(after: 20)
        }
    }

    private func scheduleStop(after seconds: TimeInterval) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.server.stop()
            self?.endBackgroundTask()
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        // iOS backgrounds this app while it installs; keep the server alive meanwhile.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Serve IPA") { [weak self] in
            self?.append("iOS stopped the server early. Large apps may need web-server mode.")
            self?.stop()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func append(_ text: String) {
        log.append(LogLine(text: text))
    }

    private func fail(_ message: String) {
        append(message)
        detail = nil
        phase = .failed(message)
        server.stop()
        endBackgroundTask()
    }

    private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "app" : cleaned
    }
}
