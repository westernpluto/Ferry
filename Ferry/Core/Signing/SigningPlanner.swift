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
        /// The bundle ID it's signed with: the original, or the one chosen in a `SigningOverride`.
        var bundleIdentifier: String
        /// `PREFIX.bundle.id`: the concrete App ID the bundle is signed with.
        var applicationIdentifier: String

        var changesBundleIdentifier: Bool { bundleIdentifier != bundle.bundleIdentifier }
    }

    var assignments: [Assignment]
    var missing: [BundleInfo]
    /// Bundle ID each missing bundle would need a profile for (after any override).
    var missingIdentifiers: [String: String] = [:]

    var isComplete: Bool { missing.isEmpty && !assignments.isEmpty }

    /// Original bundle ID → new one, for every bundle signed under a different ID.
    var bundleIdentifierChanges: [String: String] {
        var changes: [String: String] = [:]
        for assignment in assignments where assignment.changesBundleIdentifier {
            changes[assignment.bundle.bundleIdentifier] = assignment.bundleIdentifier
        }
        return changes
    }

    func wantedIdentifier(for bundle: BundleInfo) -> String {
        missingIdentifiers[bundle.path] ?? bundle.bundleIdentifier
    }
}

/// Per-app signing choices, kept by the app's original bundle ID so they also apply to updates.
/// Use them to sign an app under bundle IDs and a team your own profiles cover.
struct SigningOverride: Codable, Hashable, Sendable {
    /// Original bundle ID → bundle ID to sign with. Bundles not listed keep their ID.
    var bundleIdentifiers: [String: String] = [:]
    /// Only use profiles from this team (team ID / App ID prefix).
    var teamIdentifier: String?

    var isEmpty: Bool { bundleIdentifiers.isEmpty && (teamIdentifier ?? "").isEmpty }

    func bundleIdentifier(for original: String) -> String {
        let value = bundleIdentifiers[original]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? original : value
    }

    /// Gives the app `newIdentifier` and moves every bundle under the app's ID along with it:
    /// `com.dev.app` → `com.me.app` turns `com.dev.app.widget` into `com.me.app.widget`.
    /// Bundles with unrelated IDs keep the choice already made for them.
    mutating func rebase(_ package: AppPackage, to newIdentifier: String) {
        let original = package.container.bundleIdentifier
        let target = newIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        for bundle in package.signableBundles {
            let id = bundle.bundleIdentifier
            if id == original {
                bundleIdentifiers[id] = target
            } else if id.hasPrefix(original + ".") {
                bundleIdentifiers[id] = target + String(id.dropFirst(original.count))
            }
        }
        bundleIdentifiers = bundleIdentifiers.filter { !$0.value.isEmpty && $0.key != $0.value }
    }
}

enum SigningPlanner {
    /// Chooses, for every bundle, the best usable profile: an exact App ID beats a wildcard,
    /// and a longer wildcard beats a shorter one. Expired, App Store, and profiles that don't
    /// include the certificate are skipped.
    static func plan(
        for package: AppPackage,
        profiles: [StoredProfile],
        certificateFingerprint: String?,
        override choices: SigningOverride? = nil,
        now: Date = Date()
    ) -> SigningPlan {
        let usable = usableProfiles(profiles, certificateFingerprint: certificateFingerprint, team: choices?.teamIdentifier, now: now)

        var plan = SigningPlan(assignments: [], missing: [])
        for bundle in package.signableBundles {
            let identifier = choices?.bundleIdentifier(for: bundle.bundleIdentifier) ?? bundle.bundleIdentifier
            if let best = bestProfile(for: identifier, in: usable), let prefix = best.profile.appIDPrefix {
                plan.assignments.append(.init(
                    bundle: bundle,
                    profile: best,
                    bundleIdentifier: identifier,
                    applicationIdentifier: "\(prefix).\(identifier)"
                ))
            } else {
                plan.missing.append(bundle)
                plan.missingIdentifiers[bundle.path] = identifier
            }
        }
        return plan
    }

    /// Profiles that can sign at all: not expired, not App Store, made for the certificate,
    /// and (when `team` is set) from that team.
    static func usableProfiles(
        _ profiles: [StoredProfile],
        certificateFingerprint: String?,
        team: String? = nil,
        now: Date = Date()
    ) -> [StoredProfile] {
        let team = team?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return profiles.filter { stored in
            let profile = stored.profile
            guard profile.allowsDirectInstall, !profile.isExpired(at: now) else { return false }
            if let certificateFingerprint, !profile.allowsCertificate(fingerprint: certificateFingerprint) { return false }
            if !team.isEmpty, !profile.teamIdentifiers.contains(team), profile.appIDPrefix != team { return false }
            return true
        }
    }

    static func bestProfile(for bundleIdentifier: String, in profiles: [StoredProfile]) -> StoredProfile? {
        profiles
            .filter { $0.profile.covers(bundleIdentifier: bundleIdentifier) }
            .max { rank($0.profile) < rank($1.profile) }
    }

    /// Picks bundle IDs your profiles cover when the app asks for ones they don't
    /// ("Match My Profiles"). For the app itself it prefers an explicit profile whose App ID
    /// ends like the original (`com.dev.Notes` → `com.me.Notes`), then a wildcard profile
    /// (`com.me.*` → `com.me.Notes`). Extensions move with the app, and any that still have
    /// no profile take an explicit profile whose App ID ends like theirs (`….widget`).
    /// Returns nil when nothing fits.
    static func suggestOverride(
        for package: AppPackage,
        profiles: [StoredProfile],
        certificateFingerprint: String?,
        keeping current: SigningOverride = SigningOverride(),
        now: Date = Date()
    ) -> SigningOverride? {
        let all = usableProfiles(profiles, certificateFingerprint: certificateFingerprint, team: current.teamIdentifier, now: now)
        guard !all.isEmpty else { return nil }
        let original = package.container.bundleIdentifier
        let lastComponent = original.split(separator: ".").last.map(String.init) ?? original

        func explicitIDs(_ list: [StoredProfile]) -> [String] {
            list.compactMap { $0.profile.isWildcard ? nil : $0.profile.bundleIDPattern }
        }

        // The app: an existing match wins, then an explicit App ID ending the same, then a wildcard.
        var containerID: String?
        var team: String?
        let currentID = current.bundleIdentifier(for: original)
        if let profile = bestProfile(for: currentID, in: all) {
            containerID = currentID
            team = profile.profile.appIDPrefix
        } else if let profile = all.first(where: {
            !$0.profile.isWildcard && $0.profile.bundleIDPattern?.split(separator: ".").last.map(String.init)?.lowercased() == lastComponent.lowercased()
        }) {
            containerID = profile.profile.bundleIDPattern
            team = profile.profile.appIDPrefix
        } else if let wildcard = all.filter(\.profile.isWildcard).max(by: { rank($0.profile) < rank($1.profile) }),
                  let pattern = wildcard.profile.bundleIDPattern {
            let base = String(pattern.dropLast()) // "com.me." or "" for "*"
            containerID = base.isEmpty ? original : base + lastComponent
            team = wildcard.profile.appIDPrefix
        }
        guard let containerID else { return nil }

        var result = current
        result.rebase(package, to: containerID)
        // Keep every bundle on one team so the app and its extensions can share data.
        let teamProfiles = all.filter { team == nil || $0.profile.appIDPrefix == team }
        let teams = Set(all.compactMap(\.profile.appIDPrefix))
        if teams.count > 1, let team { result.teamIdentifier = team }

        var used = Set([containerID])
        for bundle in package.signableBundles where bundle.path != package.container.path {
            let wanted = result.bundleIdentifier(for: bundle.bundleIdentifier)
            if bestProfile(for: wanted, in: teamProfiles) != nil {
                used.insert(wanted)
                continue
            }
            let last = bundle.bundleIdentifier.split(separator: ".").last.map(String.init) ?? "extension"
            if let match = explicitIDs(teamProfiles).first(where: { !used.contains($0) && $0.lowercased().hasSuffix("." + last.lowercased()) }) {
                result.bundleIdentifiers[bundle.bundleIdentifier] = match
                used.insert(match)
            } else if bestProfile(for: containerID + "." + last, in: teamProfiles) != nil, !used.contains(containerID + "." + last) {
                // An extension with an unrelated ID goes under the app's ID, where a wildcard covers it.
                result.bundleIdentifiers[bundle.bundleIdentifier] = containerID + "." + last
                used.insert(containerID + "." + last)
            }
        }
        result.bundleIdentifiers = result.bundleIdentifiers.filter { $0.key != $0.value }
        return result
    }

    private static func rank(_ profile: ProvisioningProfile) -> (Int, Int, Date) {
        let exact = profile.isWildcard ? 0 : 1
        let specificity = profile.bundleIDPattern?.count ?? 0
        return (exact, specificity, profile.expirationDate ?? .distantPast)
    }

    /// Entitlements for one bundle, derived from its profile the way Xcode does it:
    /// the App ID and keychain group become concrete, and wildcard-only values are dropped.
    ///
    /// `binaryEntitlements` are the ones the bundle was originally signed with. The keychain
    /// groups it asked for are kept (moved to your team, and to any new bundle ID in
    /// `bundleIdentifierChanges`) as long as the profile allows them. That's what lets an app
    /// and its extensions (a notification service extension, a widget) keep sharing keychain
    /// items such as an account token.
    static func entitlements(
        fromProfileEntitlements source: [String: Any],
        applicationIdentifier: String,
        teamIdentifier: String?,
        binaryEntitlements: [String: Any]? = nil,
        bundleIdentifierChanges: [String: String] = [:]
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
        if let requested = binaryEntitlements?["keychain-access-groups"] as? [String], !prefix.isEmpty {
            let allowed = source["keychain-access-groups"] as? [String] ?? ["\(prefix).*"]
            let groups = keychainGroups(requested, prefix: prefix, allowed: allowed, changes: bundleIdentifierChanges)
            if !groups.isEmpty { result["keychain-access-groups"] = groups }
        }
        if result["keychain-access-groups"] == nil, !prefix.isEmpty {
            result["keychain-access-groups"] = [applicationIdentifier]
        }
        return result
    }

    /// The keychain groups a binary asked for, moved to `prefix` (your team): `OLDTEAM.x` becomes
    /// `TEAM.x`, with `x` changed when it's a renamed bundle ID. Order is kept (the first group
    /// is where new keychain items go). Groups the profile doesn't allow are left out.
    static func keychainGroups(_ requested: [String], prefix: String, allowed: [String], changes: [String: String]) -> [String] {
        func isAllowed(_ group: String) -> Bool {
            allowed.contains { pattern in
                pattern.hasSuffix("*") ? group.hasPrefix(String(pattern.dropLast())) : pattern == group
            }
        }
        var result: [String] = []
        for group in requested {
            var value = group
            if let dot = group.firstIndex(of: "."), group.distance(from: group.startIndex, to: dot) == 10,
               group[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
                let suffix = String(group[group.index(after: dot)...])
                value = "\(prefix).\(changes[suffix] ?? suffix)"
            }
            if isAllowed(value), !result.contains(value) { result.append(value) }
        }
        return result
    }
}
