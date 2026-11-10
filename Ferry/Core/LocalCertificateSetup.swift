import Foundation
import UIKit

/// Drives the on-device setup of the local server's HTTPS certificate:
/// generate → install the root profile → turn on full trust.
@MainActor
final class LocalCertificateSetup: ObservableObject {
    enum Status: Equatable {
        case none
        case needsTrust
        case trusted
    }

    @Published private(set) var status: Status = .none
    @Published private(set) var summary: String?
    @Published private(set) var isGenerated = false
    @Published private(set) var isWorking = false
    @Published private(set) var profileFile: URL?
    @Published var message: String?

    private let profileServer = LocalHTTPSServer()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopTask: Task<Void, Never>?

    init() {
        profileServer.onEvent = { [weak self] event in
            if case .request(_, _, let status) = event, status == 200 {
                // Safari has the profile; keep serving briefly in case it asks again.
                self?.scheduleStop(after: 10)
            }
        }
    }

    func refresh(host: String) {
        let identity = TLSIdentityStore.loadIdentity()
        summary = identity.flatMap(TLSIdentityStore.summary(of:))
        isGenerated = LocalCertificate.serverCreatedAt != nil && LocalCertificate.hasRoot
        profileFile = isGenerated ? LocalCertificate.configurationProfileFile() : nil
        guard identity != nil else {
            status = .none
            return
        }
        Task { [weak self] in
            let trusted = await Task.detached { LocalCertificate.isTrusted(host: host) }.value
            self?.status = trusted ? .trusted : .needsTrust
        }
    }

    /// Creates the certificate. Re-uses the existing root unless `newRoot` is true.
    func generate(newRoot: Bool, host: String) {
        isWorking = true
        Task { [weak self] in
            do {
                try await Task.detached { try LocalCertificate.generate(newRoot: newRoot) }.value
            } catch {
                self?.message = error.localizedDescription
            }
            self?.isWorking = false
            self?.refresh(host: host)
        }
    }

    /// Serves the root profile over plain HTTP on the loopback interface and opens it in
    /// Safari, which offers to download it to Settings.
    func openProfileInSafari(port: Int) {
        guard let data = LocalCertificate.configurationProfile() else {
            message = "Generate a certificate first."
            return
        }
        let profilePort = port < 65535 ? port + 1 : port - 1
        guard let nwPort = UInt16(exactly: profilePort),
              let url = URL(string: "http://127.0.0.1:\(profilePort)/\(LocalCertificate.profileFileName)") else { return }

        do {
            profileServer.removeAllRoutes()
            profileServer.setRoute(
                "/\(LocalCertificate.profileFileName)",
                .init(contentType: "application/x-apple-aspen-config", source: .data(data))
            )
            try profileServer.start(identity: nil, port: nwPort)
        } catch {
            message = error.localizedDescription
            return
        }

        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Serve profile") { [weak self] in
            self?.stopServing()
        }
        scheduleStop(after: 120)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            UIApplication.shared.open(url) { opened in
                if !opened {
                    self?.message = "Couldn't open Safari. Use Save Profile to Files instead."
                    self?.stopServing()
                }
            }
        }
    }

    func stopServing() {
        stopTask?.cancel()
        stopTask = nil
        profileServer.stop()
        endBackgroundTask()
    }

    private func scheduleStop(after seconds: TimeInterval) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopServing()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
