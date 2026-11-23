import Foundation

/// An app Ferry installed (or found on an Apple TV), and what was installed.
struct InstallRecord: Codable, Identifiable, Hashable {
    enum Destination: Codable, Hashable {
        case iPhone
        case appleTV(id: UUID, name: String)

        var key: String {
            switch self {
            case .iPhone: return "iphone"
            case .appleTV(let id, _): return id.uuidString
            }
        }

        var title: String {
            switch self {
            case .iPhone: return "iPhone"
            case .appleTV(_, let name): return name
            }
        }
    }

    var id = UUID()
    var title: String
    /// The library entry it was installed from, if it came from the library.
    var packageID: UUID?
    /// The app's own bundle ID (as in the library and in sources).
    var originalBundleIdentifier: String
    /// The bundle ID it's installed under (differs when signed with your own bundle IDs).
    var installedBundleIdentifier: String
    var version: String
    /// The app's own build number, not the one Ferry gives each signed install.
    var build: String
    var installedAt: Date?
    /// When the profile it was signed with expires; the app stops opening after that.
    var expiresAt: Date?
    var destination: Destination
    /// True when the device itself reported the app (Apple TV). iPhone records only mean
    /// Ferry handed the app to iOS: iOS doesn't tell apps what's installed.
    var confirmed = false
    var sourceLink: SourceLink?
}

/// How an installed app compares with what's available.
struct InstallStatus: Hashable {
    /// A newer version than the installed one, from a source or the library.
    var availableVersion: String?
    /// The library already has that newer version, so it only needs installing.
    var availableInLibrary = false
    var expired = false
    var expiresSoon = false

    var needsAttention: Bool { availableVersion != nil || expired || expiresSoon }

    var summary: String? {
        if expired { return "Expired. Install again with a current profile." }
        if let availableVersion {
            return availableInLibrary ? "\(availableVersion) is ready to install" : "\(availableVersion) available"
        }
        if expiresSoon { return "Signature expires soon. Install again to renew." }
        return nil
    }

    static func check(
        _ record: InstallRecord,
        library: AppPackage?,
        sourceVersion: AltSource.Version?,
        now: Date = Date()
    ) -> InstallStatus {
        var status = InstallStatus()
        func isNewer(_ version: String, _ build: String?) -> Bool {
            AppVersion.isNewer(version: version, build: build, than: record.version, installedBuild: record.build)
        }
        let libraryNewer = library.map { isNewer($0.container.shortVersion, $0.container.buildVersion) } ?? false
        if let sourceVersion, isNewer(sourceVersion.version, sourceVersion.buildVersion) {
            status.availableVersion = sourceVersion.version
            // Already downloaded if the library's copy is at least as new as the source's.
            if let library, libraryNewer,
               !AppVersion.isNewer(version: sourceVersion.version, build: sourceVersion.buildVersion,
                                   than: library.container.shortVersion, installedBuild: library.container.buildVersion) {
                status.availableInLibrary = true
            }
        } else if let library, libraryNewer {
            status.availableVersion = library.container.shortVersion
            status.availableInLibrary = true
        }
        if let expiresAt = record.expiresAt {
            status.expired = expiresAt <= now
            status.expiresSoon = !status.expired && expiresAt.timeIntervalSince(now) < 7 * 24 * 3600
        }
        return status
    }
}

/// What Ferry has installed where. Persisted in Application Support.
@MainActor
final class InstallHistory: ObservableObject {
    @Published private(set) var records: [InstallRecord] = []

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("installs.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([InstallRecord].self, from: data) {
            records = decoded
        }
    }

    func records(for package: AppPackage) -> [InstallRecord] {
        records.filter { $0.packageID == package.id || $0.originalBundleIdentifier == package.container.bundleIdentifier }
    }

    /// Notes an install Ferry just finished. `original` is the library entry; `installed` is
    /// what was actually installed (after signing, if it was signed).
    func recordInstall(original: AppPackage, installed: AppPackage, destination: InstallRecord.Destination, confirmed: Bool) {
        let expiry = installed.signableBundles.compactMap(\.profile?.expirationDate).min()
        upsert(InstallRecord(
            title: original.title,
            packageID: original.id,
            originalBundleIdentifier: original.container.bundleIdentifier,
            installedBundleIdentifier: installed.container.bundleIdentifier,
            version: original.container.shortVersion,
            build: original.container.buildVersion,
            installedAt: Date(),
            expiresAt: expiry,
            destination: destination,
            confirmed: confirmed,
            sourceLink: original.sourceLink
        ))
    }

    /// The library entry a record belongs to.
    func package(for record: InstallRecord, in packages: [AppPackage]) -> AppPackage? {
        packages.first { $0.id == record.packageID }
            ?? packages.first { $0.container.bundleIdentifier == record.originalBundleIdentifier }
    }

    func status(of record: InstallRecord, packages: [AppPackage], sources: SourceStore) -> InstallStatus {
        InstallStatus.check(
            record,
            library: package(for: record, in: packages),
            sourceVersion: sources.sourceApp(bundleIdentifier: record.originalBundleIdentifier, link: record.sourceLink)?.app.latest
        )
    }

    /// Installed apps with a newer version available or a signature about to run out.
    func needingAttention(packages: [AppPackage], sources: SourceStore) -> [(record: InstallRecord, status: InstallStatus)] {
        records.compactMap { record in
            let result = status(of: record, packages: packages, sources: sources)
            return result.needsAttention ? (record: record, status: result) : nil
        }
    }

    func forget(_ record: InstallRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Brings an Apple TV's records in line with the apps it reports: versions are updated,
    /// apps that were removed from the TV are dropped, and apps that match the library or a
    /// source are added even if something else installed them.
    func reconcile(
        appleTV id: UUID,
        name: String,
        apps: [AppleTVApp],
        packages: [AppPackage],
        overrides: [String: SigningOverride],
        sourceApp: (String) -> (sourceURL: URL, app: AltSource.App)?
    ) {
        let destination = InstallRecord.Destination.appleTV(id: id, name: name)
        var updated = records.filter { $0.destination.key != destination.key }
        let previous = records.filter { $0.destination.key == destination.key }

        for app in apps {
            let version = app.version ?? "0"
            if var record = previous.first(where: { $0.installedBundleIdentifier == app.bundleId }) {
                if record.version != version {
                    // Installed or updated by something else: take the TV's numbers.
                    record.version = version
                    record.build = app.build ?? version
                    record.expiresAt = nil
                }
                record.destination = destination
                record.confirmed = true
                updated.append(record)
                continue
            }
            let package = packages.first { package in
                let original = package.container.bundleIdentifier
                return original == app.bundleId || overrides[original]?.bundleIdentifier(for: original) == app.bundleId
            }
            let source = sourceApp(package?.container.bundleIdentifier ?? app.bundleId)
            guard package != nil || source != nil else { continue }
            updated.append(InstallRecord(
                title: package?.title ?? source?.app.name ?? app.name,
                packageID: package?.id,
                originalBundleIdentifier: package?.container.bundleIdentifier ?? app.bundleId,
                installedBundleIdentifier: app.bundleId,
                version: version,
                build: app.build ?? version,
                installedAt: nil,
                expiresAt: nil,
                destination: destination,
                confirmed: true,
                sourceLink: package?.sourceLink ?? source.map { SourceLink(sourceURL: $0.sourceURL, bundleIdentifier: $0.app.bundleIdentifier) }
            ))
        }
        guard updated != records else { return }
        records = updated
        save()
    }

    /// Drops records for Apple TVs that are no longer paired.
    func pruneAppleTVs(keeping ids: Set<UUID>) {
        let kept = records.filter { record in
            if case .appleTV(let id, _) = record.destination { return ids.contains(id) }
            return true
        }
        guard kept.count != records.count else { return }
        records = kept
        save()
    }

    private func upsert(_ record: InstallRecord) {
        records.removeAll {
            $0.destination.key == record.destination.key
                && ($0.installedBundleIdentifier == record.installedBundleIdentifier
                    || ($0.packageID != nil && $0.packageID == record.packageID))
        }
        records.insert(record, at: 0)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
