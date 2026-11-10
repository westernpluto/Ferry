import CryptoKit
import Foundation

/// A decoded `embedded.mobileprovision`.
///
/// Provisioning profiles are CMS (PKCS#7) signed blobs whose payload is a plain
/// XML property list, so the plist can be pulled straight out of the bytes
/// without a full CMS decoder.
struct ProvisioningProfile: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case development
        case adHoc
        case enterprise
        case appStore

        var displayName: String {
            switch self {
            case .development: return "Development"
            case .adHoc: return "Ad Hoc"
            case .enterprise: return "Enterprise (In-House)"
            case .appStore: return "App Store / TestFlight"
            }
        }
    }

    var name: String
    var uuid: String?
    var teamName: String?
    var teamIdentifiers: [String]
    var appIDName: String?
    var applicationIdentifier: String?
    var creationDate: Date?
    var expirationDate: Date?
    var provisionedDevices: [String]?
    var provisionsAllDevices: Bool
    var getTaskAllow: Bool
    var platforms: [String]
    /// SHA-256 fingerprints (lowercase hex) of the signing certificates the profile allows.
    var certificateFingerprints: [String]?

    /// The part of the application identifier before the bundle ID (normally the team ID).
    var appIDPrefix: String? {
        guard let applicationIdentifier, let dot = applicationIdentifier.firstIndex(of: ".") else { return teamIdentifiers.first }
        return String(applicationIdentifier[..<dot])
    }

    /// The bundle ID pattern this profile covers, such as `com.example.app` or `com.example.*`.
    var bundleIDPattern: String? {
        guard let applicationIdentifier, let dot = applicationIdentifier.firstIndex(of: ".") else { return nil }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }

    var isWildcard: Bool { bundleIDPattern?.hasSuffix("*") ?? false }

    /// Whether the profile's App ID covers the given bundle ID.
    func covers(bundleIdentifier: String) -> Bool {
        guard let pattern = bundleIDPattern else { return false }
        if pattern.hasSuffix("*") {
            return bundleIdentifier.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == bundleIdentifier
    }

    func allowsCertificate(fingerprint: String) -> Bool {
        guard let certificateFingerprints else { return true }
        return certificateFingerprints.contains(fingerprint.lowercased())
    }

    var kind: Kind {
        if provisionsAllDevices { return .enterprise }
        if provisionedDevices != nil { return getTaskAllow ? .development : .adHoc }
        return .appStore
    }

    /// Whether this kind of profile can be installed with an over-the-air link.
    var allowsDirectInstall: Bool { kind != .appStore }

    func isExpired(at date: Date = Date()) -> Bool {
        guard let expirationDate else { return false }
        return expirationDate <= date
    }

    /// Whether the given device UDID is allowed to run apps signed with this profile.
    func includesDevice(_ udid: String) -> Bool {
        if provisionsAllDevices { return true }
        let wanted = Self.normalize(udid)
        guard !wanted.isEmpty else { return false }
        return (provisionedDevices ?? []).contains { Self.normalize($0) == wanted }
    }

    private static func normalize(_ udid: String) -> String {
        udid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    enum ParseError: LocalizedError {
        case noPropertyList
        case invalidPropertyList

        var errorDescription: String? {
            switch self {
            case .noPropertyList: return "The provisioning profile does not contain a property list."
            case .invalidPropertyList: return "The provisioning profile's property list could not be read."
            }
        }
    }

    static func propertyList(from data: Data) throws -> [String: Any] {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
        else { throw ParseError.noPropertyList }

        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            throw ParseError.invalidPropertyList
        }
        return plist
    }

    static func parse(_ data: Data) throws -> ProvisioningProfile {
        ProvisioningProfile(plist: try propertyList(from: data))
    }

    /// The profile's `Entitlements` dictionary.
    static func entitlements(from data: Data) throws -> [String: Any] {
        try propertyList(from: data)["Entitlements"] as? [String: Any] ?? [:]
    }

    static func fingerprint(of certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    init(plist: [String: Any]) {
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        name = plist["Name"] as? String ?? "Unnamed profile"
        uuid = plist["UUID"] as? String
        teamName = plist["TeamName"] as? String
        teamIdentifiers = plist["TeamIdentifier"] as? [String] ?? []
        appIDName = plist["AppIDName"] as? String
        applicationIdentifier = entitlements["application-identifier"] as? String
        creationDate = plist["CreationDate"] as? Date
        expirationDate = plist["ExpirationDate"] as? Date
        provisionedDevices = plist["ProvisionedDevices"] as? [String]
        provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        getTaskAllow = entitlements["get-task-allow"] as? Bool ?? false
        platforms = plist["Platform"] as? [String] ?? []
        certificateFingerprints = (plist["DeveloperCertificates"] as? [Data])?.map(Self.fingerprint(of:))
    }
}
