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
                }

                if !installer.exportedFiles.isEmpty {
                    Section {
                        ShareLink(items: installer.exportedFiles) {
                            Label("Share manifest.plist and IPA", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            installer.openRemoteInstallLink()
                        } label: {
                            Label("Install from my server", systemImage: "arrow.down.app")
                        }
                        .disabled(installer.remoteInstallURL == nil)
                    } header: {
                        Text("Step 1: upload · Step 2: install")
                    } footer: {
                        Text("Upload both files to the folder at your base URL, then tap Install from my server.")
                    }
                }

                Section("After iOS installs the app") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("watchOS installs the watch app automatically if Automatic App Install is turned on in the Watch app. If it isn't:")
                        Text("1. Open the Watch app on your iPhone.")
                        Text("2. Go to My Watch and scroll to Available Apps.")
                        Text("3. Tap Install next to \(package.title).")
                    }
                    .font(.callout)
                    Button {
                        installer.openWatchApp()
                    } label: {
                        Label("Open the Watch app", systemImage: "applewatch")
                    }
                }

                if !installer.log.isEmpty {
                    Section("Activity") {
                        ForEach(installer.log) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.text).font(.caption)
                                Text(line.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Install")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch installer.phase {
        case .idle:
            if installer.exportedFiles.isEmpty {
                Label("Ready", systemImage: "circle")
            } else {
                Label("Files ready to upload", systemImage: "doc.on.doc")
            }
        case .serving:
            HStack { ProgressView(); Text("Starting server…") }
        case .waitingForInstaller:
            HStack { ProgressView(); Text("Waiting for iOS to download the app…") }
        case .transferring(let fraction):
            VStack(alignment: .leading) {
                Text("Sending the app to iOS…")
                ProgressView(value: fraction)
            }
        case .handedOff:
            Label("Handed off to iOS. Check your Home Screen and Apple Watch.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
