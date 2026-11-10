import SwiftUI

struct InstallView: View {
    let package: AppPackage

    @EnvironmentObject private var installer: InstallCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    status
                        .padding(.vertical, 8)
                }

                if installer.phase == .readyToUpload || !installer.exportedFiles.isEmpty {
                    Section {
                        ShareLink(items: installer.exportedFiles) {
                            Label("Share manifest.plist and IPA", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            installer.openRemoteInstallLink()
                        } label: {
                            Label("Install from My Server", systemImage: "arrow.down.circle")
                        }
                        .disabled(installer.remoteInstallURL == nil)
                    } header: {
                        Text("Upload, then install")
                    } footer: {
                        Text("Upload both files to the address in Settings › Install Method, then tap Install from My Server.")
                    }
                }

                if !package.watchApps.isEmpty {
                    Section("Apple Watch") {
                        Text("After the iPhone app installs, the watch app installs automatically if Automatic App Install is on. Otherwise, open the Watch app › My Watch › Available Apps and tap Install.")
                            .font(.callout)
                        Button {
                            installer.openWatchApp()
                        } label: {
                            Label("Open the Watch App", systemImage: "arrow.up.forward.app")
                        }
                    }
                }

                if !installer.log.isEmpty {
                    Section("Activity") {
                        ForEach(installer.log) { line in
                            Text(line.text)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(package.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var status: some View {
        switch installer.phase {
        case .idle:
            Label("Getting ready…", systemImage: "hourglass")
        case .signing:
            progressRow("Signing…", detail: installer.detail)
        case .serving:
            progressRow("Starting…", detail: nil)
        case .waitingForInstaller:
            progressRow("Waiting for iOS…", detail: "Tap Install if iOS asks.")
        case .transferring(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text("Installing…").font(.headline)
                ProgressView(value: fraction)
            }
        case .readyToUpload:
            Label("Ready to upload", systemImage: "icloud.and.arrow.up")
                .font(.headline)
        case .handedOff:
            Label("Installing on your iPhone. Check the Home Screen.", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func progressRow(_ title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
