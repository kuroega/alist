import CryptoKit
import Foundation

/// One video found on the server, with what its name says about it.
struct LibraryFile: Codable, Hashable, Identifiable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let modified: String?
    let parsed: ParsedMedia

    var id: String { path }

    var object: AListObject {
        AListObject(virtualPath: path, name: name, size: size, isDirectory: false, modified: modified, type: AListFileType.video.rawValue)
    }

    /// When the file landed on the server; used for "recently added" ordering.
    var addedAt: Date { modified.flatMap(LibraryDates.parse) ?? .distantPast }
}

struct LibrarySnapshot: Codable, Sendable {
    var files: [LibraryFile]
    var roots: [String]
    var scannedAt: Date
}

struct LibraryScanProgress: Equatable, Sendable {
    var foldersScanned: Int
    var videosFound: Int
    var currentFolder: String
}

/// Walks the server breadth-first from the library folders and collects every
/// video, skipping extras, samples and system folders.
struct LibraryScanner: Sendable {
    let api: any AListAPI
    var maxDepth = 12
    var maxFolders = 6_000
    var concurrency = 4

    func scan(
        roots: [String],
        progress: @escaping @Sendable (LibraryScanProgress) async -> Void
    ) async throws -> [LibraryFile] {
        var queue: [(path: String, depth: Int)] = Self.minimalRoots(roots).map { ($0, 0) }
        var visited = Set<String>()
        var files: [String: LibraryFile] = [:]
        var foldersScanned = 0

        try await withThrowingTaskGroup(of: (String, Int, [AListObject]).self) { group in
            var running = 0
            while true {
                while running < concurrency, !queue.isEmpty, visited.count < maxFolders {
                    let next = queue.removeFirst()
                    guard visited.insert(next.path).inserted else { continue }
                    running += 1
                    group.addTask { (next.path, next.depth, try await listAll(next.path)) }
                }
                guard running > 0, let result = try await group.next() else { break }
                let (folder, depth, items) = result
                running -= 1
                foldersScanned += 1
                try Task.checkCancellation()

                for item in items {
                    let path = Self.childPath(of: item, in: folder)
                    if item.isDirectory {
                        if depth + 1 <= maxDepth, !Self.isSkippedFolder(item.name) {
                            queue.append((path, depth + 1))
                        }
                    } else if Self.isVideo(item), !Self.isSample(item.name) {
                        files[path] = LibraryFile(
                            path: path,
                            name: item.name,
                            size: item.size,
                            modified: item.modified,
                            parsed: MediaNameParser.parse(path: path)
                        )
                    }
                }
                await progress(LibraryScanProgress(foldersScanned: foldersScanned, videosFound: files.count, currentFolder: folder))
            }
        }
        return files.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Lists every page of a folder. A folder that cannot be read is treated
    /// as empty so one locked share never sinks the whole scan; an expired
    /// session still surfaces.
    private func listAll(_ path: String) async throws -> [AListObject] {
        var items: [AListObject] = []
        var page = 1
        do {
            while true {
                let result = try await api.list(path: path, page: page, perPage: 200)
                items += result.content
                let hasMore = result.hasMore ?? (result.content.count == 200)
                guard hasMore, page < 100 else { break }
                page += 1
            }
        } catch AListAPIError.unauthorized {
            throw AListAPIError.unauthorized
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return items
        }
        return items
    }

    static func childPath(of item: AListObject, in folder: String) -> String {
        if let provided = item.virtualPath, !provided.isEmpty { return AListPath.normalize(provided) }
        return (try? AListPath.join(parent: folder, name: item.name)) ?? AListPath.normalize(folder + "/" + item.name)
    }

    /// Drops roots nested inside other roots so nothing is listed twice.
    static func minimalRoots(_ roots: [String]) -> [String] {
        let normalized = Set((roots.isEmpty ? ["/"] : roots).map(AListPath.normalize)).sorted()
        return normalized.filter { root in
            !normalized.contains { other in
                other != root && (other == "/" || root.hasPrefix(other + "/"))
            }
        }
    }

    static func isVideo(_ item: AListObject) -> Bool {
        guard !item.isDirectory else { return false }
        if item.fileType == .video { return true }
        guard item.fileType == .unknown else { return false }
        return videoExtensions.contains(URL(fileURLWithPath: item.name).pathExtension.lowercased())
    }

    static func isSample(_ name: String) -> Bool {
        name.range(of: #"(?i)(^|[\s._\-\[(])sample([\s._\-\])]|$)"#, options: .regularExpression) != nil
    }

    static func isSkippedFolder(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("@") || name.hasPrefix("#") || name.hasPrefix("$") { return true }
        return skippedFolders.contains(name.lowercased())
    }

    private static let videoExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "rmvb", "webm", "flv", "m4v", "ts", "m2ts", "wmv", "mpg", "mpeg", "iso"]
    private static let skippedFolders: Set<String> = [
        "sample", "samples", "extras", "featurettes", "trailers", "trailer", "behind the scenes", "deleted scenes",
        "interviews", "shorts", "scenes", "other", "bonus", "subs", "subtitles", "system volume information", "lost+found", "花絮", "预告片"
    ]
}

/// Caches the scanned index and TMDB matches per account under Caches, and
/// the chosen library folders in user defaults.
struct GalleryLibraryStore {
    static let rootsDefaultsKey = "com.alist.tv.gallery-roots-v1"
    static let englishMetadataDefaultsKey = "com.alist.tv.gallery-english-metadata"

    let accountKey: String
    private let directory: URL?
    private let defaults: UserDefaults

    init(baseURL: URL, username: String, defaults: UserDefaults = .standard, directory: URL? = nil) {
        let raw = baseURL.absoluteString + "|" + username
        accountKey = SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        self.defaults = defaults
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Gallery", isDirectory: true)
        self.directory = base?.appendingPathComponent(accountKey, isDirectory: true)
        if let dir = self.directory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Library folders

    var roots: [String] {
        (defaults.dictionary(forKey: Self.rootsDefaultsKey)?[accountKey] as? [String]) ?? []
    }

    func setRoots(_ roots: [String]) {
        var all = defaults.dictionary(forKey: Self.rootsDefaultsKey) ?? [:]
        all[accountKey] = Array(Set(roots.map(AListPath.normalize))).sorted()
        defaults.set(all, forKey: Self.rootsDefaultsKey)
    }

    /// Matches carry the language they were fetched in, so they live per language.
    var prefersEnglishMetadata: Bool {
        get { defaults.bool(forKey: Self.englishMetadataDefaultsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.englishMetadataDefaultsKey) }
    }

    // MARK: Snapshot & matches

    func loadSnapshot() -> LibrarySnapshot? { read("library.json") }
    func saveSnapshot(_ snapshot: LibrarySnapshot) { write(snapshot, to: "library.json") }

    /// One file per TMDB language, so a device switching languages (or the
    /// English override) never shows titles fetched in another language.
    private func matchesFile(_ language: String) -> String { "matches-\(language).json" }

    func loadMatches(language: String) -> [String: GalleryMatch] { read(matchesFile(language)) ?? [:] }
    func saveMatches(_ matches: [String: GalleryMatch], language: String) { write(matches, to: matchesFile(language)) }

    func removeMatches(language: String) {
        guard let url = directory?.appendingPathComponent(matchesFile(language)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func read<Value: Decodable>(_ name: String) -> Value? {
        guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to name: String) {
        guard let url = directory?.appendingPathComponent(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum LibraryDates {
    static func parse(_ raw: String) -> Date? {
        if let date = fractional.date(from: raw) { return date }
        return plain.date(from: raw)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
