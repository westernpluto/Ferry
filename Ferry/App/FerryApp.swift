import SwiftUI
import UniformTypeIdentifiers

@main
struct FerryApp: App {
    @StateObject private var store = PackageStore()
    @StateObject private var signing = SigningStore()
    @StateObject private var installer = InstallCoordinator()
    @StateObject private var sources = SourceStore()
    @StateObject private var appleTV = AppleTVStore()
    @StateObject private var history = InstallHistory()
    @StateObject private var updater = SelfUpdater()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(signing)
                .environmentObject(installer)
                .environmentObject(sources)
                .environmentObject(appleTV)
                .environmentObject(history)
                .environmentObject(updater)
                .onAppear {
                    installer.appleTV = appleTV
                    installer.history = history
                }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    switch url.pathExtension.lowercased() {
                    case "mobileprovision":
                        signing.importProfiles(from: [url])
                    default:
                        Task { await store.importIPA(from: url) }
                    }
                }
        }
    }
}

/// Apps in the library, and the sources they can be added and updated from.
struct RootView: View {
    @EnvironmentObject private var store: PackageStore
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var signing: SigningStore
    @EnvironmentObject private var appleTV: AppleTVStore
    @EnvironmentObject private var history: InstallHistory
    @EnvironmentObject private var updater: SelfUpdater
    @EnvironmentObject private var installer: InstallCoordinator

    @State private var offeredUpdate: SourceStore.Update?
    @State private var selfInstall: AppPackage?
    @State private var lastSelfInstall: AppPackage?
    @State private var selfUpdateError: String?

    /// Apps with something to do: a newer version in a source, or an installed copy that's
    /// out of date or about to expire. Each app counts once.
    private var updateCount: Int {
        var apps = Set(store.packages.filter { sources.update(for: $0) != nil }.map(\.container.bundleIdentifier))
        for item in history.needingAttention(packages: store.packages, sources: sources) {
            apps.insert(item.record.originalBundleIdentifier)
        }
        return apps.count
    }

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Apps", systemImage: "square.stack.3d.up.fill") }
                .badge(updateCount)
            SourcesView()
                .tabItem { Label("Sources", systemImage: "tray.full.fill") }
        }
        .task { await checkForUpdates() }
        .onReceive(appleTV.$installedApps) { reconcile($0) }
        .alert(
            "Ferry \(offeredUpdate?.version.displayVersion ?? "") Is Available",
            isPresented: Binding(get: { offeredUpdate != nil }, set: { if !$0 { offeredUpdate = nil } }),
            presenting: offeredUpdate
        ) { update in
            Button("Update") { installSelf(update) }
            Button("Skip This Version") { updater.skippedVersion = update.version.displayVersion }
            Button("Later", role: .cancel) {}
        } message: { update in
            Text(update.version.localizedDescription.map { "\($0)\n\n" } ?? "")
                + Text("Ferry signs the update with your certificate and installs it over itself. It closes while iOS installs.")
        }
        .alert("Couldn't Update Ferry", isPresented: Binding(get: { selfUpdateError != nil }, set: { if !$0 { selfUpdateError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(selfUpdateError ?? "")
        }
        .sheet(item: $selfInstall, onDismiss: {
            installer.stop()
            if let lastSelfInstall { store.removeSignedCopy(of: lastSelfInstall) }
        }) { package in
            InstallView(package: package)
        }
    }

    private func installSelf(_ update: SourceStore.Update) {
        Task {
            do {
                let package = try await updater.install(update, store: store, sources: sources, signing: signing, installer: installer)
                lastSelfInstall = package
                selfInstall = package
            } catch {
                selfUpdateError = error.localizedDescription
            }
        }
    }

    /// Refreshes sources, then asks paired Apple TVs which apps they have. TVs are only
    /// contacted once one has been paired, so nobody else sees the Local Network prompt.
    private func checkForUpdates() async {
        await sources.refresh()
        if let update = updater.availableUpdate(in: sources), updater.shouldPrompt(for: update) {
            offeredUpdate = update
        }
        if !appleTV.devices.isEmpty {
            await appleTV.refreshInstalledApps()
        }
    }

    private func reconcile(_ installed: [UUID: [AppleTVApp]]) {
        history.pruneAppleTVs(keeping: Set(appleTV.devices.map(\.id)))
        for (id, apps) in installed {
            guard let device = appleTV.device(id) else { continue }
            history.reconcile(
                appleTV: id,
                name: device.displayName,
                apps: apps,
                packages: store.packages,
                overrides: signing.overrides,
                sourceApp: { sources.sourceApp(bundleIdentifier: $0) }
            )
        }
    }
}

extension UTType {
    static let ipa = UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip)
    static let mobileProvision = UTType(importedAs: "com.apple.mobileprovision", conformingTo: .data)
}
