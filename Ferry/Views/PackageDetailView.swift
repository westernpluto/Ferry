import SwiftUI

struct PackageDetailView: View {
    let package: AppPackage

    @EnvironmentObject private var store: PackageStore
    @EnvironmentObject private var signing: SigningStore
    @EnvironmentObject private var installer: InstallCoordinator
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var appleTV: AppleTVStore
    @AppStorage(SettingsKey.appleTVTarget) private var appleTVTarget = ""
    @AppStorage(SettingsKey.mode) private var mode: InstallMode = .local
    @AppStorage(SettingsKey.port) private var port = SettingsDefault.port
    @AppStorage(SettingsKey.host) private var host = SettingsDefault.host
    @AppStorage(SettingsKey.remoteBaseURL) private var remoteBaseURL = ""

    @State private var showingInstall = false
    @State private var showingSigningSetup = false
    @State private var watchUDID = ""
    @State private var showingOverrides = false
    @State private var showingAppleTVs = false
    @State private var matchMessage: String?

    private var willSign: Bool { signing.signBeforeInstall && signing.certificate != nil }
    private var plan: SigningPlan? { willSign ? signing.plan(for: package) : nil }
    private var update: SourceStore.Update? { sources.update(for: package) }
    private var downloadKey: String { package.sourceLink?.bundleIdentifier ?? package.container.bundleIdentifier }

    /// The Apple TV a tvOS app installs on: the last one used, or the only one paired.
    private var targetAppleTV: PairedAppleTV? {
        appleTV.devices.first { $0.id.uuidString == appleTVTarget } ?? appleTV.devices.first
    }

    /// Why Install is disabled, if it is.
    private var blocker: String? {
        if let structural = package.structuralIssues.first(where: { $0.severity == .error }) {
            return structural.message
        }
        if package.isAppleTVApp && targetAppleTV == nil {
            return "Pair an Apple TV to install this app."
        }
        if let plan {
            if !plan.isComplete {
                let names = plan.missing.map { "\($0.displayName) (\(plan.wantedIdentifier(for: $0)))" }
                return "Add a provisioning profile for: \(names.joined(separator: ", ")), or choose bundle IDs your profiles cover."
            }
        } else if let problem = package.issues.first(where: { $0.severity == .error }) {
            return problem.message
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                header
                installButton
                statusLine
            }
            .listRowSeparator(.hidden)

            if let update {
                updateSection(update)
            }

            if let plan {
                Section {
                    ForEach(plan.assignments, id: \.bundle.path) { assignment in
                        BundleProfileRow(
                            bundle: assignment.bundle,
                            signedIdentifier: assignment.bundleIdentifier,
                            profileName: assignment.profile.profile.name
                        )
                    }
                    ForEach(plan.missing, id: \.path) { bundle in
                        BundleProfileRow(bundle: bundle, signedIdentifier: plan.wantedIdentifier(for: bundle), profileName: nil)
                    }
                    if !plan.isComplete {
                        Button {
                            matchMessage = signing.matchProfiles(for: package)
                                ? nil
                                : "None of your profiles can be matched to this app. Add a profile (a wildcard one covers any bundle ID), or set the bundle IDs yourself."
                        } label: {
                            Label("Match My Profiles", systemImage: "wand.and.stars")
                        }
                    }
                    Button {
                        showingOverrides = true
                    } label: {
                        Label("Bundle IDs & Team…", systemImage: "slider.horizontal.3")
                    }
                } header: {
                    Text("Signing")
                } footer: {
                    if let choices = signing.signingOverride(for: package), !choices.isEmpty {
                        Text(Self.overrideSummary(choices) + " This also applies to updates.")
                    } else {
                        Text("If the app asks for bundle IDs your profiles don't cover, choose ones they do.")
                    }
                }
            }

            let notes = willSign ? package.structuralIssues : package.issues
            if !notes.isEmpty {
                Section("Notes") {
                    ForEach(notes) { IssueRow(issue: $0) }
                }
            }

            Section {
                DisclosureGroup("Details") {
                    ForEach(package.signableBundles, id: \.path) { bundle in
                        BundleDetails(bundle: bundle)
                    }
                    LabeledContent("File", value: package.originalFileName)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: package.fileSize, countStyle: .file))
                }
                if let profile = package.watchApps.first?.profile, !profile.provisionsAllDevices, !willSign {
                    DisclosureGroup("Check an Apple Watch UDID") {
                        TextField("UDID", text: $watchUDID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        if !watchUDID.isEmpty {
                            let included = profile.includesDevice(watchUDID)
                            Label(included ? "In the profile" : "Not in the profile",
                                  systemImage: included ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(included ? .green : .red)
                        }
                    }
                }
            }
        }
        .navigationTitle(package.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingInstall, onDismiss: {
            installer.stop()
            // The signed copy has been handed over; keep only the original IPA.
            store.removeSignedCopy(of: package)
        }) {
            InstallView(package: package)
        }
        .sheet(isPresented: $showingOverrides) {
            NavigationStack {
                SigningOverrideView(package: package)
            }
        }
        .sheet(isPresented: $showingAppleTVs) {
            NavigationStack {
                AppleTVListView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAppleTVs = false }
                        }
                    }
            }
        }
        .alert("Match My Profiles", isPresented: Binding(get: { matchMessage != nil }, set: { if !$0 { matchMessage = nil } })) {
            Button("Choose Bundle IDs") { showingOverrides = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text(matchMessage ?? "")
        }
        .sheet(isPresented: $showingSigningSetup) {
            NavigationStack {
                SigningSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSigningSetup = false }
                        }
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(package.title).font(.title2.bold())
                Text("Version \(package.container.shortVersion) · \(package.isAppleTVApp ? "Apple TV" : package.watchApps.isEmpty ? "iPhone" : "iPhone + Apple Watch")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var installButton: some View {
        VStack(spacing: 8) {
            Button {
                install()
            } label: {
                Label(installTitle, systemImage: package.isAppleTVApp ? "appletv.fill" : "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(blocker != nil || installer.phase.isBusy)

            if package.isAppleTVApp {
                if appleTV.devices.count > 1 {
                    Picker("Apple TV", selection: Binding(
                        get: { targetAppleTV?.id.uuidString ?? "" },
                        set: { appleTVTarget = $0 }
                    )) {
                        ForEach(appleTV.devices) { Text($0.displayName).tag($0.id.uuidString) }
                    }
                    .pickerStyle(.menu)
                } else if appleTV.devices.isEmpty {
                    Button("Pair an Apple TV") { showingAppleTVs = true }
                        .font(.callout.bold())
                }
            }
        }
    }

    private static func overrideSummary(_ choices: SigningOverride) -> String {
        let team = choices.teamIdentifier.map { "team \($0)" }
        let ids = choices.bundleIdentifiers.isEmpty ? nil : "your own bundle IDs"
        return "Signed with " + [ids, team].compactMap { $0 }.joined(separator: " and ") + "."
    }

    private var installTitle: String {
        if package.isAppleTVApp {
            let name = targetAppleTV?.displayName ?? "Apple TV"
            return willSign ? "Sign & Install on \(name)" : "Install on \(name)"
        }
        return willSign ? "Sign & Install" : "Install"
    }

    private func updateSection(_ update: SourceStore.Update) -> some View {
        Section {
            if let progress = sources.downloads[downloadKey] {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading \(update.version.version)…").font(.callout)
                    ProgressView(value: progress)
                }
            } else {
                Button {
                    Task { await sources.download(update.version, of: update.app, from: update.sourceURL, into: store) }
                } label: {
                    Label("Update to \(update.version.displayVersion)", systemImage: "arrow.down.circle")
                }
            }
            if let notes = update.version.localizedDescription, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(6)
            }
        } header: {
            Text("Update Available")
        } footer: {
            Text("Replaces this app's IPA in your library. Then tap \(installTitle) to put it on your device.")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let blocker {
            VStack(alignment: .leading, spacing: 8) {
                Label(blocker, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                if package.structuralIssues.first(where: { $0.severity == .error }) == nil {
                    Button(signing.certificate == nil ? "Set Up Signing" : "Manage Profiles") {
                        showingSigningSetup = true
                    }
                    .font(.callout.bold())
                }
            }
        } else if let certificate = signing.certificate, willSign {
            Label("Signs with \(certificate.name)", systemImage: "signature")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Label("Installs with the developer's signature", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func install() {
        let target: InstallTarget
        if package.isAppleTVApp, let device = targetAppleTV {
            appleTVTarget = device.id.uuidString
            target = .appleTV(device.id)
        } else {
            target = mode == .local ? .local(host: host, port: port) : .remote(baseURL: remoteBaseURL)
        }

        var job: SigningJob?
        if let plan {
            guard let credentials = SigningStore.vault.load() else {
                showingSigningSetup = true
                return
            }
            var files: [UUID: URL] = [:]
            for assignment in plan.assignments {
                files[assignment.profile.id] = signing.fileURL(for: assignment.profile)
            }
            job = SigningJob(
                package: package,
                inputURL: store.fileURL(for: package),
                outputURL: store.signedFileURL(for: package),
                plan: plan,
                profileFiles: files,
                credentials: credentials,
                freshBuildNumber: signing.freshBuildNumber
            )
        }

        installer.start(package, fileURL: store.fileURL(for: package), signing: job, target: target)
        showingInstall = true
    }
}

private struct BundleProfileRow: View {
    let bundle: BundleInfo
    var signedIdentifier: String
    let profileName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: profileName == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(profileName == nil ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.displayName).font(.body)
                Text(signedIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if signedIdentifier != bundle.bundleIdentifier {
                    Text("instead of \(bundle.bundleIdentifier)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(profileName ?? "No matching profile")
                    .font(.caption)
                    .foregroundStyle(profileName == nil ? .red : .secondary)
            }
        }
    }
}

private struct IssueRow: View {
    let issue: PackageIssue

    var body: some View {
        Label {
            Text(issue.message).font(.callout)
        } icon: {
            switch issue.severity {
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            }
        }
    }
}

private struct BundleDetails: View {
    let bundle: BundleInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bundle.displayName).font(.headline)
            detail("Bundle ID", bundle.bundleIdentifier)
            detail("Version", "\(bundle.shortVersion) (\(bundle.buildVersion))")
            if let minimum = bundle.minimumOSVersion {
                detail("Requires", "\(bundle.isWatchOSBinary ? "watchOS" : "iOS") \(minimum)")
            }
            if bundle.isWatchApp {
                detail("Runs without iPhone app", bundle.runsIndependently ? "Yes" : "No")
            }
            if let profile = bundle.profile {
                detail("Profile", "\(profile.name) (\(profile.kind.displayName))")
                if let expiry = profile.expirationDate {
                    detail("Expires", expiry.formatted(date: .abbreviated, time: .omitted))
                }
            } else {
                detail("Profile", "None")
            }
        }
        .padding(.vertical, 4)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading) {
                Text(title).foregroundStyle(.secondary)
                Text(value)
            }
        }
        .font(.caption)
    }
}
