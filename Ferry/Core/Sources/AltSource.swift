import Foundation

/// An AltStore-style source: a JSON file that lists apps and where to download each version.
/// The same format is used by AltStore, SideStore, Feather and most other sideloading apps.
/// Decoding is lenient: unknown keys are ignored and a malformed app is skipped, not fatal.
struct AltSource: Codable, Hashable, Sendable {
    var name: String
    var identifier: String?
    var subtitle: String?
    var iconURL: URL?
    var website: URL?
    var apps: [App]

    struct App: Codable, Hashable, Identifiable, Sendable {
        var name: String
        var bundleIdentifier: String
        var developerName: String?
        var subtitle: String?
        var localizedDescription: String?
        var iconURL: URL?
        /// Newest first, as the format specifies.
        var versions: [Version]

        var id: String { bundleIdentifier }
        var latest: Version? { versions.first }
    }

    struct Version: Codable, Hashable, Sendable {
        var version: String
        var buildVersion: String?
        var date: String?
        var localizedDescription: String?
        var downloadURL: URL
        var size: Int64?
        var minOSVersion: String?

        var displayVersion: String {
            guard let buildVersion, !buildVersion.isEmpty, buildVersion != version else { return version }
            return "\(version) (\(buildVersion))"
        }

        /// The release date, if the source gives one in a format we understand.
        var releaseDate: Date? {
            guard let date else { return nil }
            let iso = ISO8601DateFormatter()
            if let parsed = iso.date(from: date) { return parsed }
            iso.formatOptions = [.withFullDate]
            return iso.date(from: String(date.prefix(10)))
        }
    }
}

// MARK: - Lenient decoding

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == AnyKey {
    func string(_ key: String) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: AnyKey(key)) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: AnyKey(key)) {
            return value.rounded() == value ? String(Int64(value)) : String(value)
        }
        return nil
    }

    func url(_ key: String) -> URL? {
        guard let text = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }

    func int64(_ key: String) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: AnyKey(key)) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: AnyKey(key)) { return Int64(value) }
        return string(key).flatMap { Int64($0) }
    }
}

/// Decodes each element on its own so one bad entry doesn't drop the whole list.
private struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension AltSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.string("name") ?? "Source"
        identifier = c.string("identifier")
        subtitle = c.string("subtitle") ?? c.string("description")
        iconURL = c.url("iconURL")
        website = c.url("website")
        let decoded = (try? c.decodeIfPresent([Lossy<App>].self, forKey: AnyKey("apps"))) ?? nil
        apps = (decoded ?? []).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(identifier, forKey: AnyKey("identifier"))
        try c.encodeIfPresent(subtitle, forKey: AnyKey("subtitle"))
        try c.encodeIfPresent(iconURL, forKey: AnyKey("iconURL"))
        try c.encodeIfPresent(website, forKey: AnyKey("website"))
        try c.encode(apps, forKey: AnyKey("apps"))
    }
}

extension AltSource.App {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let bundleIdentifier = c.string("bundleIdentifier"), !bundleIdentifier.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "App without bundleIdentifier"))
        }
        self.bundleIdentifier = bundleIdentifier
        name = c.string("name") ?? bundleIdentifier
        developerName = c.string("developerName")
        subtitle = c.string("subtitle")
        localizedDescription = c.string("localizedDescription")
        iconURL = c.url("iconURL")

        let listed = ((try? c.decodeIfPresent([Lossy<AltSource.Version>].self, forKey: AnyKey("versions"))) ?? nil)?
            .compactMap(\.value) ?? []
        if !listed.isEmpty {
            versions = listed
        } else if let downloadURL = c.url("downloadURL") {
            // Older sources put a single version on the app itself.
            versions = [AltSource.Version(
                version: c.string("version") ?? "1.0",
                buildVersion: nil,
                date: c.string("versionDate"),
                localizedDescription: c.string("versionDescription"),
                downloadURL: downloadURL,
                size: c.int64("size"),
                minOSVersion: c.string("minOSVersion")
            )]
        } else {
            versions = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(bundleIdentifier, forKey: AnyKey("bundleIdentifier"))
        try c.encodeIfPresent(developerName, forKey: AnyKey("developerName"))
        try c.encodeIfPresent(subtitle, forKey: AnyKey("subtitle"))
        try c.encodeIfPresent(localizedDescription, forKey: AnyKey("localizedDescription"))
        try c.encodeIfPresent(iconURL, forKey: AnyKey("iconURL"))
        try c.encode(versions, forKey: AnyKey("versions"))
    }
}

extension AltSource.Version {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let downloadURL = c.url("downloadURL") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Version without downloadURL"))
        }
        self.downloadURL = downloadURL
        version = c.string("version") ?? "1.0"
        buildVersion = c.string("buildVersion")
        date = c.string("date")
        localizedDescription = c.string("localizedDescription")
        size = c.int64("size")
        minOSVersion = c.string("minOSVersion")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(version, forKey: AnyKey("version"))
        try c.encodeIfPresent(buildVersion, forKey: AnyKey("buildVersion"))
        try c.encodeIfPresent(date, forKey: AnyKey("date"))
        try c.encodeIfPresent(localizedDescription, forKey: AnyKey("localizedDescription"))
        try c.encode(downloadURL, forKey: AnyKey("downloadURL"))
        try c.encodeIfPresent(size, forKey: AnyKey("size"))
        try c.encodeIfPresent(minOSVersion, forKey: AnyKey("minOSVersion"))
    }
}

// MARK: - Versions

enum AppVersion {
    /// Whether `candidate` (from a source) is newer than what's installed in the library.
    /// Marketing versions compare numerically (1.10 > 1.9). When they're equal, a build number
    /// from the source decides.
    static func isNewer(version: String, build: String?, than installedVersion: String, installedBuild: String) -> Bool {
        switch version.compare(installedVersion, options: .numeric) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame:
            guard let build, !build.isEmpty else { return false }
            return build.compare(installedBuild, options: .numeric) == .orderedDescending
        }
    }
}
