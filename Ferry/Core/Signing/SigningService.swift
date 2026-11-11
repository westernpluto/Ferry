import Foundation
import Security
import ZSignKit

/// Everything needed to re-sign one package, captured on the main actor.
struct SigningJob: Sendable {
    var package: AppPackage
    var inputURL: URL
    var outputURL: URL
    var plan: SigningPlan
    /// Saved profile ID → its file on disk.
    var profileFiles: [UUID: URL]
    var credentials: PKCS12Vault.Contents
    /// Give every bundle a new, matching CFBundleVersion (see `SigningService.freshBuildNumber`).
    var freshBuildNumber = false
}

enum SigningServiceError: LocalizedError {
    case incompletePlan([String])
    case unreadableProfile(String)

    var errorDescription: String? {
        switch self {
        case .incompletePlan(let bundles):
            return "No matching provisioning profile for: \(bundles.joined(separator: ", "))."
        case .unreadableProfile(let name):
            return "The profile “\(name)” couldn't be read."
        }
    }
}

enum SigningService {
    /// Signs the package and returns the inspected result. Runs off the main thread.
    static func sign(_ job: SigningJob, log: @escaping @Sendable (String, Bool) -> Void) async throws -> AppPackage {
        try await Task.detached(priority: .userInitiated) {
            try signSynchronously(job, log: log)
        }.value
    }

    private static func signSynchronously(_ job: SigningJob, log: @escaping @Sendable (String, Bool) -> Void) throws -> AppPackage {
        guard job.plan.isComplete else {
            throw SigningServiceError.incompletePlan(job.plan.missing.map(\.displayName))
        }

        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("Signing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let key = try writeKeyMaterial(job.credentials, to: work)

        // The iPhone app's profile goes first: zsign falls back to it for anything unmatched.
        let containerPath = job.package.container.path
        let ordered = job.plan.assignments.sorted { lhs, rhs in
            lhs.bundle.path == containerPath && rhs.bundle.path != containerPath
        }
        var profiles: [ZSignProfile] = []
        for (index, assignment) in ordered.enumerated() {
            guard let profileURL = job.profileFiles[assignment.profile.id],
                  let profileData = try? Data(contentsOf: profileURL),
                  let source = try? ProvisioningProfile.entitlements(from: profileData) else {
                throw SigningServiceError.unreadableProfile(assignment.profile.profile.name)
            }
            let entitlements = SigningPlanner.entitlements(
                fromProfileEntitlements: source,
                applicationIdentifier: assignment.applicationIdentifier,
                teamIdentifier: assignment.profile.profile.teamIdentifiers.first
            )
            let entitlementsURL = work.appendingPathComponent("entitlements-\(index).plist")
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
                .write(to: entitlementsURL)
            profiles.append(ZSignProfile(profileURL: profileURL, entitlementsURL: entitlementsURL))
            log("\(assignment.bundle.displayName) → \(assignment.profile.profile.name)", false)
        }

        var bundleVersion: String?
        if job.freshBuildNumber {
            bundleVersion = freshBuildNumber(basedOn: job.package.container.buildVersion)
            log("Build number for this install: \(bundleVersion!)", false)
        }

        try? fileManager.removeItem(at: job.outputURL)
        try ZSigner.signIPA(
            input: job.inputURL,
            output: job.outputURL,
            keyURL: key.keyURL,
            certificateURL: key.certificateURL,
            password: key.password,
            profiles: profiles,
            temporaryDirectory: work,
            bundleVersion: bundleVersion,
            log: log
        )

        let result = try IPAInspector.inspect(url: job.outputURL)
        let size = (try? fileManager.attributesOfItem(atPath: job.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        var signed = job.package
        signed.storedFileName = job.outputURL.lastPathComponent
        signed.fileSize = size
        signed.container = result.container
        signed.watchApps = result.watchApps
        signed.extensions = result.extensions
        return signed
    }

    /// A build number that's higher than the original and than any earlier install from
    /// Ferry: `<original's first number>.<minutes since 2024>`. watchOS can keep an old watch
    /// app when an update arrives with the same build number; this guarantees it changes,
    /// and gives the iPhone app and watch app the same value, as Apple requires.
    static func freshBuildNumber(basedOn original: String, now: Date = Date()) -> String {
        let major = original.split(separator: ".").first.flatMap { Int($0) } ?? 1
        let epoch = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        let minutes = max(1, Int(now.timeIntervalSince(epoch) / 60))
        return "\(major).\(minutes)"
    }

    private struct KeyMaterial {
        var keyURL: URL
        var certificateURL: URL?
        var password: String?
    }

    /// Exports the private key (PEM) and certificate (DER) with the Security framework, which
    /// reads every .p12 format Keychain Access produces. Falls back to handing zsign the .p12.
    private static func writeKeyMaterial(_ credentials: PKCS12Vault.Contents, to folder: URL) throws -> KeyMaterial {
        let identity = try PKCS12Vault.importPKCS12(credentials.p12, password: credentials.password)
        var privateKey: SecKey?
        SecIdentityCopyPrivateKey(identity, &privateKey)

        if let privateKey,
           let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any],
           (attributes[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeRSA as String),
           let der = SecKeyCopyExternalRepresentation(privateKey, nil) as Data?,
           let certificate = PKCS12Vault.certificate(of: identity) {
            let pem = "-----BEGIN RSA PRIVATE KEY-----\n"
                + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                + "\n-----END RSA PRIVATE KEY-----\n"
            let keyURL = folder.appendingPathComponent("key.pem")
            let certificateURL = folder.appendingPathComponent("certificate.der")
            try Data(pem.utf8).write(to: keyURL, options: [.atomic, .completeFileProtection])
            try (SecCertificateCopyData(certificate) as Data).write(to: certificateURL, options: [.atomic, .completeFileProtection])
            return KeyMaterial(keyURL: keyURL, certificateURL: certificateURL, password: nil)
        }

        let p12URL = folder.appendingPathComponent("identity.p12")
        try credentials.p12.write(to: p12URL, options: [.atomic, .completeFileProtection])
        return KeyMaterial(keyURL: p12URL, certificateURL: nil, password: credentials.password)
    }
}
