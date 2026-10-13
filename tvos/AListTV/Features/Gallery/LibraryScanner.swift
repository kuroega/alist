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

struct LibraryScanProgress: Equatable, Sendable {
    var foldersScanned: Int
    var videosFound: Int
    var currentFolder: String
}

/// Videos that appeared, changed or disappeared since the store last knew.
struct LibraryChange: Equatable, Sendable {
    private(set) var upserted: [String: LibraryFile] = [:]
    private(set) var removed: Set<String> = []

    var isEmpty: Bool { upserted.isEmpty && removed.isEmpty }
    var count: Int { upserted.count + removed.count }

    mutating func upsert(_ file: LibraryFile) {
        removed.remove(file.path)
        upserted[file.path] = file
    }

    mutating func remove(_ path: String) {
        upserted[path] = nil
        removed.insert(path)
    }
}

struct LibraryScanResult: Equatable, Sendable {
    /// False when nothing could be listed or the folder limit cut the walk
    /// short; such a pass removes nothing.
    var isComplete: Bool
    var foldersListed: Int
    /// Folders whose stored contents were reused without listing them.
    var foldersReused: Int
    /// Folders that could not be read; what was known about them is kept.
    var foldersFailed: Int
}

/// Walks the server breadth-first from the library folders and keeps the
/// Gallery store in step with it, skipping extras, samples and system folders.
///
/// The walk is incremental. Every listing is saved as it arrives, so an
/// interrupted scan keeps its progress. In `.quick` mode a folder without
/// subfolders is not listed again while the modified time its parent
/// reports is unchanged; its stored videos are reused. `.full` lists every
/// folder. Either way only differences are reported, and a folder that
/// fails to list keeps what was known about it instead of vanishing.
struct LibraryScanner: Sendable {
    enum Mode: Sendable {
        case quick
        case full
    }

    let api: any AListAPI
    let database: GalleryDatabase
    var maxDepth = 12
    var maxFolders = 40_000
    var concurrency = 4
    /// Changes gathered before they are handed over (also flushed every second).
    var changeBatch = 250

    private struct Pending {
        let path: String
        let depth: Int
        /// Modified time the parent's listing gave for this folder.
        let reported: String?
        let parent: String?
    }

    func scan(
        roots: [String],
        mode: Mode,
        progress: @escaping @Sendable (LibraryScanProgress) async -> Void,
        changes: @escaping @Sendable (LibraryChange) async -> Void
    ) async throws -> LibraryScanResult {
        let baseline = await database.beginScan()
        try Task.checkCancellation()
        let scanID = baseline.scanID

        var folders = baseline.folders
        var children: [String: [String]] = [:]
        for record in folders.values {
            if let parent = record.parent { children[parent, default: []].append(record.path) }
        }
        var known: [String: LibraryFile] = [:]
        for files in baseline.filesByFolder.values {
            for file in files { known[file.path] = file }
        }

        var queue = Self.minimalRoots(roots).map { Pending(path: $0, depth: 0, reported: nil, parent: nil) }
        var head = 0
        var visited = Set<String>()
        /// Videos confirmed present during this pass.
        var live = Set<String>()
        var seen: [String] = []
        var pending = LibraryChange()
        var lastHandOver = Date()
        var result = LibraryScanResult(isComplete: false, foldersListed: 0, foldersReused: 0, foldersFailed: 0)

        func handOver(force: Bool) async {
            if !pending.isEmpty, force || pending.count >= changeBatch || Date().timeIntervalSince(lastHandOver) >= 1 {
                await changes(pending)
                pending = LibraryChange()
                lastHandOver = Date()
            }
            if !seen.isEmpty, force || seen.count >= 500 {
                database.markSeen(seen, scanID: scanID)
                seen.removeAll()
            }
        }

        /// A folder that could not be read keeps its stored subtree.
        func keepSubtree(of folder: String) {
            let prefix = folder == "/" ? "/" : folder + "/"
            let inside = { (path: String) in path == folder || path.hasPrefix(prefix) }
            seen += folders.keys.filter(inside)
            for (key, files) in baseline.filesByFolder where inside(key) {
                for file in files { live.insert(file.path) }
            }
        }

        try await withThrowingTaskGroup(of: (Pending, [AListObject]?).self) { group in
            var running = 0
            while true {
                while running < concurrency, head < queue.count, visited.count < maxFolders {
                    let next = queue[head]
                    head += 1
                    guard visited.insert(next.path).inserted else { continue }
                    if mode == .quick, canReuse(next, folders: folders, children: children) {
                        result.foldersReused += 1
                        seen.append(next.path)
                        for file in baseline.filesByFolder[next.path] ?? [] { live.insert(file.path) }
                        continue
                    }
                    running += 1
                    group.addTask { (next, try await listAll(next.path)) }
                }
                guard running > 0, let reply = try await group.next() else { break }
                let (folder, items) = reply
                running -= 1
                try Task.checkCancellation()

                if let items {
                    result.foldersListed += 1
                    var subfolders: [Pending] = []
                    var subfolderPaths = Set<String>()
                    var videos: [String: LibraryFile] = [:]
                    for item in items {
                        let path = Self.childPath(of: item, in: folder.path)
                        if item.isDirectory {
                            if folder.depth + 1 <= maxDepth, !Self.isSkippedFolder(item.name), subfolderPaths.insert(path).inserted {
                                subfolders.append(Pending(path: path, depth: folder.depth + 1, reported: item.modified, parent: folder.path))
                            }
                        } else if Self.isVideo(item), !Self.isSample(item.name) {
                            // Parsing depends only on the path, so a known file keeps its result.
                            let parsed = known[path]?.parsed ?? MediaNameParser.parse(path: path)
                            videos[path] = LibraryFile(path: path, name: item.name, size: item.size, modified: item.modified, parsed: parsed)
                        }
                    }

                    let record = GalleryFolderRecord(path: folder.path, parent: folder.parent, modified: folder.reported, listedAt: Date())
                    folders[folder.path] = record
                    children[folder.path] = subfolders.map(\.path)
                    for subfolder in subfolders {
                        var child = folders[subfolder.path] ?? GalleryFolderRecord(path: subfolder.path)
                        child.parent = folder.path
                        folders[subfolder.path] = child
                    }
                    database.recordListing(folder: record, subfolders: subfolders.map(\.path), files: Array(videos.values), scanID: scanID)

                    for file in videos.values {
                        if known[file.path] != file || pending.removed.contains(file.path) { pending.upsert(file) }
                        live.insert(file.path)
                    }
                    for old in baseline.filesByFolder[folder.path] ?? [] where videos[old.path] == nil && !live.contains(old.path) {
                        pending.remove(old.path)
                    }
                    queue += subfolders
                } else {
                    result.foldersFailed += 1
                    keepSubtree(of: folder.path)
                }

                await handOver(force: false)
                await progress(LibraryScanProgress(
                    foldersScanned: result.foldersListed + result.foldersReused + result.foldersFailed,
                    videosFound: live.count,
                    currentFolder: folder.path
                ))
            }
        }
        try Task.checkCancellation()

        // Only a pass that reached the server and every folder may delete.
        result.isComplete = head == queue.count && result.foldersListed > 0
        if result.isComplete {
            for path in known.keys where !live.contains(path) { pending.remove(path) }
        }
        let removed = Array(pending.removed)
        await handOver(force: true)
        if result.isComplete {
            // A pass that listed every folder counts as full, whatever its mode.
            database.finishScan(scanID: scanID, removedFiles: removed, roots: Self.minimalRoots(roots), full: result.foldersReused == 0, at: Date())
        }
        return result
    }

    /// A folder is reused when it was listed before, had no subfolders to
    /// walk, and its parent reports the same, plausible modified time.
    private func canReuse(_ folder: Pending, folders: [String: GalleryFolderRecord], children: [String: [String]]) -> Bool {
        guard let reported = folder.reported, Self.isTrustworthyModified(reported),
              let record = folders[folder.path], record.listedAt != nil, record.modified == reported else { return false }
        return children[folder.path]?.isEmpty ?? true
    }

    /// Drivers without real folder times report nothing or Go's zero date.
    static func isTrustworthyModified(_ value: String) -> Bool {
        guard let year = Int(value.prefix(4)) else { return false }
        return year >= 1980
    }

    /// Lists every page of a folder, or returns nil when it cannot be read so
    /// one locked share never sinks the whole scan; an expired session and
    /// cancellation still surface.
    private func listAll(_ path: String) async throws -> [AListObject]? {
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
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return nil
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

    /// Whether `path` lies inside one of the library folders (all of the
    /// server when there are none).
    static func isInside(_ path: String, roots: [String]) -> Bool {
        minimalRoots(roots).contains { root in root == "/" || path == root || path.hasPrefix(root + "/") }
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

/// Per-account Gallery storage: the library folders and metadata language in
/// user defaults, and the index itself in a `GalleryDatabase` under Caches.
struct GalleryLibraryStore {
    static let rootsDefaultsKey = "com.alist.tv.gallery-roots-v1"
    static let englishMetadataDefaultsKey = "com.alist.tv.gallery-english-metadata"

    let accountKey: String
    let database: GalleryDatabase
    private let defaults: UserDefaults

    init(baseURL: URL, username: String, defaults: UserDefaults = .standard, directory: URL? = nil) {
        let raw = baseURL.absoluteString + "|" + username
        accountKey = SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        self.defaults = defaults
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Gallery", isDirectory: true)
        let accountDirectory = base?.appendingPathComponent(accountKey, isDirectory: true)
        if let accountDirectory {
            try? FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        }
        database = GalleryDatabase(directory: accountDirectory)
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
