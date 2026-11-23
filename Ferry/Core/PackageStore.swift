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

    /// Adds an IPA to the library. If the library already has this app (`replacing`, or else
    /// the same bundle ID on the same platform), its IPA is overwritten in place: the entry keeps
    /// its ID, file name and per-app settings, and no second copy is kept. Old signed copies
    /// are deleted. Returns the new or updated package.
    @discardableResult
    func importIPA(
        from source: URL,
        originalFileName: String? = nil,
        sourceLink: SourceLink? = nil,
        replacing replaceID: AppPackage.ID? = nil,
        moveFile: Bool = false
    ) async -> AppPackage? {
        isImporting = true
        defer { isImporting = false }

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        // Inspect a staged copy first, so a bad download never replaces a working IPA.
        let staged = directory.appendingPathComponent("incoming-\(UUID().uuidString).ipa")
        let name = originalFileName ?? source.lastPathComponent
        do {
            let result: IPAInspector.Result = try await Task.detached(priority: .userInitiated) {
                if moveFile {
                    try FileManager.default.moveItem(at: source, to: staged)
                } else {
                    try FileManager.default.copyItem(at: source, to: staged)
                }
                return try IPAInspector.inspect(url: staged)
            }.value

            let existingIndex = packages.firstIndex { package in
                if let replaceID { return package.id == replaceID }
                return package.container.bundleIdentifier == result.container.bundleIdentifier
                    && package.container.isTVOSApp == result.container.isTVOSApp
            }

            var package: AppPackage
            if let existingIndex {
                package = packages[existingIndex]
                let destination = fileURL(for: package)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try FileManager.default.moveItem(at: staged, to: destination)
                }
                try? FileManager.default.removeItem(at: signedFileURL(for: package))
                package.originalFileName = name
                package.importedAt = Date()
                package.container = result.container
                package.watchApps = result.watchApps
                package.extensions = result.extensions
                package.sourceLink = sourceLink ?? package.sourceLink
                package.fileSize = Self.size(of: destination)
                packages.remove(at: existingIndex)
            } else {
                let id = UUID()
                let destination = directory.appendingPathComponent("\(id.uuidString).ipa")
                try FileManager.default.moveItem(at: staged, to: destination)
                package = AppPackage(
                    id: id,
                    storedFileName: destination.lastPathComponent,
                    originalFileName: name,
                    importedAt: Date(),
                    fileSize: Self.size(of: destination),
                    container: result.container,
                    watchApps: result.watchApps,
                    extensions: result.extensions,
                    sourceLink: sourceLink
                )
            }
            packages.insert(package, at: 0)
            save()
            return package
        } catch {
            try? FileManager.default.removeItem(at: staged)
            if moveFile { try? FileManager.default.removeItem(at: source) }
            lastError = "\(name): \(error.localizedDescription)"
            return nil
        }
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Where the re-signed copy of a package is written.
    func signedFileURL(for package: AppPackage) -> URL {
        directory.appendingPathComponent("\(package.id.uuidString)-signed.ipa")
    }

    /// Deletes the re-signed copy once it has been installed, so only the original stays.
    func removeSignedCopy(of package: AppPackage) {
        try? FileManager.default.removeItem(at: signedFileURL(for: package))
    }

    func delete(_ package: AppPackage) {
        try? FileManager.default.removeItem(at: fileURL(for: package))
        try? FileManager.default.removeItem(at: signedFileURL(for: package))
        packages.removeAll { $0.id == package.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([AppPackage].self, from: data) else { return }
        packages = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        // Clean up anything left behind by an interrupted import or install.
        let keep = Set(packages.map(\.storedFileName))
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where file.hasSuffix(".ipa") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(packages) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
