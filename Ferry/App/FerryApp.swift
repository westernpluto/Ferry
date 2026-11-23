import SwiftUI
import UniformTypeIdentifiers

@main
struct FerryApp: App {
    @StateObject private var store = PackageStore()
    @StateObject private var signing = SigningStore()
    @StateObject private var installer = InstallCoordinator()
    @StateObject private var sources = SourceStore()
    @StateObject private var appleTV = AppleTVStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(signing)
                .environmentObject(installer)
                .environmentObject(sources)
                .environmentObject(appleTV)
                .onAppear { installer.appleTV = appleTV }
                .task { await sources.refresh() }
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

    private var updateCount: Int {
        store.packages.filter { sources.update(for: $0) != nil }.count
    }

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Apps", systemImage: "square.stack.3d.up.fill") }
                .badge(updateCount)
            SourcesView()
                .tabItem { Label("Sources", systemImage: "tray.full.fill") }
        }
    }
}

extension UTType {
    static let ipa = UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip)
    static let mobileProvision = UTType(importedAs: "com.apple.mobileprovision", conformingTo: .data)
}
