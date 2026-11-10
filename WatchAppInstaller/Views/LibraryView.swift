import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: PackageStore
    @State private var showingImporter = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.packages.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.packages) { package in
                            NavigationLink(value: package.id) {
                                PackageRow(package: package)
                            }
                        }
                        .onDelete { offsets in
                            for package in offsets.map({ store.packages[$0] }) {
                                store.delete(package)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Watch Apps")
            .navigationDestination(for: UUID.self) { id in
                if let package = store.packages.first(where: { $0.id == id }) {
                    PackageDetailView(package: package)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if store.isImporting {
                        ProgressView()
                    } else {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import IPA", systemImage: "plus")
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.ipa, .zip], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    for url in urls { await store.importIPA(from: url) }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("Import failed", isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "applewatch")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No apps yet")
                .font(.title2.bold())
            Text("Import a signed .ipa that contains a watchOS app. Apps signed with an Ad Hoc, Development or Enterprise profile can be installed on your iPhone and paired Apple Watch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Import IPA") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

private struct PackageRow: View {
    let package: AppPackage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: package.watchApps.isEmpty ? "iphone" : "applewatch")
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.title).font(.headline)
                Text("\(package.container.bundleIdentifier) · \(package.container.shortVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusBadge(issues: package.issues)
        }
    }
}

struct StatusBadge: View {
    let issues: [PackageIssue]

    var body: some View {
        let worst = issues.map(\.severity).max()
        switch worst {
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        }
    }
}
