// Apple TV discovery over Bonjour, ported from iOStoATV.
import Foundation
import Network

/// A Bonjour service advertised by an Apple TV.
struct AppleTVService: Identifiable, Hashable {
    enum Kind { case pairable, paired }

    let name: String
    let kind: Kind
    let endpoint: NWEndpoint
    /// TXT values (`identifier`, `authTag`, ...) for `_remotepairing._tcp`.
    var txt: [String: String] = [:]
    var id: String { "\(kind)-\(name)" }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Browses for the RemotePairing services tvOS 17+ advertises:
/// - `_remotepairing-manual-pairing._tcp` while Settings › Remote App and Devices is open
/// - `_remotepairing._tcp` whenever the TV is on, used once paired
@MainActor
final class BonjourBrowser: ObservableObject {
    static let pairingType = "_remotepairing-manual-pairing._tcp"
    static let pairedType = "_remotepairing._tcp"

    @Published private(set) var pairable: [AppleTVService] = []
    @Published private(set) var paired: [AppleTVService] = []
    /// Set when browsing fails, e.g. Local Network access was denied.
    @Published private(set) var problem: String?

    private var browsers: [NWBrowser] = []

    func start() {
        guard browsers.isEmpty else { return }
        browsers = [
            makeBrowser(type: Self.pairingType, kind: .pairable),
            makeBrowser(type: Self.pairedType, kind: .paired),
        ]
    }

    /// Starts browsing again. Results are kept until fresh ones arrive so the
    /// list doesn't flicker.
    func restart() {
        browsers.forEach { $0.cancel() }
        browsers = []
        problem = nil
        start()
    }

    /// iOS tears down Bonjour browsing while the app is in the background
    /// (NWError -65569 "DefunctConnection"), so start fresh on return.
    func appBecameActive() {
        restart()
    }

    private var pendingRestart: Task<Void, Never>?
    private var consecutiveFailures = 0

    private func handleFailure(_ error: NWError) {
        if Self.isPolicyDenied(error) {
            problem = Self.policyDeniedMessage
            return
        }
        // Transient (e.g. defunct after backgrounding, Wi-Fi change): retry quietly
        // with backoff, and only tell the user if it keeps failing.
        consecutiveFailures += 1
        if consecutiveFailures >= 4 {
            problem = "Can't search the network right now (\(error.localizedDescription)). Check that Wi-Fi is on."
        }
        let delay = min(Double(1 << min(consecutiveFailures, 4)), 15)
        pendingRestart?.cancel()
        pendingRestart = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browsers.forEach { $0.cancel() }
            self.browsers = []
            self.start()
        }
    }

    private func makeBrowser(type: String, kind: AppleTVService.Kind) -> NWBrowser {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services = results.compactMap { r -> AppleTVService? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = r.metadata {
                    for key in ["identifier", "authTag", "ver", "flags"] {
                        if let value = record[key] { txt[key] = value }
                    }
                }
                return AppleTVService(name: name, kind: kind, endpoint: r.endpoint, txt: txt)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                switch kind {
                case .pairable: self?.pairable = services
                case .paired: self?.paired = services
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.consecutiveFailures = 0
                    self.problem = nil
                case let .waiting(error):
                    // Waiting is recoverable on its own; only surface a denied permission.
                    if Self.isPolicyDenied(error) { self.problem = Self.policyDeniedMessage }
                case let .failed(error):
                    self.handleFailure(error)
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        return browser
    }

    nonisolated private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ { return true }
        return false
    }

    nonisolated private static let policyDeniedMessage =
        "Ferry isn't allowed to use the local network. Turn on Local Network for Ferry in Settings › Privacy & Security › Local Network."


    /// Resolves a service to a concrete host and port by briefly connecting to it.
    /// Prefers IPv4; falls back to whatever the system picks (often link-local IPv6).
    nonisolated static func resolve(_ service: AppleTVService) async throws -> AppleTVAddress {
        if let v4 = try? await resolve(service.endpoint, ipv4Only: true, timeout: 4) {
            return v4
        }
        return try await resolve(service.endpoint, ipv4Only: false, timeout: 6)
    }

    nonisolated private static func resolve(_ endpoint: NWEndpoint, ipv4Only: Bool, timeout: TimeInterval) async throws -> AppleTVAddress {
        let params = NWParameters.tcp
        if ipv4Only, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        return try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce(cont, connection: connection)
            let finish: @Sendable (Result<AppleTVAddress, Error>) -> Void = { once.resume($0) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        finish(.success(AppleTVAddress(host: Self.string(for: host), port: port.rawValue)))
                    } else {
                        finish(.failure(AppleTVError(message: "Could not resolve Apple TV address")))
                    }
                case let .failed(error), let .waiting(error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(AppleTVError(message: "Resolve cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(AppleTVError(message: "Timed out finding the Apple TV on the network")))
            }
        }
    }

    nonisolated private static func string(for host: NWEndpoint.Host) -> String {
        switch host {
        case let .name(name, _): return name
        case let .ipv4(addr):
            // Format from raw bytes: the description can carry an interface
            // suffix ("192.168.1.130%en0") that isn't valid for IPv4.
            return addr.rawValue.map { String($0) }.joined(separator: ".")
        case let .ipv6(addr):
            var text = "\(addr)"
            if addr.isLinkLocal, !text.contains("%"), let iface = addr.interface {
                text += "%\(iface.name)"
            }
            return text
        @unknown default: return "\(host)"
        }
    }
}

/// Resumes a continuation exactly once, whichever callback gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppleTVAddress, Error>?
    private let connection: NWConnection

    init(_ continuation: CheckedContinuation<AppleTVAddress, Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(_ result: Result<AppleTVAddress, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return }
        connection.cancel()
        cont.resume(with: result)
    }
}
