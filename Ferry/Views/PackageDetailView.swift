import SwiftUI

struct PackageDetailView: View {
    let package: AppPackage

    @EnvironmentObject private var store: PackageStore
    @EnvironmentObject private var signing: SigningStore
    @EnvironmentObject private var installer: InstallCoordinator
    @AppStorage(SettingsKey.mode) private var mode: InstallMode = .local
    @AppStorage(SettingsKey.port) private var port = SettingsDefault.port
    @AppStorage(SettingsKey.host) private var host = SettingsDefault.host
    @AppStorage(SettingsKey.remoteBaseURL) private var remoteBaseURL = ""

    @State private var showingInstall = false
    @State private var showingSigningSetup = false
    @State private var watchUDID = ""

    private var willSign: Bool { signing.signBeforeInstall && signing.certificate != nil }
    private var plan: SigningPlan? { willSign ? signing.plan(for: package) : nil }

    /// Why Install is disabled, if it is.
    private var blocker: String? {
        if let structural = package.structuralIssues.first(where: { $0.severity == .error }) {
            return structural.message
        }
        if let plan {
            if !plan.isComplete {
                let names = plan.missing.map { "\($0.displayName) (\($0.bundleIdentifier))" }
                return "Add a provisioning profile for: \(names.joined(separator: ", "))."
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

            if let plan {
                Section("Signing") {
                    ForEach(plan.assignments, id: \.bundle.path) { assignment in
                        BundleProfileRow(bundle: assignment.bundle, profileName: assignment.profile.profile.name)
                    }
                    ForEach(plan.missing, id: \.path) { bundle in
                        BundleProfileRow(bundle: bundle, profileName: nil)
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
        .sheet(isPresented: $showingInstall, onDismiss: { installer.stop() }) {
            InstallView(package: package)
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
                Text("Version \(package.container.shortVersion) · \(package.watchApps.isEmpty ? "iPhone" : "iPhone + Apple Watch")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var installButton: some View {
        Button {
            install()
        } label: {
            Label(willSign ? "Sign & Install" : "Install", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(blocker != nil || installer.phase.isBusy)
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
        let target: InstallTarget = mode == .local
            ? .local(host: host, port: port)
            : .remote(baseURL: remoteBaseURL)

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
                credentials: credentials
            )
        }

        installer.start(package, fileURL: store.fileURL(for: package), signing: job, target: target)
        showingInstall = true
    }
}

private struct BundleProfileRow: View {
    let bundle: BundleInfo
    let profileName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: profileName == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(profileName == nil ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.displayName).font(.body)
                Text(bundle.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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
