import Foundation
import Security

/// Stores the PKCS#12 identity used by the local HTTPS server in the Keychain.
enum TLSIdentityStore {
    enum StoreError: LocalizedError {
        case wrongPassword
        case importFailed(OSStatus)
        case noIdentity
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "The password for the .p12 file is incorrect."
            case .importFailed(let status): return "The .p12 file could not be imported (error \(status))."
            case .noIdentity: return "The .p12 file does not contain a certificate with a private key."
            case .keychain(let status): return "The identity could not be saved to the Keychain (error \(status))."
            }
        }
    }

    private struct Stored: Codable {
        var p12: Data
        var password: String
    }

    private static let service = "WatchAppInstaller.TLSIdentity"
    private static let account = "local-server"

    static func importPKCS12(_ data: Data, password: String) throws -> SecIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        if status == errSecAuthFailed { throw StoreError.wrongPassword }
        guard status == errSecSuccess else { throw StoreError.importFailed(status) }
        guard let entries = items as? [[String: Any]],
              let entry = entries.first(where: { $0[kSecImportItemIdentity as String] != nil }),
              let value = entry[kSecImportItemIdentity as String] else {
            throw StoreError.noIdentity
        }
        return value as! SecIdentity
    }

    /// Validates and saves the identity. Returns it for immediate use.
    @discardableResult
    static func save(p12: Data, password: String) throws -> SecIdentity {
        let identity = try importPKCS12(p12, password: password)
        let payload = try JSONEncoder().encode(Stored(p12: p12, password: password))

        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return identity
    }

    static func loadIdentity() -> SecIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return try? importPKCS12(stored.p12, password: stored.password)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func summary(of identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
