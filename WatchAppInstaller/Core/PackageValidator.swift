import Foundation

/// Checks whether an IPA can be installed onto an iPhone and its paired Apple Watch.
enum PackageValidator {
    static func validate(_ package: AppPackage, now: Date = Date()) -> [PackageIssue] {
        var issues: [PackageIssue] = []
        let container = package.container

        if container.isWatchOSBinary {
            issues.append(.init(
                severity: .error,
                message: "The top-level app is a bare watchOS binary. iOS can only install a watch app that is inside an iOS app. In Xcode, archive the app's iOS target (for a watch-only app this is the generated stub app) and export that IPA."
            ))
        }

        if package.watchApps.isEmpty {
            issues.append(.init(
                severity: .error,
                message: "No watchOS app was found in \(container.path)Watch/. This IPA would only install on the iPhone."
            ))
        }

        issues += signingIssues(for: container, label: "iOS app", now: now)
        for watch in package.watchApps {
            issues += signingIssues(for: watch, label: "watch app “\(watch.displayName)”", now: now)

            if let companion = watch.companionBundleIdentifier, companion != container.bundleIdentifier {
                issues.append(.init(
                    severity: .warning,
                    message: "The watch app names \(companion) as its companion app, but the container app is \(container.bundleIdentifier)."
                ))
            }
            if !watch.bundleIdentifier.hasPrefix(container.bundleIdentifier + ".") {
                issues.append(.init(
                    severity: .warning,
                    message: "The watch app's bundle ID (\(watch.bundleIdentifier)) should start with the iOS app's bundle ID (\(container.bundleIdentifier))."
                ))
            }
            if let watchTeam = watch.profile?.teamIdentifiers.first,
               let containerTeam = container.profile?.teamIdentifiers.first,
               watchTeam != containerTeam {
                issues.append(.init(
                    severity: .warning,
                    message: "The watch app is signed by team \(watchTeam) but the iOS app is signed by team \(containerTeam)."
                ))
            }
            if let devices = watch.profile?.provisionedDevices, watch.profile?.provisionsAllDevices == false {
                issues.append(.init(
                    severity: .info,
                    message: "The watch app's profile lists \(devices.count) device(s). Your Apple Watch's UDID must be one of them."
                ))
            }
        }

        if container.launchProhibited && !package.watchApps.isEmpty {
            issues.append(.init(
                severity: .info,
                message: "This is a watch-only app. Its iOS stub app has no icon on the Home Screen."
            ))
        }

        return issues.sorted { $0.severity > $1.severity }
    }

    private static func signingIssues(for bundle: BundleInfo, label: String, now: Date) -> [PackageIssue] {
        var issues: [PackageIssue] = []
        if !bundle.hasCodeSignature {
            issues.append(.init(severity: .error, message: "The \(label) is not code signed."))
        }
        guard let profile = bundle.profile else {
            issues.append(.init(severity: .error, message: "The \(label) has no embedded provisioning profile."))
            return issues
        }
        if !profile.allowsDirectInstall {
            issues.append(.init(
                severity: .error,
                message: "The \(label) is signed for App Store distribution, so it can only be installed from the App Store or TestFlight. Re-sign it with an Ad Hoc, Development or Enterprise profile."
            ))
        }
        if profile.isExpired(at: now) {
            issues.append(.init(severity: .error, message: "The \(label)'s provisioning profile “\(profile.name)” has expired."))
        } else if let expiry = profile.expirationDate, expiry.timeIntervalSince(now) < 7 * 24 * 3600 {
            issues.append(.init(severity: .warning, message: "The \(label)'s provisioning profile expires on \(expiry.formatted(date: .abbreviated, time: .omitted))."))
        }
        return issues
    }
}
