import SwiftUI

struct PackageDetailView: View {
    let package: AppPackage

    @EnvironmentObject private var store: PackageStore
    @EnvironmentObject private var installer: InstallCoordinator
    @AppStorage(SettingsKey.mode) private var mode: InstallMode = .local
    @AppStorage(SettingsKey.port) private var port = SettingsDefault.port
    @AppStorage(SettingsKey.host) private var host = SettingsDefault.host
    @AppStorage(SettingsKey.remoteBaseURL) private var remoteBaseURL = ""

    @State private var showingInstall = false
    @State private var watchUDID = ""

    var body: some View {
        List {
            Section {
                Button {
                    startInstall()
                } label: {
                    Label("Install on iPhone & Apple Watch", systemImage: "arrow.down.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!package.canInstall)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Method: \(mode.title). Change it in Settings.")
            }

            if !package.issues.isEmpty {
                Section("Checks") {
                    ForEach(package.issues) { issue in
                        IssueRow(issue: issue)
                    }
                }
            }

            ForEach(package.watchApps, id: \.path) { watch in
                BundleSection(title: "watchOS App", bundle: watch)
            }
            BundleSection(title: "iOS Container App", bundle: package.container)

            if let profile = package.watchApps.first?.profile ?? package.container.profile,
               !profile.provisionsAllDevices {
                Section {
                    TextField("Apple Watch UDID", text: $watchUDID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if !watchUDID.isEmpty {
                        let included = profile.includesDevice(watchUDID)
                        Label(
                            included ? "This device is in the profile." : "This device is NOT in the profile.",
                            systemImage: included ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(included ? .green : .red)
                    }
                } header: {
                    Text("Check a device")
                } footer: {
                    Text("Apps can't read device identifiers, so paste the UDID yourself. On a Mac, find your watch's UDID in Xcode › Window › Devices and Simulators.")
                }
            }

            Section("File") {
                LabeledContent("Name", value: package.originalFileName)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: package.fileSize, countStyle: .file))
                LabeledContent("Imported", value: package.importedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(package.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingInstall, onDismiss: { installer.stop() }) {
            InstallView(package: package)
        }
    }

    private func startInstall() {
        let fileURL = store.fileURL(for: package)
        switch mode {
        case .local:
            installer.installLocally(package, fileURL: fileURL, host: host, port: port)
        case .remote:
            installer.prepareRemote(package, fileURL: fileURL, baseURL: remoteBaseURL)
        }
        showingInstall = true
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

private struct BundleSection: View {
    let title: String
    let bundle: BundleInfo

    var body: some View {
        Section(title) {
            LabeledContent("Name", value: bundle.displayName)
            LabeledContent("Bundle ID", value: bundle.bundleIdentifier)
            LabeledContent("Version", value: "\(bundle.shortVersion) (\(bundle.buildVersion))")
            if let minimum = bundle.minimumOSVersion {
                LabeledContent("Requires", value: "\(bundle.isWatchOSBinary ? "watchOS" : "iOS") \(minimum)")
            }
            if bundle.isWatchApp {
                LabeledContent("Runs without iPhone app", value: bundle.runsIndependently ? "Yes" : "No")
            }
            LabeledContent("Code signature", value: bundle.hasCodeSignature ? "Present" : "Missing")
            if let profile = bundle.profile {
                LabeledContent("Profile", value: profile.name)
                LabeledContent("Type", value: profile.kind.displayName)
                if let team = profile.teamName ?? profile.teamIdentifiers.first {
                    LabeledContent("Team", value: team)
                }
                if let expiry = profile.expirationDate {
                    LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(profile.isExpired() ? .red : .primary)
                }
                if let devices = profile.provisionedDevices {
                    LabeledContent("Devices", value: "\(devices.count)")
                }
            } else {
                LabeledContent("Profile", value: "None")
            }
        }
    }
}
