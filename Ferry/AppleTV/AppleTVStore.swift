// Paired Apple TVs and the operations on them, ported from iOStoATV's AppModel.
import Combine
import Foundation
import Security
import UIKit

/// An Apple TV we hold a pairing record for. The record itself lives in the Keychain.
struct PairedAppleTV: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var model: String?
    /// Host the TV was reached at while pairing (usually its IPv4 address).
    var pairingHost: String?
    /// Last address the `_remotepairing._tcp` service worked at.
    var lastAddress: AppleTVAddress?
    var info: AppleTVInfo?
    var pairedAt = Date()

    var displayName: String { info?.name ?? name }
}

/// Shown while the bridge waits for the user to type the PIN from the TV.
struct AppleTVPinRequest: Identifiable {
    let id = UUID()
    let deviceName: String
    let respond: (String?) -> Void
}

@MainActor
final class AppleTVStore: ObservableObject {
    @Published private(set) var devices: [PairedAppleTV] = []
    @Published var pinRequest: AppleTVPinRequest?
    /// Apps each Apple TV reported the last time it was asked, by device.
    @Published private(set) var installedApps: [UUID: [AppleTVApp]] = [:]

    let browser = BonjourBrowser()

    /// Addresses verified during this app session, so we don't re-probe for every action.
    private var verified: [UUID: AppleTVAddress] = [:]
    private let storeKey = "appleTVs.v1"
    private var browserChanges: AnyCancellable?

    /// The name this iPhone shows up as on the Apple TV.
    var hostName: String { "Ferry (\(UIDevice.current.name))" }

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([PairedAppleTV].self, from: data) {
            devices = saved
        }
        // Views observe the store; forward discovery changes so they refresh too.
        browserChanges = browser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Starts looking for Apple TVs. Only called once Apple TV features are used, so people
    /// without one never see the Local Network prompt.
    func startBrowsing() {
        browser.start()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func update(_ device: PairedAppleTV) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
            persist()
        }
    }

    func device(_ id: UUID) -> PairedAppleTV? { devices.first { $0.id == id } }

    func isOnline(_ device: PairedAppleTV) -> Bool {
        guard let record = PairingKeychain.load(device.id.uuidString) else { return false }
        return browser.paired.contains { service in
            guard let id = service.txt["identifier"], let tag = service.txt["authTag"] else { return false }
            return AppleTVBridge.serviceMatches(pairing: record, identifier: id, authTag: tag)
        }
    }

    // MARK: Pairing

    func pair(service: AppleTVService) async throws -> PairedAppleTV {
        let address = try await BonjourBrowser.resolve(service)
        return try await pair(at: address, suggestedName: service.name)
    }

    /// Pair by IP when Bonjour can't see the TV. With no port, ask the TV for it.
    func pair(host: String, port: UInt16?) async throws -> PairedAppleTV {
        if let port {
            return try await pair(at: AppleTVAddress(host: host, port: port), suggestedName: host)
        }
        let services: [AppleTVProbedService]
        do {
            services = try await AppleTVBridge.probeHost(host)
        } catch {
            throw AppleTVError(message: "Couldn't ask \(host) for its pairing port (\(error.localizedDescription)). Enter the port manually.")
        }
        guard let service = services.first(where: { $0.serviceType == BonjourBrowser.pairingType })
            ?? services.first(where: { $0.serviceType == BonjourBrowser.pairedType })
        else {
            throw AppleTVError(message: "\(host) didn't answer. Check the address, and make sure the Apple TV is on the Remote App and Devices screen.")
        }
        return try await pair(at: AppleTVAddress(host: host, port: service.port), suggestedName: service.instance)
    }

    func pair(at address: AppleTVAddress, suggestedName: String) async throws -> PairedAppleTV {
        let name = suggestedName
        let (record, peer) = try await AppleTVBridge.pair(address, hostName: hostName) { [weak self] in
            self?.askForPIN(deviceName: name)
        }

        var device = PairedAppleTV(name: peer.name ?? suggestedName, model: peer.model, pairingHost: address.host)
        // Pairing with the same TV again replaces the old entry.
        if let udid = peer.udid, let old = devices.first(where: { $0.info?.udid == udid }) {
            device.id = old.id
            remove(old)
        }
        try PairingKeychain.save(record, for: device.id.uuidString)
        devices.append(device)
        persist()

        // Fill in UDID / tvOS version now if we can; not fatal if the TV is slow to advertise.
        _ = try? await refreshInfo(device.id)
        return self.device(device.id) ?? device
    }

    /// Called from the bridge's background thread; blocks until the user answers.
    nonisolated private func askForPIN(deviceName: String) -> String? {
        final class Box: @unchecked Sendable {
            var value: String?
            var answered = false
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            self.pinRequest = AppleTVPinRequest(deviceName: deviceName) { pin in
                // Main thread only; answer at most once.
                guard !box.answered else { return }
                box.answered = true
                box.value = pin
                done.signal()
            }
        }
        done.wait()
        return box.value
    }

    func remove(_ device: PairedAppleTV) {
        PairingKeychain.delete(device.id.uuidString)
        verified[device.id] = nil
        installedApps[device.id] = nil
        devices.removeAll { $0.id == device.id }
        persist()
    }

    // MARK: Connecting

    private func record(for device: PairedAppleTV) throws -> Data {
        guard let data = PairingKeychain.load(device.id.uuidString) else {
            throw AppleTVError(message: "The pairing for \(device.displayName) is missing. Remove it and pair again.")
        }
        return data
    }

    /// Finds the `_remotepairing._tcp` address for a paired TV. Only addresses that
    /// can belong to this TV are tried, so other Apple TVs never get prompted.
    private func address(for device: PairedAppleTV, record: Data) async throws -> AppleTVAddress {
        if let address = verified[device.id] { return address }

        // Give Bonjour a moment if it's only just started.
        startBrowsing()
        for _ in 0..<20 where browser.paired.isEmpty && device.lastAddress == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        var candidates: [AppleTVAddress] = []
        func add(_ address: AppleTVAddress) { if !candidates.contains(address) { candidates.append(address) } }
        if let last = device.lastAddress { add(last) }

        for service in browser.paired {
            let matches: Bool
            if let identifier = service.txt["identifier"], let tag = service.txt["authTag"] {
                matches = AppleTVBridge.serviceMatches(pairing: record, identifier: identifier, authTag: tag)
            } else {
                matches = false
            }
            guard let address = try? await BonjourBrowser.resolve(service) else { continue }
            if matches || address.host == device.pairingHost || address.host == device.lastAddress?.host {
                add(address)
            }
        }

        guard !candidates.isEmpty else {
            throw AppleTVError(message: "Couldn't find \(device.displayName) on the network. Make sure it's awake and on the same Wi-Fi as this iPhone.")
        }

        var lastError: Error?
        for address in candidates {
            do {
                let info = try await AppleTVBridge.deviceInfo(address, hostName: hostName, pairing: record)
                var updated = self.device(device.id) ?? device
                updated.info = info
                updated.lastAddress = address
                update(updated)
                verified[device.id] = address
                return address
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppleTVError(message: "Couldn't connect to \(device.displayName).")
    }

    /// Runs `body` against the device, re-discovering it once if a cached address fails.
    private func withDevice<T>(_ id: UUID, _ body: (AppleTVAddress, Data) async throws -> T) async throws -> T {
        guard let device = self.device(id) else { throw AppleTVError(message: "Unknown Apple TV") }
        let record = try record(for: device)
        let hadCached = verified[id] != nil
        let current = try await address(for: device, record: record)
        do {
            return try await body(current, record)
        } catch {
            guard hadCached else { throw error }
            verified[id] = nil
            let fresh = try await address(for: device, record: record)
            return try await body(fresh, record)
        }
    }

    @discardableResult
    func refreshInfo(_ id: UUID) async throws -> AppleTVInfo? {
        verified[id] = nil
        _ = try await withDevice(id) { _, _ in () }
        return device(id)?.info
    }

    func listApps(_ id: UUID) async throws -> [AppleTVApp] {
        let apps = try await withDevice(id) { address, record in
            try await AppleTVBridge.listApps(address, hostName: hostName, pairing: record)
        }
        installedApps[id] = apps
        return apps
    }

    /// Asks every paired Apple TV which apps it has. TVs that can't be reached are skipped
    /// (their last answer is kept).
    func refreshInstalledApps() async {
        for device in devices {
            _ = try? await listApps(device.id)
        }
    }

    func install(_ id: UUID, ipa: URL, progress: @escaping (AppleTVProgress) -> Void) async throws {
        guard let device = self.device(id) else { throw AppleTVError(message: "Unknown Apple TV") }
        let record = try record(for: device)
        // No automatic retry here: a half-finished install shouldn't be repeated silently.
        let target = try await address(for: device, record: record)
        do {
            try await AppleTVBridge.install(target, hostName: hostName, pairing: record, ipa: ipa, progress: progress)
        } catch {
            verified[id] = nil
            throw error
        }
    }

    func uninstall(_ id: UUID, bundleId: String) async throws {
        try await withDevice(id) { address, record in
            try await AppleTVBridge.uninstall(address, hostName: hostName, pairing: record, bundleId: bundleId) { _ in }
        }
    }
}

/// Stores Apple TV pairing records (which contain private keys) in the Keychain.
enum PairingKeychain {
    private static let service = "Ferry.AppleTVPairing"

    static func save(_ data: Data, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppleTVError(message: "Couldn't save the pairing to the Keychain (\(status)).")
        }
    }

    static func load(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
