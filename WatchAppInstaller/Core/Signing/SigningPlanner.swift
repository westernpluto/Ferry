import Foundation

/// A provisioning profile saved in the app.
struct StoredProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var fileName: String
    var profile: ProvisioningProfile
    var importedAt: Date
}

/// Which saved profile signs which bundle.
struct SigningPlan: Sendable {
    struct Assignment: Sendable, Hashable {
        var bundle: BundleInfo
        var profile: StoredProfile
        /// `PREFIX.bundle.id`: the concrete App ID the bundle is signed with.
        var applicationIdentifier: String
    }

    var assignments: [Assignment]
    var missing: [BundleInfo]

    var isComplete: Bool { missing.isEmpty && !assignments.isEmpty }
}

enum SigningPlanner {
    /// Chooses, for every bundle, the best usable profile: an exact App ID beats a wildcard,
    /// and a longer wildcard beats a shorter one. Expired, App Store, and profiles that don't
    /// include the certificate are skipped.
    static func plan(
        for package: AppPackage,
        profiles: [StoredProfile],
        certificateFingerprint: String?,
        now: Date = Date()
    ) -> SigningPlan {
        let usable = profiles.filter { stored in
            let profile = stored.profile
            guard profile.allowsDirectInstall, !profile.isExpired(at: now) else { return false }
            if let certificateFingerprint, !profile.allowsCertificate(fingerprint: certificateFingerprint) { return false }
            return true
        }

        var assignments: [SigningPlan.Assignment] = []
        var missing: [BundleInfo] = []
        for bundle in package.signableBundles {
            let candidates = usable.filter { $0.profile.covers(bundleIdentifier: bundle.bundleIdentifier) }
            let best = candidates.max { lhs, rhs in
                rank(lhs.profile) < rank(rhs.profile)
            }
            if let best, let prefix = best.profile.appIDPrefix {
                assignments.append(.init(
                    bundle: bundle,
                    profile: best,
                    applicationIdentifier: "\(prefix).\(bundle.bundleIdentifier)"
                ))
            } else {
                missing.append(bundle)
            }
        }
        return SigningPlan(assignments: assignments, missing: missing)
    }

    private static func rank(_ profile: ProvisioningProfile) -> (Int, Int, Date) {
        let exact = profile.isWildcard ? 0 : 1
        let specificity = profile.bundleIDPattern?.count ?? 0
        return (exact, specificity, profile.expirationDate ?? .distantPast)
    }

    /// Entitlements for one bundle, derived from its profile the way Xcode does it:
    /// the App ID and keychain group become concrete, and wildcard-only values are dropped.
    static func entitlements(
        fromProfileEntitlements source: [String: Any],
        applicationIdentifier: String,
        teamIdentifier: String?
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        let prefix = applicationIdentifier.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""

        for (key, value) in source {
            switch value {
            case let string as String:
                if string == "*" { continue }
                result[key] = string.hasSuffix(".*") ? applicationIdentifier : string
            case let array as [Any]:
                let concrete: [Any] = array.compactMap { element in
                    guard let string = element as? String else { return element }
                    if string == "*" { return nil }
                    return string.hasSuffix(".*") ? applicationIdentifier : string
                }
                if !concrete.isEmpty { result[key] = concrete }
            default:
                result[key] = value
            }
        }

        result["application-identifier"] = applicationIdentifier
        if let teamIdentifier {
            result["com.apple.developer.team-identifier"] = teamIdentifier
        }
        if result["keychain-access-groups"] == nil, !prefix.isEmpty {
            result["keychain-access-groups"] = [applicationIdentifier]
        }
        return result
    }
}
