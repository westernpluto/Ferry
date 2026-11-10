import SwiftUI

/// The app list. Uses a split view, so it shows the list and the selected app side by side
/// when there's room (iPhone Duo unfolded, landscape on large iPhones) and a stack otherwise.
struct LibraryView: View {
    @EnvironmentObject private var store: PackageStore
    @EnvironmentObject private var signing: SigningStore

    @State private var selection: AppPackage.ID?
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("Apps")
                .toolbar { toolbarContent }
        } detail: {
            if let id = selection, let package = store.packages.first(where: { $0.id == id }) {
                PackageDetailView(package: package)
                    .id(package.id)
            } else {
                ContentUnavailableHint(showingImporter: $showingImporter, isEmpty: store.packages.isEmpty)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.ipa, .zip], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls { await store.importIPA(from: url) }
                if selection == nil { selection = store.packages.first?.id }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Couldn't import", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !signing.isReady {
                Section {
                    Button {
                        showingSettings = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set up signing").font(.headline)
                                Text("Add your certificate and profiles once to install any of your apps.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "signature")
                        }
                    }
                }
            }

            Section {
                ForEach(store.packages) { package in
                    PackageRow(package: package)
                        .tag(package.id)
                }
                .onDelete { offsets in
                    for package in offsets.map({ store.packages[$0] }) {
                        if selection == package.id { selection = nil }
                        store.delete(package)
                    }
                }
            }
        }
        .overlay {
            if store.packages.isEmpty && signing.isReady {
                ContentUnavailableHint(showingImporter: $showingImporter, isEmpty: true)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                    Label("Add App", systemImage: "plus")
                }
            }
        }
    }
}

private struct ContentUnavailableHint: View {
    @Binding var showingImporter: Bool
    var isEmpty: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "ferry.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(isEmpty ? "Add an app" : "Select an app")
                .font(.title2.bold())
            Text("Add a .ipa file. Its iPhone app and any Apple Watch app inside it are installed together.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if isEmpty {
                Button {
                    showingImporter = true
                } label: {
                    Label("Add App", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PackageRow: View {
    let package: AppPackage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.title).font(.headline)
                Text("\(package.container.shortVersion) · \(package.watchApps.isEmpty ? "iPhone only" : "iPhone + Watch")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
