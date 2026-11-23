import Foundation
import Security

/// Your signing certificate (.p12) and provisioning profiles.
@MainActor
final class SigningStore: ObservableObject {
    struct CertificateInfo: Equatable {
        var name: String
        var fingerprint: String
    }

    @Published private(set) var certificate: CertificateInfo?
    @Published private(set) var profiles: [StoredProfile] = []
    @Published var signBeforeInstall: Bool {
        didSet { UserDefaults.standard.set(signBeforeInstall, forKey: Self.signKey) }
    }
    /// Give each signed install a new build number (helps the Apple Watch pick up updates).
    @Published var freshBuildNumber: Bool {
        didSet { UserDefaults.standard.set(freshBuildNumber, forKey: Self.freshBuildKey) }
    }

    /// Per-app bundle ID / team choices, keyed by the app's original bundle ID.
    @Published private(set) var overrides: [String: SigningOverride] = [:]

    nonisolated static let vault = PKCS12Vault(service: "Ferry.SigningIdentity", account: "developer")
    private static let signKey = "signBeforeInstall"
    private static let freshBuildKey = "freshBuildNumber"

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("profiles.json") }
    private var overridesURL: URL { directory.appendingPathComponent("overrides.json") }

    var isReady: Bool { certificate != nil && !profiles.isEmpty }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Profiles", isDirectory: true)
        self.directory = base
        signBeforeInstall = UserDefaults.standard.object(forKey: Self.signKey) as? Bool ?? true
        freshBuildNumber = UserDefaults.standard.object(forKey: Self.freshBuildKey) as? Bool ?? true
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        loadProfiles()
        loadOverrides()
        refreshCertificate()
    }

    // MARK: Certificate

    func importCertificate(p12: Data, password: String) throws {
        let identity = try Self.vault.save(p12: p12, password: password)
        certificate = Self.info(for: identity)
    }

    func removeCertificate() {
        Self.vault.clear()
        certificate = nil
    }

    private func refreshCertificate() {
        certificate = Self.vault.loadIdentity().flatMap(Self.info(for:))
    }

    private static func info(for identity: SecIdentity) -> CertificateInfo? {
        guard let certificate = PKCS12Vault.certificate(of: identity) else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        let name = SecCertificateCopySubjectSummary(certificate) as String? ?? "Certificate"
        return CertificateInfo(name: name, fingerprint: ProvisioningProfile.fingerprint(of: der))
    }

    // MARK: Profiles

    /// Imports `.mobileprovision` files. Returns a message for each file that couldn't be added.
    @discardableResult
    func importProfiles(from urls: [URL]) -> [String] {
        var problems: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let profile = try ProvisioningProfile.parse(data)
                if let uuid = profile.uuid, let existing = profiles.first(where: { $0.profile.uuid == uuid }) {
                    deleteProfile(existing)
                }
                let id = UUID()
                let fileName = "\(id.uuidString).mobileprovision"
                try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                profiles.append(StoredProfile(id: id, fileName: fileName, profile: profile, importedAt: Date()))
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        profiles.sort { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }
        saveProfiles()
        return problems
    }

    func deleteProfile(_ stored: StoredProfile) {
        try? FileManager.default.removeItem(at: fileURL(for: stored))
        profiles.removeAll { $0.id == stored.id }
        saveProfiles()
    }

    func fileURL(for stored: StoredProfile) -> URL {
        directory.appendingPathComponent(stored.fileName)
    }

    func plan(for package: AppPackage) -> SigningPlan {
        SigningPlanner.plan(
            for: package,
            profiles: profiles,
            certificateFingerprint: certificate?.fingerprint,
            override: signingOverride(for: package)
        )
    }

    // MARK: Per-app bundle IDs and team

    func signingOverride(for package: AppPackage) -> SigningOverride? {
        overrides[package.container.bundleIdentifier]
    }

    func setOverride(_ value: SigningOverride?, for package: AppPackage) {
        let key = package.container.bundleIdentifier
        if let value, !value.isEmpty {
            overrides[key] = value
        } else {
            overrides[key] = nil
        }
        saveOverrides()
    }

    /// Chooses bundle IDs (and a team) that the saved profiles cover. Returns false if none fit.
    @discardableResult
    func matchProfiles(for package: AppPackage) -> Bool {
        guard let suggestion = SigningPlanner.suggestOverride(
            for: package,
            profiles: profiles,
            certificateFingerprint: certificate?.fingerprint,
            keeping: signingOverride(for: package) ?? SigningOverride()
        ) else { return false }
        setOverride(suggestion, for: package)
        return true
    }

    /// Teams that have at least one usable profile, for the team picker.
    var teams: [(id: String, name: String)] {
        var seen: [String: String] = [:]
        for stored in SigningPlanner.usableProfiles(profiles, certificateFingerprint: certificate?.fingerprint) {
            guard let id = stored.profile.appIDPrefix else { continue }
            seen[id] = seen[id] ?? stored.profile.teamName ?? id
        }
        return seen.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: overridesURL),
              let decoded = try? JSONDecoder().decode([String: SigningOverride].self, from: data) else { return }
        overrides = decoded
    }

    private func saveOverrides() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        try? data.write(to: overridesURL, options: .atomic)
    }

    /// Whether a profile can be used with the imported certificate.
    func matchesCertificate(_ stored: StoredProfile) -> Bool {
        guard let fingerprint = certificate?.fingerprint else { return true }
        return stored.profile.allowsCertificate(fingerprint: fingerprint)
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([StoredProfile].self, from: data) else { return }
        profiles = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
