import SwiftUI
import UniformTypeIdentifiers

@main
struct WatchAppInstallerApp: App {
    @StateObject private var store = PackageStore()
    @StateObject private var signing = SigningStore()
    @StateObject private var installer = InstallCoordinator()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(signing)
                .environmentObject(installer)
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

extension UTType {
    static let ipa = UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip)
    static let mobileProvision = UTType(importedAs: "com.apple.mobileprovision", conformingTo: .data)
}
