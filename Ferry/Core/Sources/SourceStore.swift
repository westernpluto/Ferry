import Foundation

/// The AltStore-style sources you've added, and the updates they offer for apps in the library.
@MainActor
final class SourceStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        var url: URL
        var source: AltSource?
        var error: String?
        var id: URL { url }
        var title: String { source?.name ?? url.host ?? url.absoluteString }
    }

    /// A newer version of a library app, found in a source.
    struct Update: Hashable {
        var sourceURL: URL
        var app: AltSource.App
        var version: AltSource.Version
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// Download progress (0...1) by app bundle ID.
    @Published private(set) var downloads: [String: Double] = [:]

    private let directory: URL
    private var cacheURL: URL { directory.appendingPathComponent("sources.json") }
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sources", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    // MARK: Managing sources

    enum SourceError: LocalizedError {
        case invalidURL
        case duplicate
        case notASource(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter the source's full address (https://…)."
            case .duplicate: return "That source has already been added."
            case .notASource(let detail): return "That address isn't an AltStore-style source (\(detail))."
            }
        }
    }

    /// Accepts a plain address, an `altstore://source?url=…` / `sidestore://…` link or a
    /// `feather://source/…` link.
    static func sourceURL(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            if let inner = components.queryItems?.first(where: { $0.name == "url" })?.value {
                value = inner
            } else if let host = components.host {
                // feather://source/<url>
                value = String(value.dropFirst((scheme + "://" + host + "/").count))
            }
        }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        guard let url = URL(string: value), url.host?.contains(".") == true else { return nil }
        return url
    }

    func add(_ text: String) async throws {
        guard let url = Self.sourceURL(from: text) else { throw SourceError.invalidURL }
        guard !entries.contains(where: { $0.url == url }) else { throw SourceError.duplicate }
        let source = try await Self.fetch(url)
        entries.append(Entry(url: url, source: source))
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.url == entry.url }
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.map { entries[$0] }
        var remaining = entries
        for index in offsets.reversed() { remaining.remove(at: index) }
        let insertAt = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        entries = remaining
        save()
    }

    /// Re-downloads every source. Keeps the last good copy of a source that fails.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let urls = entries.map(\.url)
        let results = await withTaskGroup(of: (URL, Result<AltSource, Error>).self) { group in
            for url in urls {
                group.addTask {
                    do { return (url, .success(try await Self.fetch(url))) } catch { return (url, .failure(error)) }
                }
            }
            var collected: [URL: Result<AltSource, Error>] = [:]
            for await (url, result) in group { collected[url] = result }
            return collected
        }
        for index in entries.indices {
            switch results[entries[index].url] {
            case .success(let source):
                entries[index].source = source
                entries[index].error = nil
            case .failure(let error):
                entries[index].error = error.localizedDescription
            case nil:
                break
            }
        }
        lastRefresh = Date()
        save()
    }

    nonisolated static func fetch(_ url: URL) async throws -> AltSource {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.notASource("HTTP \(http.statusCode)")
        }
        let source: AltSource
        do {
            source = try JSONDecoder().decode(AltSource.self, from: data)
        } catch {
            throw SourceError.notASource("not valid JSON")
        }
        return source
    }

    // MARK: Finding apps and updates

    var allApps: [(sourceURL: URL, app: AltSource.App)] {
        entries.flatMap { entry in (entry.source?.apps ?? []).map { (sourceURL: entry.url, app: $0) } }
    }

    /// The source app a library app comes from: the source it was added from, or else any
    /// source listing its bundle ID.
    func sourceApp(for package: AppPackage) -> (sourceURL: URL, app: AltSource.App)? {
        if let link = package.sourceLink,
           let entry = entries.first(where: { $0.url == link.sourceURL }),
           let app = entry.source?.apps.first(where: { $0.bundleIdentifier == link.bundleIdentifier }) {
            return (entry.url, app)
        }
        let id = package.container.bundleIdentifier
        return allApps.first { $0.app.bundleIdentifier == id }
    }

    func update(for package: AppPackage) -> Update? {
        guard let match = sourceApp(for: package), let latest = match.app.latest else { return nil }
        guard AppVersion.isNewer(
            version: latest.version,
            build: latest.buildVersion,
            than: package.container.shortVersion,
            installedBuild: package.container.buildVersion
        ) else { return nil }
        return Update(sourceURL: match.sourceURL, app: match.app, version: latest)
    }

    func libraryPackage(for app: AltSource.App, in store: PackageStore) -> AppPackage? {
        store.packages.first { package in
            package.sourceLink?.bundleIdentifier == app.bundleIdentifier
                || package.container.bundleIdentifier == app.bundleIdentifier
        }
    }

    // MARK: Downloading

    /// Downloads a version and adds it to the library. If the app is already there, its IPA is
    /// overwritten in place (same entry, no second copy).
    @discardableResult
    func download(_ version: AltSource.Version, of app: AltSource.App, from sourceURL: URL,
                  into store: PackageStore) async -> AppPackage? {
        let key = app.bundleIdentifier
        guard downloads[key] == nil else { return nil }
        downloads[key] = 0
        defer {
            downloads[key] = nil
            activeTasks[key] = nil
        }

        let file: URL
        do {
            file = try await downloadFile(version.downloadURL, key: key)
        } catch {
            if (error as? URLError)?.code != .cancelled {
                store.lastError = "\(app.name): \(error.localizedDescription)"
            }
            return nil
        }
        let link = SourceLink(sourceURL: sourceURL, bundleIdentifier: app.bundleIdentifier)
        let existing = libraryPackage(for: app, in: store)
        return await store.importIPA(
            from: file,
            originalFileName: "\(app.name)-\(version.version).ipa",
            sourceLink: link,
            replacing: existing?.id,
            moveFile: true
        )
    }

    func cancelDownload(_ app: AltSource.App) {
        activeTasks[app.bundleIdentifier]?.cancel()
    }

    private func downloadFile(_ url: URL, key: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString).ipa")

        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                if let error { return continuation.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                guard let temporary else { return continuation.resume(throwing: URLError(.cannotOpenFile)) }
                do {
                    // The temporary file is deleted when this handler returns, so move it now.
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard let self, self.downloads[key] != nil else { return }
                    self.downloads[key] = fraction
                }
            }
            activeTasks[key] = task
            task.resume()
        }
    }

    // MARK: Persistence

    private struct Cached: Codable {
        var url: URL
        var source: AltSource?
    }

    private func load() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Cached].self, from: data) {
            entries = cached.map { Entry(url: $0.url, source: $0.source) }
        }
    }

    private func save() {
        let cached = entries.map { Cached(url: $0.url, source: $0.source) }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
