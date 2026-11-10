import Foundation
import CZSign

/// Certificates for the app's loopback HTTPS server.
public struct LocalTLSMaterial: Sendable {
    /// Server identity (private key, certificate and root) as PKCS#12.
    public var serverPKCS12: Data
    /// Root CA private key and certificate as PKCS#12, kept to re-issue server certificates.
    public var rootPKCS12: Data
    /// Root CA certificate (DER), to put in the configuration profile the user installs.
    public var rootCertificate: Data
}

public struct LocalTLSError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

public enum LocalTLSGenerator {
    /// Creates a server certificate for `localhost`, `127.0.0.1` and `::1`, signed by a root CA
    /// whose name constraints only allow those names. Pass the previous `rootPKCS12` to keep
    /// the same root, so a profile that's already installed and trusted stays valid.
    /// Both PKCS#12 outputs are protected with `password`.
    public static func generate(reusingRoot rootPKCS12: Data?, password: String, serverValidityDays: Int = 800) throws -> LocalTLSMaterial {
        var result = czsign_local_tls()
        var error = [CChar](repeating: 0, count: 512)
        defer { czsign_free_local_tls(&result) }

        let existing = rootPKCS12 ?? Data()
        let status: Int32 = existing.withUnsafeBytes { raw in
            let base = existing.isEmpty ? nil : raw.bindMemory(to: UInt8.self).baseAddress
            return czsign_make_local_tls(base, Int32(existing.count), password, Int32(serverValidityDays),
                                         &result, &error, Int32(error.count))
        }
        guard status == 0,
              let server = result.server_p12, let root = result.ca_p12, let rootDER = result.ca_der else {
            let message = String(cString: error)
            throw LocalTLSError(message: message.isEmpty ? "Couldn't create the certificate." : message)
        }
        return LocalTLSMaterial(
            serverPKCS12: Data(bytes: server, count: Int(result.server_p12_length)),
            rootPKCS12: Data(bytes: root, count: Int(result.ca_p12_length)),
            rootCertificate: Data(bytes: rootDER, count: Int(result.ca_der_length))
        )
    }
}
