import Foundation
import Security

/// Saves a PKCS#12 file and its password in the Keychain (this device only).
struct PKCS12Vault {
    enum VaultError: LocalizedError {
        case wrongPassword
        case importFailed(OSStatus)
        case noIdentity
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "The password for the .p12 file is incorrect."
            case .importFailed(let status): return "The .p12 file couldn't be read (error \(status))."
            case .noIdentity: return "The .p12 file doesn't contain a certificate with its private key."
            case .keychain(let status): return "Couldn't save to the Keychain (error \(status))."
            }
        }
    }

    struct Contents: Codable, Sendable {
        var p12: Data
        var password: String
    }

    let service: String
    let account: String

    static func importPKCS12(_ data: Data, password: String) throws -> SecIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        if status == errSecAuthFailed { throw VaultError.wrongPassword }
        guard status == errSecSuccess else { throw VaultError.importFailed(status) }
        guard let entries = items as? [[String: Any]],
              let entry = entries.first(where: { $0[kSecImportItemIdentity as String] != nil }),
              let value = entry[kSecImportItemIdentity as String] else {
            throw VaultError.noIdentity
        }
        return value as! SecIdentity
    }

    @discardableResult
    func save(p12: Data, password: String) throws -> SecIdentity {
        let identity = try Self.importPKCS12(p12, password: password)
        let payload = try JSONEncoder().encode(Contents(p12: p12, password: password))

        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        return identity
    }

    func load() -> Contents? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    func loadIdentity() -> SecIdentity? {
        guard let contents = load() else { return nil }
        return try? Self.importPKCS12(contents.p12, password: contents.password)
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func certificate(of identity: SecIdentity) -> SecCertificate? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess else { return nil }
        return certificate
    }

    static func summary(of identity: SecIdentity) -> String? {
        certificate(of: identity).flatMap { SecCertificateCopySubjectSummary($0) as String? }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// The TLS identity used by the local HTTPS server.
enum TLSIdentityStore {
    private static let vault = PKCS12Vault(service: "WatchAppInstaller.TLSIdentity", account: "local-server")

    @discardableResult
    static func save(p12: Data, password: String) throws -> SecIdentity {
        try vault.save(p12: p12, password: password)
    }

    static func loadIdentity() -> SecIdentity? { vault.loadIdentity() }
    static func clear() { vault.clear() }
    static func summary(of identity: SecIdentity) -> String? { PKCS12Vault.summary(of: identity) }
}
