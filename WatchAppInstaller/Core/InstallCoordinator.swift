import Foundation
import UIKit

/// Drives an over-the-air install of an IPA (and the watch app inside it).
@MainActor
final class InstallCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case serving
        case waitingForInstaller
        case transferring(Double)
        case handedOff
        case failed(String)
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var exportedFiles: [URL] = []
    @Published private(set) var remoteInstallURL: URL?

    private let server = LocalHTTPSServer()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopTask: Task<Void, Never>?

    init() {
        server.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    var isServerRunning: Bool { server.isRunning }

    // MARK: - Local install

    func installLocally(_ package: AppPackage, fileURL: URL, host: String, port: Int) {
        reset()
        guard let identity = TLSIdentityStore.loadIdentity() else {
            fail("No TLS certificate is set up. Import one in Settings first.")
            return
        }
        guard let port = UInt16(exactly: port), port > 0 else {
            fail("The port must be between 1 and 65535.")
            return
        }

        let prefix = "/\(package.id.uuidString)"
        let hostPart = host.contains(":") ? "[\(host)]" : host
        guard let ipaURL = URL(string: "https://\(hostPart):\(port)\(prefix)/app.ipa"),
              let manifestURL = URL(string: "https://\(hostPart):\(port)\(prefix)/manifest.plist"),
              let installURL = ManifestBuilder.installURL(manifestURL: manifestURL) else {
            fail("Could not build the install URLs for host \(host).")
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

        if let summary = TLSIdentityStore.summary(of: identity) {
            append("Using certificate “\(summary)”.")
        }
        append("Serving \(package.title) at \(manifestURL.absoluteString)")
        phase = .serving
        beginBackgroundTask()

        // Give the listener a moment to come up before iOS asks for the manifest.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.openInstallLink(installURL)
        }
    }

    // MARK: - Remote install

    /// Writes `manifest.plist` and the IPA to a folder you can upload to `baseURL`.
    func prepareRemote(_ package: AppPackage, fileURL: URL, baseURL: String) {
        reset()
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var base = URL(string: trimmed), base.scheme?.lowercased() == "https", base.host != nil else {
            fail("Enter an https:// base URL in Settings. iOS only installs apps from HTTPS servers.")
            return
        }
        if !base.absoluteString.hasSuffix("/") {
            base = URL(string: base.absoluteString + "/") ?? base
        }

        let ipaName = Self.safeFileName(package.title) + ".ipa"
        let ipaURL = base.appendingPathComponent(ipaName)
        let manifestURL = base.appendingPathComponent("manifest.plist")

        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Export-\(package.id.uuidString)", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let manifestFile = folder.appendingPathComponent("manifest.plist")
            try ManifestBuilder.manifest(for: package, ipaURL: ipaURL).write(to: manifestFile)
            let ipaFile = folder.appendingPathComponent(ipaName)
            try FileManager.default.copyItem(at: fileURL, to: ipaFile)

            exportedFiles = [manifestFile, ipaFile]
            remoteInstallURL = ManifestBuilder.installURL(manifestURL: manifestURL)
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
        stopTask?.cancel()
        stopTask = nil
        server.stop()
        server.removeAllRoutes()
        endBackgroundTask()
        if case .failed = phase { return }
        if phase != .handedOff { phase = .idle }
    }

    func reset() {
        stop()
        phase = .idle
        log.removeAll()
        exportedFiles.removeAll()
        remoteInstallURL = nil
    }

    func openWatchApp() {
        // Undocumented URL scheme that opens the Watch app. It may be ignored on some iOS versions.
        guard let url = URL(string: "itms-watchs://") else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened {
                self?.append("Could not open the Watch app automatically. Open it from the Home Screen.")
            }
        }
    }

    private func openInstallLink(_ url: URL) {
        append("Asking iOS to install…")
        UIApplication.shared.open(url) { [weak self] opened in
            guard let self else { return }
            if opened {
                if case .serving = self.phase { self.phase = .waitingForInstaller }
                if self.remoteInstallURL != nil { self.phase = .handedOff }
                self.append("iOS accepted the install request. Confirm the “Install” prompt if one appears.")
            } else {
                self.fail("iOS refused to open the install link.")
            }
        }
    }

    private func handle(_ event: LocalHTTPSServer.Event) {
        switch event {
        case .ready(let port):
            append("Server listening on port \(port).")
        case .stopped:
            append("Server stopped.")
        case .failed(let message):
            fail("Server error: \(message)")
        case .request(let method, let path, let status):
            append("\(method) \(path.split(separator: "/").last ?? "") → \(status)")
            if status == 404 || status >= 500 {
                append("If iOS never requests the manifest, check that your root certificate is trusted in Settings › General › About › Certificate Trust Settings.")
            }
        case .transfer(_, let sent, let total):
            guard total > 0 else { return }
            phase = .transferring(Double(sent) / Double(total))
        case .transferFinished:
            phase = .handedOff
            append("The IPA was sent to iOS. Installation continues on the iPhone, then on your Apple Watch.")
            scheduleStop(after: 20)
        }
    }

    private func scheduleStop(after seconds: TimeInterval) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        // iOS moves this app to the background while it installs, so keep the server alive.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Serve IPA") { [weak self] in
            self?.append("iOS ended background time for the server.")
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
