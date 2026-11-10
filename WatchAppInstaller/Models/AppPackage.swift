import Foundation

/// Metadata about one `.app` bundle inside an IPA.
struct BundleInfo: Codable, Hashable, Sendable {
    /// Path of the bundle inside the archive, ending in `/`.
    var path: String
    var bundleIdentifier: String
    var displayName: String
    var shortVersion: String
    var buildVersion: String
    var minimumOSVersion: String?
    var platformName: String?
    var deviceFamilies: [Int]
    var isWatchApp: Bool
    var companionBundleIdentifier: String?
    var runsIndependently: Bool
    var launchProhibited: Bool
    var hasCodeSignature: Bool
    var profile: ProvisioningProfile?

    var isWatchOSBinary: Bool {
        platformName?.lowercased() == "watchos" || deviceFamilies == [4]
    }

    init(path: String, plist: [String: Any], hasCodeSignature: Bool, profile: ProvisioningProfile?) {
        self.path = path
        bundleIdentifier = plist["CFBundleIdentifier"] as? String ?? "unknown"
        let folderName = path.split(separator: "/").last.map { String($0.dropLast(4)) } ?? "App"
        displayName = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? folderName
        shortVersion = plist["CFBundleShortVersionString"] as? String ?? "1.0"
        buildVersion = plist["CFBundleVersion"] as? String ?? shortVersion
        minimumOSVersion = plist["MinimumOSVersion"] as? String
        platformName = plist["DTPlatformName"] as? String
        deviceFamilies = (plist["UIDeviceFamily"] as? [Any])?.compactMap { value in
            if let int = value as? Int { return int }
            if let string = value as? String { return Int(string) }
            return nil
        } ?? []
        isWatchApp = (plist["WKApplication"] as? Bool ?? false) || (plist["WKWatchKitApp"] as? Bool ?? false)
        companionBundleIdentifier = plist["WKCompanionAppBundleIdentifier"] as? String
        runsIndependently = plist["WKRunsIndependentlyOfCompanionApp"] as? Bool ?? false
        launchProhibited = plist["LSApplicationLaunchProhibited"] as? Bool ?? false
        self.hasCodeSignature = hasCodeSignature
        self.profile = profile
    }
}

/// An imported IPA stored in the app's library.
struct AppPackage: Codable, Identifiable, Hashable {
    var id: UUID
    /// File name of the stored copy inside the library directory.
    var storedFileName: String
    var originalFileName: String
    var importedAt: Date
    var fileSize: Int64
    var container: BundleInfo
    var watchApps: [BundleInfo]

    var title: String { watchApps.first?.displayName ?? container.displayName }

    var issues: [PackageIssue] { PackageValidator.validate(self) }

    var canInstall: Bool { !issues.contains { $0.severity == .error } }
}

struct PackageIssue: Hashable, Identifiable {
    enum Severity: Int, Comparable {
        case info, warning, error
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var severity: Severity
    var message: String
    var id: String { "\(severity.rawValue)-\(message)" }
}
