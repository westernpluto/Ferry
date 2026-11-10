import Foundation

/// Checks whether an IPA can be installed onto an iPhone and its paired Apple Watch.
enum PackageValidator {
    /// - Parameter includeSigning: When false, only problems that re-signing can't fix are returned.
    static func validate(_ package: AppPackage, includeSigning: Bool = true, now: Date = Date()) -> [PackageIssue] {
        var issues: [PackageIssue] = []
        let container = package.container

        if container.isWatchOSBinary {
            issues.append(.init(
                severity: .error,
                message: "This is a bare watchOS app. iOS can only install a watch app that's inside an iPhone app. In Xcode, archive the iPhone (or watch-only stub) target and export that IPA."
            ))
        }

        if package.watchApps.isEmpty {
            issues.append(.init(
                severity: .warning,
                message: "There's no Apple Watch app in this IPA, so it will only install on the iPhone."
            ))
        }

        for watch in package.watchApps {
            if let companion = watch.companionBundleIdentifier, companion != container.bundleIdentifier {
                issues.append(.init(
                    severity: .warning,
                    message: "The watch app names \(companion) as its iPhone app, but the iPhone app is \(container.bundleIdentifier)."
                ))
            }
            if !watch.bundleIdentifier.hasPrefix(container.bundleIdentifier + ".") {
                issues.append(.init(
                    severity: .warning,
                    message: "The watch app's bundle ID (\(watch.bundleIdentifier)) should start with the iPhone app's (\(container.bundleIdentifier))."
                ))
            }
            if !watch.runsIndependently && !container.launchProhibited {
                issues.append(.init(
                    severity: .info,
                    message: "“\(watch.displayName)” needs its iPhone app to work. It isn't marked to run on its own (WKRunsIndependentlyOfCompanionApp)."
                ))
            }
        }

        if container.launchProhibited && !package.watchApps.isEmpty {
            issues.append(.init(severity: .info, message: "Watch-only app: nothing appears on the iPhone Home Screen."))
        }

        if includeSigning {
            issues += signingIssues(for: package, now: now)
        }

        return issues.sorted { $0.severity > $1.severity }
    }

    static func signingIssues(for package: AppPackage, now: Date = Date()) -> [PackageIssue] {
        var issues: [PackageIssue] = []
        let container = package.container

        for bundle in package.signableBundles {
            issues += signingIssues(for: bundle, label: label(for: bundle, in: package), now: now)
        }

        for watch in package.watchApps {
            if let watchTeam = watch.profile?.teamIdentifiers.first,
               let containerTeam = container.profile?.teamIdentifiers.first,
               watchTeam != containerTeam {
                issues.append(.init(
                    severity: .warning,
                    message: "The watch app is signed by team \(watchTeam) but the iPhone app by team \(containerTeam).",
                    isSigning: true
                ))
            }
            if let devices = watch.profile?.provisionedDevices, watch.profile?.provisionsAllDevices == false {
                issues.append(.init(
                    severity: .info,
                    message: "The watch app's profile lists \(devices.count) device(s). Your Apple Watch must be one of them.",
                    isSigning: true
                ))
            }
        }
        return issues
    }

    private static func label(for bundle: BundleInfo, in package: AppPackage) -> String {
        if bundle.path == package.container.path { return "iPhone app" }
        if package.watchApps.contains(where: { $0.path == bundle.path }) { return "watch app “\(bundle.displayName)”" }
        return "extension “\(bundle.displayName)”"
    }

    private static func signingIssues(for bundle: BundleInfo, label: String, now: Date) -> [PackageIssue] {
        var issues: [PackageIssue] = []
        if !bundle.hasCodeSignature {
            issues.append(.init(severity: .error, message: "The \(label) isn't signed.", isSigning: true))
        }
        guard let profile = bundle.profile else {
            issues.append(.init(severity: .error, message: "The \(label) has no provisioning profile.", isSigning: true))
            return issues
        }
        if !profile.allowsDirectInstall {
            issues.append(.init(
                severity: .error,
                message: "The \(label) is signed for the App Store, so it can't be installed directly. Sign it with your own certificate.",
                isSigning: true
            ))
        }
        if profile.isExpired(at: now) {
            issues.append(.init(severity: .error, message: "The \(label)'s profile “\(profile.name)” has expired.", isSigning: true))
        } else if let expiry = profile.expirationDate, expiry.timeIntervalSince(now) < 7 * 24 * 3600 {
            issues.append(.init(
                severity: .warning,
                message: "The \(label)'s profile expires \(expiry.formatted(date: .abbreviated, time: .omitted)).",
                isSigning: true
            ))
        }
        return issues
    }
}
