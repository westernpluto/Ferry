import SwiftUI
import UniformTypeIdentifiers

@main
struct WatchAppInstallerApp: App {
    @StateObject private var store = PackageStore()
    @StateObject private var installer = InstallCoordinator()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(installer)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await store.importIPA(from: url) }
                }
        }
    }
}

extension UTType {
    static let ipa = UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip)
}
