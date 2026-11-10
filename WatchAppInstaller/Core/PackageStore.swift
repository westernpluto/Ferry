import Foundation

/// The library of imported IPAs, persisted in Application Support.
@MainActor
final class PackageStore: ObservableObject {
    @Published private(set) var packages: [AppPackage] = []
    @Published var isImporting = false
    @Published var lastError: String?

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Packages", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    func fileURL(for package: AppPackage) -> URL {
        directory.appendingPathComponent(package.storedFileName)
    }

    func importIPA(from source: URL) async {
        isImporting = true
        defer { isImporting = false }

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let destination = directory.appendingPathComponent("\(id.uuidString).ipa")
        do {
            let result: IPAInspector.Result = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: destination)
                return try IPAInspector.inspect(url: destination)
            }.value

            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            let package = AppPackage(
                id: id,
                storedFileName: destination.lastPathComponent,
                originalFileName: source.lastPathComponent,
                importedAt: Date(),
                fileSize: size,
                container: result.container,
                watchApps: result.watchApps
            )
            packages.insert(package, at: 0)
            save()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = "\(source.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func delete(_ package: AppPackage) {
        try? FileManager.default.removeItem(at: fileURL(for: package))
        packages.removeAll { $0.id == package.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([AppPackage].self, from: data) else { return }
        packages = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(packages) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
