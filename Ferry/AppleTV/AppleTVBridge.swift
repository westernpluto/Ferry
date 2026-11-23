// Apple TV support, ported from iOStoATV. Swift wrapper over the Rust bridge in
// Packages/ATVBridge (idevice: RemotePairing, CoreDevice tunnel, AFC, InstallationProxy).
import ATVBridge
import Foundation

struct AppleTVError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Where a device service can be reached.
struct AppleTVAddress: Hashable, Codable {
    var host: String
    var port: UInt16
}

enum AppleTVInstallPhase {
    case uploading
    case installing
}

struct AppleTVProgress {
    var phase: AppleTVInstallPhase
    var percent: Int
    var status: String

    /// Overall 0...1, weighting upload and install equally.
    var fraction: Double {
        let p = Double(percent) / 100
        return phase == .uploading ? p * 0.5 : 0.5 + p * 0.5
    }
}

struct AppleTVInfo: Codable, Hashable {
    var udid: String
    var name: String?
    var productType: String?
    var osVersion: String?
    var buildVersion: String?
    var deviceClass: String?
}

struct AppleTVPeer: Codable, Hashable {
    var name: String?
    var model: String?
    var udid: String?
}

struct AppleTVProbedService: Codable, Hashable {
    var serviceType: String
    var instance: String
    var port: UInt16
}

struct AppleTVApp: Codable, Hashable, Identifiable {
    var bundleId: String
    var name: String
    var version: String?
    var id: String { bundleId }
}

struct AppleTVIPAInfo: Codable, Hashable {
    var bundleId: String
    var name: String?
    var version: String?
    var platforms: [String]
    var minimumOS: String?
    var isTvOS: Bool
}

/// Swift wrapper over the Rust bridge. All calls block, so each one runs on a
/// background queue and is exposed as `async`.
enum AppleTVBridge {
    private static let queue = DispatchQueue(label: "ferry.appletv.bridge", qos: .userInitiated, attributes: .concurrent)

    private static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private static func check(_ err: UnsafeMutablePointer<CChar>?) throws {
        guard let err else { return }
        let message = String(cString: err)
        atv_free_string(err)
        throw AppleTVError(message: message)
    }

    private static func take(_ s: UnsafeMutablePointer<CChar>?) -> String {
        guard let s else { return "" }
        defer { atv_free_string(s) }
        return String(cString: s)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Pairing

    /// Pairs with a TV in pairing mode. `pin` is called on a background thread
    /// and may block until the user has typed the code; return nil to cancel.
    static func pair(_ addr: AppleTVAddress, hostName: String, pin: @escaping () -> String?) async throws -> (record: Data, peer: AppleTVPeer) {
        try await run {
            let box = Unmanaged.passRetained(PinBox(pin))
            defer { box.release() }
            var buf: UnsafeMutablePointer<UInt8>?
            var len = 0
            var peerJSON: UnsafeMutablePointer<CChar>?
            try check(atv_pair(addr.host, addr.port, hostName, pinTrampoline, box.toOpaque(), &buf, &len, &peerJSON))
            let peer = (try? decode(AppleTVPeer.self, take(peerJSON))) ?? AppleTVPeer()
            guard let buf else { throw AppleTVError(message: "Pairing returned no data") }
            defer { atv_free_bytes(buf, len) }
            return (Data(bytes: buf, count: len), peer)
        }
    }

    /// Whether a `_remotepairing._tcp` TXT record was published by the TV `pairing` belongs to.
    static func serviceMatches(pairing: Data, identifier: String, authTag: String) -> Bool {
        pairing.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            return atv_service_matches(p.baseAddress, p.count, identifier, authTag) == 1
        }
    }

    // MARK: Paired operations

    static func deviceInfo(_ addr: AppleTVAddress, hostName: String, pairing: Data) async throws -> AppleTVInfo {
        try await run {
            var out: UnsafeMutablePointer<CChar>?
            try pairing.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                try check(atv_device_info(addr.host, addr.port, hostName, p.baseAddress, p.count, &out))
            }
            return try decode(AppleTVInfo.self, take(out))
        }
    }

    static func listApps(_ addr: AppleTVAddress, hostName: String, pairing: Data) async throws -> [AppleTVApp] {
        try await run {
            var out: UnsafeMutablePointer<CChar>?
            try pairing.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                try check(atv_list_apps(addr.host, addr.port, hostName, p.baseAddress, p.count, &out))
            }
            return try decode([AppleTVApp].self, take(out))
        }
    }

    static func install(
        _ addr: AppleTVAddress, hostName: String, pairing: Data, ipa: URL,
        progress: @escaping (AppleTVProgress) -> Void
    ) async throws {
        try await run {
            let box = Unmanaged.passRetained(ProgressBox(progress))
            defer { box.release() }
            try pairing.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                try check(atv_install(addr.host, addr.port, hostName, p.baseAddress, p.count,
                                      ipa.path, progressTrampoline, box.toOpaque()))
            }
        }
    }

    static func uninstall(
        _ addr: AppleTVAddress, hostName: String, pairing: Data, bundleId: String,
        progress: @escaping (AppleTVProgress) -> Void
    ) async throws {
        try await run {
            let box = Unmanaged.passRetained(ProgressBox(progress))
            defer { box.release() }
            try pairing.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                try check(atv_uninstall(addr.host, addr.port, hostName, p.baseAddress, p.count,
                                        bundleId, progressTrampoline, box.toOpaque()))
            }
        }
    }

    /// Asks a host directly which RemotePairing services it has (no multicast needed).
    static func probeHost(_ host: String) async throws -> [AppleTVProbedService] {
        try await run {
            var out: UnsafeMutablePointer<CChar>?
            try check(atv_probe_host(host, &out))
            return try decode([AppleTVProbedService].self, take(out))
        }
    }

    // MARK: Local

    static func inspectIPA(_ url: URL) async throws -> AppleTVIPAInfo {
        try await run {
            var out: UnsafeMutablePointer<CChar>?
            try check(atv_inspect_ipa(url.path, &out))
            return try decode(AppleTVIPAInfo.self, take(out))
        }
    }
}

// MARK: - C callback plumbing

private final class PinBox {
    let provide: () -> String?
    init(_ provide: @escaping () -> String?) { self.provide = provide }
}

private final class ProgressBox {
    let handler: (AppleTVProgress) -> Void
    init(_ handler: @escaping (AppleTVProgress) -> Void) { self.handler = handler }
}

private let pinTrampoline: AtvPinCallback = { ctx, out, cap in
    guard let ctx, let out, cap > 0 else { return }
    let box = Unmanaged<PinBox>.fromOpaque(ctx).takeUnretainedValue()
    let pin = box.provide()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let bytes = Array(pin.utf8.prefix(cap - 1))
    for (i, b) in bytes.enumerated() { out[i] = CChar(bitPattern: b) }
    out[bytes.count] = 0
}

private let progressTrampoline: AtvProgressCallback = { ctx, phase, percent, status in
    guard let ctx else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
    let text = status.map { String(cString: $0) } ?? ""
    box.handler(AppleTVProgress(phase: phase == 0 ? .uploading : .installing, percent: Int(percent), status: text))
}
