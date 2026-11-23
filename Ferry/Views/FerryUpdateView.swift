import SwiftUI

/// Settings › Ferry Updates: where Ferry gets its own updates, and installing them.
struct FerryUpdateView: View {
    @EnvironmentObject private var updater: SelfUpdater
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var store: PackageStore
    @EnvironmentObject private var signing: SigningStore
    @EnvironmentObject private var installer: InstallCoordinator

    @State private var installing: AppPackage?
    @State private var lastInstalled: AppPackage?
    @State private var error: String?
    @State private var showingAddSource = false

    private var update: SourceStore.Update? { updater.availableUpdate(in: sources) }
    private var candidates: [(sourceURL: URL, app: AltSource.App)] { updater.candidates(in: sources) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed", value: updater.displayVersion)
                if sources.isRefreshing || updater.isPreparing {
                    HStack { ProgressView(); Text(updater.isPreparing ? "Downloading…" : "Checking…") }
                } else if let update {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ferry \(update.version.displayVersion) is available").font(.headline)
                        if let notes = update.version.localizedDescription, !notes.isEmpty {
                            Text(notes).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        startUpdate(update)
                    } label: {
                        Label("Update Ferry", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(installer.phase.isBusy)
                } else if updater.sourceApp(in: sources) != nil {
                    Label("Ferry is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("Check Now") { Task { await sources.refresh() } }
                    .disabled(sources.isRefreshing)
            } footer: {
                Text("Ferry downloads the update, signs it with your certificate under the bundle ID and team it has now, and installs it over itself. Your apps, profiles and certificate stay. Ferry closes while iOS installs the update.")
            }

            Section {
                if candidates.isEmpty {
                    Text("None of your sources lists Ferry yet.")
                        .foregroundStyle(.secondary)
                    Button {
                        showingAddSource = true
                    } label: {
                        Label("Add a Source", systemImage: "plus.circle.fill")
                    }
                } else {
                    Picker("Updates From", selection: $updater.link) {
                        Text("Automatic").tag(SourceLink?.none)
                        ForEach(candidates, id: \.app.bundleIdentifier) { item in
                            Text("\(item.app.name) · \(sources.entries.first { $0.url == item.sourceURL }?.title ?? item.sourceURL.host ?? "")")
                                .tag(SourceLink?.some(SourceLink(sourceURL: item.sourceURL, bundleIdentifier: item.app.bundleIdentifier)))
                        }
                    }
                }
                Toggle("Check When Ferry Opens", isOn: $updater.checksAutomatically)
            } header: {
                Text("Source")
            } footer: {
                Text("Your Ferry install page publishes a source for Ferry at …github.io/<your copy>/source.json. Add it in the Sources tab, or use any source that lists Ferry.")
            }
        }
        .navigationTitle("Ferry Updates")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSource) { AddSourceView() }
        .sheet(item: $installing, onDismiss: {
            installer.stop()
            if let lastInstalled { store.removeSignedCopy(of: lastInstalled) }
        }) { package in
            InstallView(package: package)
        }
        .alert("Couldn't Update Ferry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func startUpdate(_ update: SourceStore.Update) {
        Task {
            do {
                let package = try await updater.install(update, store: store, sources: sources, signing: signing, installer: installer)
                lastInstalled = package
                installing = package
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
