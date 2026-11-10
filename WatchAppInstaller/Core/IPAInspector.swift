import Foundation
import ZIPFoundation

enum IPAInspectorError: LocalizedError {
    case notAnArchive
    case noPayloadApp
    case missingInfoPlist(String)
    case invalidInfoPlist(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "The file is not a valid IPA (ZIP) archive."
        case .noPayloadApp: return "The IPA does not contain an app in its Payload folder."
        case .missingInfoPlist(let path): return "\(path) is missing its Info.plist."
        case .invalidInfoPlist(let path): return "\(path)Info.plist could not be read."
        }
    }
}

/// Reads bundle metadata and signing information from an IPA without extracting it to disk.
enum IPAInspector {
    struct Result: Sendable {
        var container: BundleInfo
        var watchApps: [BundleInfo]
    }

    static func inspect(url: URL) throws -> Result {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw IPAInspectorError.notAnArchive
        }

        var paths = Set<String>()
        for entry in archive {
            paths.insert(entry.path)
        }

        let rootCandidates = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "Payload", parts[1].hasSuffix(".app") else { return nil }
            return "Payload/\(parts[1])/"
        })
        guard let root = rootCandidates.sorted().first else { throw IPAInspectorError.noPayloadApp }

        let container = try bundle(at: root, archive: archive, paths: paths)

        let watchDir = root + "Watch/"
        let watchRoots = Set(paths.compactMap { path -> String? in
            guard path.hasPrefix(watchDir) else { return nil }
            guard let first = path.dropFirst(watchDir.count).split(separator: "/").first,
                  first.hasSuffix(".app") else { return nil }
            return watchDir + first + "/"
        })

        let watchApps = try watchRoots.sorted().map { try bundle(at: $0, archive: archive, paths: paths) }
        return Result(container: container, watchApps: watchApps)
    }

    static func bundle(at root: String, archive: Archive, paths: Set<String>) throws -> BundleInfo {
        guard let plistData = try read(root + "Info.plist", in: archive) else {
            throw IPAInspectorError.missingInfoPlist(root)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw IPAInspectorError.invalidInfoPlist(root)
        }
        let profile = try read(root + "embedded.mobileprovision", in: archive).flatMap { try? ProvisioningProfile.parse($0) }
        let signed = paths.contains(root + "_CodeSignature/CodeResources")
        return BundleInfo(path: root, plist: plist, hasCodeSignature: signed, profile: profile)
    }

    private static func read(_ path: String, in archive: Archive) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }
}
