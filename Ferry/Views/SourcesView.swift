import SwiftUI
import UIKit

/// AltStore-style sources: add them once, then get apps and updates from them without
/// importing files by hand.
struct SourcesView: View {
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var store: PackageStore

    @State private var showingAdd = false

    private var updates: [(package: AppPackage, update: SourceStore.Update)] {
        store.packages.compactMap { package in sources.update(for: package).map { (package: package, update: $0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                if !updates.isEmpty {
                    Section {
                        ForEach(updates, id: \.package.id) { item in
                            SourceAppRow(app: item.update.app, sourceURL: item.update.sourceURL)
                        }
                    } header: {
                        HStack {
                            Text("Updates")
                            Spacer()
                            Button("Update All") { updateAll() }
                                .font(.caption.bold())
                                .disabled(!sources.downloads.isEmpty)
                        }
                    } footer: {
                        Text("Updating replaces the app's IPA in your library. No extra copies are kept.")
                    }
                }

                Section {
                    if sources.entries.isEmpty {
                        Button {
                            showingAdd = true
                        } label: {
                            Label("Add a Source", systemImage: "plus.circle.fill")
                        }
                    }
                    ForEach(sources.entries) { entry in
                        NavigationLink {
                            SourceDetailView(url: entry.url)
                        } label: {
                            SourceRow(entry: entry)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { sources.entries[$0] }.forEach(sources.remove)
                    }
                    .onMove { sources.move(from: $0, to: $1) }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Sources use the AltStore format, which SideStore, Feather and others use too. Pull down to check for updates.")
                }
            }
            .navigationTitle("Sources")
            .refreshable { await sources.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if sources.isRefreshing { ProgressView() } else { EditButton() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddSourceView()
            }
        }
    }

    private func updateAll() {
        let pending = updates
        Task {
            for item in pending {
                await sources.download(item.update.version, of: item.update.app, from: item.update.sourceURL, into: store)
            }
        }
    }
}

private struct SourceRow: View {
    let entry: SourceStore.Entry

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(url: entry.source?.iconURL, systemName: "tray.full.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline)
                if let error = entry.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("\(entry.source?.apps.count ?? 0) apps · \(entry.url.host ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct SourceDetailView: View {
    let url: URL
    @EnvironmentObject private var sources: SourceStore
    @State private var search = ""

    private var entry: SourceStore.Entry? { sources.entries.first { $0.url == url } }

    private var apps: [AltSource.App] {
        let all = entry?.source?.apps ?? []
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            if let subtitle = entry?.source?.subtitle {
                Section { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Section {
                ForEach(apps) { app in
                    NavigationLink {
                        SourceAppDetailView(app: app, sourceURL: url)
                    } label: {
                        SourceAppRow(app: app, sourceURL: url)
                    }
                }
            } footer: {
                Text(url.absoluteString).textSelection(.enabled)
            }
        }
        .navigationTitle(entry?.title ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .refreshable { await sources.refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

/// One app from a source, with a Get / Update / Open button.
struct SourceAppRow: View {
    let app: AltSource.App
    let sourceURL: URL

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(url: app.iconURL, systemName: "app.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                Text(app.subtitle ?? app.developerName ?? app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SourceAppButton(app: app, sourceURL: sourceURL)
        }
    }
}

struct SourceAppButton: View {
    let app: AltSource.App
    let sourceURL: URL
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var store: PackageStore

    var body: some View {
        if let progress = sources.downloads[app.bundleIdentifier] {
            Button {
                sources.cancelDownload(app)
            } label: {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                    Circle().trim(from: 0, to: max(0.03, progress))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel download")
        } else if let latest = app.latest {
            let installed = sources.libraryPackage(for: app, in: store)
            let needsUpdate = installed.map {
                AppVersion.isNewer(version: latest.version, build: latest.buildVersion,
                                   than: $0.container.shortVersion, installedBuild: $0.container.buildVersion)
            }
            Button(needsUpdate == nil ? "Get" : needsUpdate == true ? "Update" : "Added") {
                Task { await sources.download(latest, of: app, from: sourceURL, into: store) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.callout.bold())
            .disabled(needsUpdate == false)
        }
    }
}

struct SourceAppDetailView: View {
    let app: AltSource.App
    let sourceURL: URL
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var store: PackageStore

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    SourceIcon(url: app.iconURL, systemName: "app.fill", size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.title2.bold())
                        if let developer = app.developerName {
                            Text(developer).font(.subheadline).foregroundStyle(.secondary)
                        }
                        SourceAppButton(app: app, sourceURL: sourceURL)
                    }
                }
                .padding(.vertical, 4)
                if let description = app.localizedDescription {
                    Text(description).font(.callout)
                }
            }

            if let installed = sources.libraryPackage(for: app, in: store) {
                Section("In Your Library") {
                    LabeledContent("Version", value: "\(installed.container.shortVersion) (\(installed.container.buildVersion))")
                }
            }

            Section("Versions") {
                ForEach(Array(app.versions.enumerated()), id: \.offset) { _, version in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(version.displayVersion).font(.headline)
                            Spacer()
                            if let date = version.releaseDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let notes = version.localizedDescription, !notes.isEmpty {
                            Text(notes).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if let size = version.size, size > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                            if let minimum = version.minOSVersion { Text("Requires \(minimum)") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Download") {
                            Task { await sources.download(version, of: app, from: sourceURL, into: store) }
                        }
                        .tint(.accentColor)
                    }
                }
            }

            Section {
                LabeledContent("Bundle ID") {
                    Text(app.bundleIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                }
            } footer: {
                Text("Swipe a version to download it instead of the newest. It replaces the copy in your library.")
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddSourceView: View {
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isAdding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/apps.json", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    if UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings {
                        Button {
                            address = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                    }
                } footer: {
                    Text("The address of an AltStore-style source (a .json file). altstore:// and sidestore:// source links work too.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button("Add", action: add)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        isAdding = true
        error = nil
        Task {
            defer { isAdding = false }
            do {
                try await sources.add(address)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SourceIcon: View {
    let url: URL?
    let systemName: String
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.5))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}
