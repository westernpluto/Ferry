import Foundation
import Security
import ZSignKit

/// Creates, stores and checks the HTTPS certificate for the local install server, on device.
enum LocalCertificate {
    static let rootVault = PKCS12Vault(service: "WatchAppInstaller.LocalRootCA", account: "root")
    static let profileFileName = "WatchInstaller-LocalRoot.mobileconfig"
    private static let createdKey = "localServerCertificateCreated"
    /// iOS rejects TLS certificates from user-trusted roots that are valid for more than 825 days.
    static let serverValidityDays = 800

    /// When the current server certificate was generated in the app, if it was.
    static var serverCreatedAt: Date? {
        UserDefaults.standard.object(forKey: createdKey) as? Date
    }

    static var serverExpiresAt: Date? {
        serverCreatedAt?.addingTimeInterval(TimeInterval(serverValidityDays) * 24 * 3600)
    }

    static var hasRoot: Bool { rootVault.load() != nil }

    /// Makes a new server certificate and saves it for the local server.
    /// Keeps the existing root (so its installed profile stays valid) unless `newRoot` is true.
    static func generate(newRoot: Bool = false) throws {
        let existing = newRoot ? nil : rootVault.load()
        let password = existing?.password ?? UUID().uuidString
        let material = try makeMaterial(reusingRoot: existing?.p12, password: password)
        try TLSIdentityStore.save(p12: material.serverPKCS12, password: password)
        try rootVault.save(p12: material.rootPKCS12, password: password)
        UserDefaults.standard.set(Date(), forKey: createdKey)
    }

    static func makeMaterial(reusingRoot root: Data?, password: String) throws -> LocalTLSMaterial {
        try LocalTLSGenerator.generate(reusingRoot: root, password: password, serverValidityDays: serverValidityDays)
    }

    /// Called when the user imports their own server .p12 instead.
    static func forgetGenerated() {
        UserDefaults.standard.removeObject(forKey: createdKey)
    }

    static func rootCertificate() -> SecCertificate? {
        rootVault.loadIdentity().flatMap(PKCS12Vault.certificate(of:))
    }

    /// A configuration profile that installs the root certificate.
    static func configurationProfile() -> Data? {
        guard let root = rootCertificate() else { return nil }
        let der = SecCertificateCopyData(root) as Data
        let profile: [String: Any] = [
            "PayloadContent": [[
                "PayloadCertificateFileName": "WatchInstallerLocalRoot.cer",
                "PayloadContent": der,
                "PayloadDisplayName": "Watch App Installer Local Root",
                "PayloadIdentifier": "com.example.WatchAppInstaller.root.\(UUID().uuidString)",
                "PayloadType": "com.apple.security.root",
                "PayloadUUID": UUID().uuidString,
                "PayloadVersion": 1,
            ]],
            "PayloadDescription": "Lets Watch App Installer serve apps over HTTPS on this iPhone. It only works for localhost and 127.0.0.1.",
            "PayloadDisplayName": "Watch App Installer Local Root",
            "PayloadIdentifier": "com.example.WatchAppInstaller.profile",
            "PayloadType": "Configuration",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Writes the profile to a temporary file, for sharing or saving to Files.
    static func configurationProfileFile() -> URL? {
        guard let data = configurationProfile() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(profileFileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Whether iOS trusts the server certificate for `host`, i.e. the root profile is
    /// installed and full trust is turned on. Doesn't touch the network.
    static func isTrusted(host: String) -> Bool {
        guard let identity = TLSIdentityStore.loadIdentity(),
              let leaf = PKCS12Vault.certificate(of: identity) else { return false }
        var chain: [SecCertificate] = [leaf]
        if let root = rootCertificate() { chain.append(root) }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return false
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
