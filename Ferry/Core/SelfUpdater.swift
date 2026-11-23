import Foundation

/// Updates Ferry itself from a source: downloads the new build, signs it with your certificate
/// under the bundle ID and team this copy of Ferry already has, and installs it over itself.
/// Your library, profiles and certificate stay, because the app's identity doesn't change.
@MainActor
final class SelfUpdater: ObservableObject {
    @Published var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Keys.auto) }
    }
    /// The source app Ferry updates from. Nil: the first source app that looks like Ferry.
    @Published var link: SourceLink? {
        didSet { defaults.set(link.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.link) }
    }
    @Published var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Keys.skipped) }
    }
    @Published private(set) var isPreparing = false

    let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let auto = "selfUpdate.automatic"
        static let link = "selfUpdate.link"
        static let skipped = "selfUpdate.skipped"
    }

    init() {
        checksAutomatically = defaults.object(forKey: Keys.auto) as? Bool ?? true
        link = defaults.data(forKey: Keys.link).flatMap { try? JSONDecoder().decode(SourceLink.self, from: $0) }
        skippedVersion = defaults.string(forKey: Keys.skipped)
    }

    var displayVersion: String { build == version ? version : "\(version) (\(build))" }

    /// Source apps that could be Ferry: the same bundle ID as this copy, or named Ferry
    /// (sources list Ferry under its original ID, which your signed copy may not use).
    func candidates(in sources: SourceStore) -> [(sourceURL: URL, app: AltSource.App)] {
        sources.allApps.filter { item in
            let id = item.app.bundleIdentifier.lowercased()
            return id == bundleIdentifier.lowercased()
                || item.app.name.lowercased() == "ferry"
                || id.hasSuffix(".ferry")
        }
    }

    func sourceApp(in sources: SourceStore) -> (sourceURL: URL, app: AltSource.App)? {
        if let link {
            return sources.sourceApp(bundleIdentifier: link.bundleIdentifier, link: link)
        }
        return candidates(in: sources).first
    }

    func availableUpdate(in sources: SourceStore) -> SourceStore.Update? {
        guard let match = sourceApp(in: sources), let latest = match.app.latest,
              AppVersion.isNewer(version: latest.version, build: latest.buildVersion, than: version, installedBuild: build)
        else { return nil }
        return SourceStore.Update(sourceURL: match.sourceURL, app: match.app, version: latest)
    }

    /// Whether to offer the update when Ferry opens.
    func shouldPrompt(for update: SourceStore.Update) -> Bool {
        checksAutomatically && update.version.displayVersion != skippedVersion
    }

    enum UpdateError: LocalizedError {
        case downloadFailed
        case needsCertificate
        case noProfile(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed:
                return "The update couldn't be downloaded."
            case .needsCertificate:
                return "Ferry signs its own updates with your certificate. Add it in Settings › Signing."
            case .noProfile(let id):
                return "None of your profiles covers Ferry's bundle ID (\(id)). Import the profile you installed Ferry with in Settings › Signing."
            }
        }
    }

    /// Downloads the update into the library (replacing any earlier copy of Ferry there), then
    /// signs and installs it. Returns the library entry, for showing install progress.
    func install(
        _ update: SourceStore.Update,
        store: PackageStore,
        sources: SourceStore,
        signing: SigningStore,
        installer: InstallCoordinator
    ) async throws -> AppPackage {
        isPreparing = true
        defer { isPreparing = false }

        guard let package = await sources.download(update.version, of: update.app, from: update.sourceURL, into: store) else {
            throw UpdateError.downloadFailed
        }

        var job: SigningJob?
        if signing.certificate != nil {
            prepareSigning(for: package, signing: signing)
            let plan = signing.plan(for: package)
            guard plan.isComplete else { throw UpdateError.noProfile(bundleIdentifier) }
            // Ferry's own build number stays as published, so it can tell when it's up to date.
            job = signing.job(for: package, input: store.fileURL(for: package),
                              output: store.signedFileURL(for: package), freshBuildNumber: false)
            guard job != nil else { throw UpdateError.needsCertificate }
        } else if !package.canInstall {
            throw UpdateError.needsCertificate
        }

        installer.start(package, fileURL: store.fileURL(for: package), signing: job, target: InstallTarget.iPhoneDefault)
        skippedVersion = nil
        return package
    }

    /// Whether a library app is Ferry (as listed in a source, or this copy's own bundle ID).
    func isFerry(_ package: AppPackage, sources: SourceStore) -> Bool {
        let id = package.container.bundleIdentifier
        return id == bundleIdentifier
            || package.sourceLink.map { link in candidates(in: sources).contains { $0.app.bundleIdentifier == link.bundleIdentifier } } == true
            || candidates(in: sources).contains { $0.app.bundleIdentifier == id }
    }

    /// Signs Ferry the way this copy is signed: the same bundle ID and team, so the new build
    /// replaces this one and keeps its Keychain items (your certificate) and files. Also makes
    /// sure the profile this copy was installed with is available; it always covers that ID.
    func prepareSigning(for package: AppPackage, signing: SigningStore) {
        if let embedded = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: embedded),
           let profile = try? ProvisioningProfile.parse(data),
           !signing.profiles.contains(where: { $0.profile.uuid != nil && $0.profile.uuid == profile.uuid }) {
            signing.importProfiles(from: [embedded])
        }
        var choices = signing.signingOverride(for: package) ?? SigningOverride()
        choices.rebase(package, to: bundleIdentifier)
        if let team = Self.ownTeam { choices.teamIdentifier = team }
        if choices != signing.signingOverride(for: package) {
            signing.setOverride(choices, for: package)
        }
    }

    /// The team in the profile this copy of Ferry was signed with.
    private static var ownTeam: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let profile = try? ProvisioningProfile.parse(data) else { return nil }
        return profile.appIDPrefix
    }
}

extension InstallTarget {
    /// The iPhone install method chosen in Settings › Install Method.
    static var iPhoneDefault: InstallTarget {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: SettingsKey.mode).flatMap(InstallMode.init(rawValue:)) ?? .local
        switch mode {
        case .local:
            let port = defaults.object(forKey: SettingsKey.port) as? Int ?? SettingsDefault.port
            let host = defaults.string(forKey: SettingsKey.host) ?? SettingsDefault.host
            return .local(host: host, port: port)
        case .remote:
            return .remote(baseURL: defaults.string(forKey: SettingsKey.remoteBaseURL) ?? "")
        }
    }
}
