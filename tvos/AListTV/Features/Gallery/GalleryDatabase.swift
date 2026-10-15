import Foundation

/// What the store remembers about one folder from its last listing.
struct GalleryFolderRecord: Equatable, Sendable {
    var path: String
    var parent: String?
    /// The folder's modified time, as its parent reported it, when it was
    /// last listed. Compared against the next report to skip the listing.
    var modified: String?
    /// Nil until the folder itself has been listed successfully.
    var listedAt: Date?
}

/// When the library was last fully walked, and which folders it covered.
struct GalleryScanState: Equatable, Sendable {
    var completedAt: Date?
    var fullCompletedAt: Date?
    var roots: [String]?
}

/// Everything a scan needs to know about the previous one.
struct LibraryScanBaseline: Sendable {
    var scanID: Int64
    var folders: [String: GalleryFolderRecord]
    /// Indexed videos keyed by the folder whose listing produced them.
    var filesByFolder: [String: [LibraryFile]]
}

/// The Gallery's local index: every video found so far, every folder's last
/// listing, and every TMDB match, in a SQLite file under Caches.
///
/// Writes are applied in submission order on one serial queue and committed
/// as they happen, so an interrupted scan or match run keeps its progress.
final class GalleryDatabase: @unchecked Sendable {
    static let fileName = "library.sqlite"
    /// Bump when the schema changes; older stores are rebuilt from scratch.
    static let schemaVersion = 1

    private let queue = DispatchQueue(label: "com.alist.tv.gallery-database", qos: .utility)
    /// Touched only on `queue`.
    private var connection: SQLiteConnection?

    /// Opens the store in `directory`, or an in-memory one when it is nil or
    /// cannot be opened, so the Gallery still works (without persistence).
    init(directory: URL?) {
        queue.async { [self] in
            if let directory, let onDisk = Self.open(directory: directory) {
                connection = onDisk
                Self.importLegacyFiles(in: directory, into: onDisk)
            } else {
                connection = try? Self.prepare(SQLiteConnection(path: ":memory:"))
            }
        }
    }

    private static func open(directory: URL) -> SQLiteConnection? {
        let url = directory.appendingPathComponent(fileName)
        if let connection = try? prepare(SQLiteConnection(path: url.path)) { return connection }
        // A damaged file is only a cache: start over rather than run without one.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName + suffix))
        }
        return try? prepare(SQLiteConnection(path: url.path))
    }

    private static func prepare(_ connection: SQLiteConnection) throws -> SQLiteConnection {
        try connection.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF;")
        if connection.userVersion != schemaVersion {
            try connection.execute("""
            DROP TABLE IF EXISTS meta;
            DROP TABLE IF EXISTS folders;
            DROP TABLE IF EXISTS files;
            DROP TABLE IF EXISTS matches;
            """)
        }
        try connection.execute("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS folders (
            path TEXT PRIMARY KEY,
            parent TEXT,
            modified TEXT,
            listed_at REAL,
            scan_id INTEGER
        );
        CREATE INDEX IF NOT EXISTS folders_parent ON folders(parent);
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY,
            folder TEXT NOT NULL,
            name TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified TEXT,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            year INTEGER,
            season INTEGER,
            episode INTEGER,
            episode_title TEXT,
            qualities TEXT NOT NULL,
            parser_version INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS files_folder ON files(folder);
        CREATE TABLE IF NOT EXISTS matches (
            language TEXT NOT NULL,
            key TEXT NOT NULL,
            matcher_version INTEGER NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY (language, key)
        );
        """)
        connection.userVersion = schemaVersion
        return connection
    }

    // MARK: Queue

    private func read<Value>(_ fallback: Value, _ body: @escaping (SQLiteConnection) throws -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let connection else { return continuation.resume(returning: fallback) }
                do {
                    continuation.resume(returning: try body(connection))
                } catch {
                    Self.report(error)
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    private func write(_ body: @escaping (SQLiteConnection) throws -> Void) {
        queue.async { [self] in
            guard let connection else { return }
            do {
                try connection.transaction { try body(connection) }
            } catch {
                Self.report(error)
            }
        }
    }

    /// Resolves once every write submitted before it has been applied.
    func flush() async {
        await read(()) { _ in }
    }

    private static func report(_ error: Error) {
#if DEBUG
        print("GalleryDatabase: \(error)")
#endif
    }

    // MARK: Files

    /// Every indexed video. Rows written by an older parser are parsed again
    /// (and saved) so titles follow parser fixes without a rescan.
    func loadFiles() async -> [LibraryFile] {
        await read([]) { connection in
            var files: [LibraryFile] = []
            var reparsed: [(file: LibraryFile, folder: String)] = []
            try connection.query("""
            SELECT path, folder, name, size, modified, kind, title, year, season, episode, episode_title, qualities, parser_version FROM files
            """) { row in
                guard let file = Self.file(from: row) else { return }
                if Int(row.int(12) ?? 0) == MediaNameParser.version {
                    files.append(file)
                } else {
                    let updated = LibraryFile(path: file.path, name: file.name, size: file.size, modified: file.modified, parsed: MediaNameParser.parse(path: file.path))
                    files.append(updated)
                    reparsed.append((updated, row.text(1) ?? AListPath.parent(of: file.path)))
                }
            }
            if !reparsed.isEmpty {
                try connection.transaction {
                    for entry in reparsed { try Self.insert(entry.file, folder: entry.folder, into: connection) }
                }
            }
            return files
        }
    }

    private static func file(from row: SQLiteRow) -> LibraryFile? {
        guard let path = row.text(0), let name = row.text(2), let kind = row.text(5).flatMap(ParsedMedia.Kind.init(rawValue:)),
              let title = row.text(6) else { return nil }
        let qualities = (row.text(11) ?? "").split(separator: "|").map(String.init)
        let parsed = ParsedMedia(
            kind: kind,
            title: title,
            year: row.int(7).map(Int.init),
            season: row.int(8).map(Int.init),
            episode: row.int(9).map(Int.init),
            episodeTitle: row.text(10),
            qualities: qualities
        )
        return LibraryFile(path: path, name: name, size: row.int(3) ?? 0, modified: row.text(4), parsed: parsed)
    }

    /// Every stored video with its folder, parsed by the current parser
    /// (without saving rows written by an older one).
    private static func forEachCurrentFile(_ connection: SQLiteConnection, _ body: (LibraryFile, String) -> Void) throws {
        try connection.query("""
        SELECT path, folder, name, size, modified, kind, title, year, season, episode, episode_title, qualities, parser_version FROM files
        """) { row in
            guard var file = Self.file(from: row), let folder = row.text(1) else { return }
            if Int(row.int(12) ?? 0) != MediaNameParser.version {
                file = LibraryFile(path: file.path, name: file.name, size: file.size, modified: file.modified, parsed: MediaNameParser.parse(path: file.path))
            }
            body(file, folder)
        }
    }

    private static func insert(_ file: LibraryFile, folder: String, into connection: SQLiteConnection) throws {
        let parsed = file.parsed
        try connection.run("""
        INSERT OR REPLACE INTO files (path, folder, name, size, modified, kind, title, year, season, episode, episode_title, qualities, parser_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(file.path), .text(folder), .text(file.name), .int(file.size), .text(file.modified),
            .text(parsed.kind.rawValue), .text(parsed.title), .int(parsed.year), .int(parsed.season), .int(parsed.episode),
            .text(parsed.episodeTitle), .text(parsed.qualities.joined(separator: "|")), .int(Int64(MediaNameParser.version))
        ])
    }

    // MARK: Scans

    func loadScanState() async -> GalleryScanState {
        await read(GalleryScanState()) { connection in
            let meta = try Self.meta(connection)
            return GalleryScanState(
                completedAt: meta[MetaKey.completedAt].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                fullCompletedAt: meta[MetaKey.fullCompletedAt].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                roots: meta[MetaKey.roots].map { $0.isEmpty ? [] : $0.components(separatedBy: "\n") }
            )
        }
    }

    /// Starts a scan pass: hands out its id together with the folders and
    /// files the previous passes left behind.
    func beginScan() async -> LibraryScanBaseline {
        await read(LibraryScanBaseline(scanID: 1, folders: [:], filesByFolder: [:])) { connection in
            let meta = try Self.meta(connection)
            let scanID = (meta[MetaKey.lastScanID].flatMap(Int64.init) ?? 0) + 1
            try Self.setMeta(MetaKey.lastScanID, String(scanID), connection)

            var folders: [String: GalleryFolderRecord] = [:]
            try connection.query("SELECT path, parent, modified, listed_at FROM folders") { row in
                guard let path = row.text(0) else { return }
                folders[path] = GalleryFolderRecord(
                    path: path,
                    parent: row.text(1),
                    modified: row.text(2),
                    listedAt: row.double(3).map(Date.init(timeIntervalSince1970:))
                )
            }
            var filesByFolder: [String: [LibraryFile]] = [:]
            try Self.forEachCurrentFile(connection) { file, folder in
                filesByFolder[folder, default: []].append(file)
            }
            return LibraryScanBaseline(scanID: scanID, folders: folders, filesByFolder: filesByFolder)
        }
    }

    /// Saves one successful folder listing: the folder itself, the subfolders
    /// the scan will visit next, and the videos directly inside it.
    func recordListing(folder: GalleryFolderRecord, subfolders: [String], files: [LibraryFile], scanID: Int64) {
        write { connection in
            try connection.run("""
            INSERT INTO folders (path, parent, modified, listed_at, scan_id) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET parent = excluded.parent, modified = excluded.modified,
                listed_at = excluded.listed_at, scan_id = excluded.scan_id
            """, [.text(folder.path), .text(folder.parent), .text(folder.modified), .double(folder.listedAt?.timeIntervalSince1970), .int(scanID)])

            // Subfolders that disappeared lose their row now; anything below
            // them is swept when the pass completes.
            var stale: [String] = []
            try connection.query("SELECT path FROM folders WHERE parent = ?", [.text(folder.path)]) { row in
                if let path = row.text(0) { stale.append(path) }
            }
            let current = Set(subfolders)
            for path in stale where !current.contains(path) {
                try connection.run("DELETE FROM folders WHERE path = ?", [.text(path)])
            }
            for path in subfolders {
                try connection.run("""
                INSERT INTO folders (path, parent, modified, listed_at, scan_id) VALUES (?, ?, NULL, NULL, NULL)
                ON CONFLICT(path) DO UPDATE SET parent = excluded.parent
                """, [.text(path), .text(folder.path)])
            }

            try connection.run("DELETE FROM files WHERE folder = ?", [.text(folder.path)])
            for file in files { try Self.insert(file, folder: folder.path, into: connection) }
        }
    }

    /// Marks folders whose stored contents are still current, so the end of
    /// the pass keeps them.
    func markSeen(_ paths: [String], scanID: Int64) {
        guard !paths.isEmpty else { return }
        write { connection in
            for path in paths {
                try connection.run("UPDATE folders SET scan_id = ? WHERE path = ?", [.int(scanID), .text(path)])
            }
        }
    }

    /// Closes a pass that visited every folder: folders it did not see are
    /// gone from the server (or outside the library folders), and so are
    /// the videos it reports removed. TMDB matches no remaining video uses
    /// go with them.
    func finishScan(scanID: Int64, removedFiles: [String], roots: [String], full: Bool, at date: Date) {
        write { connection in
            try connection.run("DELETE FROM folders WHERE scan_id IS NULL OR scan_id != ?", [.int(scanID)])
            for path in removedFiles {
                try connection.run("DELETE FROM files WHERE path = ?", [.text(path)])
            }
            try Self.removeOrphanedMatches(connection)
            let stamp = String(date.timeIntervalSince1970)
            try Self.setMeta(MetaKey.completedAt, stamp, connection)
            if full { try Self.setMeta(MetaKey.fullCompletedAt, stamp, connection) }
            try Self.setMeta(MetaKey.roots, roots.joined(separator: "\n"), connection)
        }
    }

    // MARK: Matches

    /// Matches made by the current matcher in `language`; older ones are
    /// ignored so their titles are looked up again under the current rules.
    func loadMatches(language: String) async -> [String: GalleryMatch] {
        await read([:]) { connection in
            var matches: [String: GalleryMatch] = [:]
            let decoder = JSONDecoder()
            try connection.query(
                "SELECT key, payload FROM matches WHERE language = ? AND matcher_version = ?",
                [.text(language), .int(Int64(GalleryMatcher.version))]
            ) { row in
                guard let key = row.text(0), let payload = row.text(1),
                      let match = try? decoder.decode(GalleryMatch.self, from: Data(payload.utf8)) else { return }
                matches[key] = match
            }
            return matches
        }
    }

    func saveMatches(_ matches: [String: GalleryMatch], language: String) {
        guard !matches.isEmpty else { return }
        write { connection in
            let encoder = JSONEncoder()
            for (key, match) in matches {
                try Self.insert(match, key: key, language: language, encoder: encoder, into: connection)
            }
        }
    }

    func removeMatches(language: String) {
        write { connection in
            try connection.run("DELETE FROM matches WHERE language = ?", [.text(language)])
        }
    }

    /// Forgets every match in every language.
    func removeAllMatches() {
        write { connection in
            try connection.run("DELETE FROM matches")
        }
    }

    /// Drops matches (in every language) for titles no stored video has any
    /// more, and those made by an older matcher, which are never read again.
    private static func removeOrphanedMatches(_ connection: SQLiteConnection) throws {
        var used = Set<String>()
        try forEachCurrentFile(connection) { file, _ in used.insert(GalleryMatchKey.key(for: file.parsed)) }
        var orphaned: [String] = []
        try connection.query("SELECT DISTINCT key FROM matches") { row in
            if let key = row.text(0), !used.contains(key) { orphaned.append(key) }
        }
        for key in orphaned {
            try connection.run("DELETE FROM matches WHERE key = ?", [.text(key)])
        }
        try connection.run("DELETE FROM matches WHERE matcher_version != ?", [.int(Int64(GalleryMatcher.version))])
    }

    private static func insert(_ match: GalleryMatch, key: String, language: String, encoder: JSONEncoder, into connection: SQLiteConnection) throws {
        let payload = String(decoding: try encoder.encode(match), as: UTF8.self)
        try connection.run(
            "INSERT OR REPLACE INTO matches (language, key, matcher_version, payload) VALUES (?, ?, ?, ?)",
            [.text(language), .text(key), .int(Int64(GalleryMatcher.version)), .text(payload)]
        )
    }

    // MARK: Meta

    private enum MetaKey {
        static let lastScanID = "scan.last-id"
        static let completedAt = "scan.completed-at"
        static let fullCompletedAt = "scan.full-completed-at"
        static let roots = "scan.roots"
        static let legacyImported = "legacy.imported"
    }

    private static func meta(_ connection: SQLiteConnection) throws -> [String: String] {
        var values: [String: String] = [:]
        try connection.query("SELECT key, value FROM meta") { row in
            if let key = row.text(0), let value = row.text(1) { values[key] = value }
        }
        return values
    }

    private static func setMeta(_ key: String, _ value: String, _ connection: SQLiteConnection) throws {
        try connection.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }

    // MARK: Legacy JSON cache

    private struct LegacySnapshot: Decodable {
        var files: [LibraryFile]
        var roots: [String]
        var scannedAt: Date
    }

    /// Moves the JSON index written by the first Gallery release into the
    /// store, so upgrading neither rescans nor re-matches what it can keep.
    /// Matches are kept only when TMDB's title equals the file's title,
    /// which is what the current matcher requires.
    private static func importLegacyFiles(in directory: URL, into connection: SQLiteConnection) {
        guard (try? meta(connection)[MetaKey.legacyImported]) == nil else { return }
        let fileManager = FileManager.default
        let snapshotURL = directory.appendingPathComponent("library.json")
        let matchURLs = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("matches-") && $0.pathExtension == "json" }

        do {
            try connection.transaction {
                if let data = try? Data(contentsOf: snapshotURL), let snapshot = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
                    // The first release used the same parser (version 1), so its results stand.
                    for file in snapshot.files {
                        try insert(file, folder: AListPath.parent(of: file.path), into: connection)
                    }
                    // Old scans were full walks; folders are recorded on the next one.
                    let stamp = String(snapshot.scannedAt.timeIntervalSince1970)
                    try setMeta(MetaKey.completedAt, stamp, connection)
                    try setMeta(MetaKey.fullCompletedAt, stamp, connection)
                    try setMeta(MetaKey.roots, snapshot.roots.joined(separator: "\n"), connection)
                }
                let encoder = JSONEncoder()
                for url in matchURLs {
                    let language = String(url.deletingPathExtension().lastPathComponent.dropFirst("matches-".count))
                    guard !language.isEmpty, let data = try? Data(contentsOf: url),
                          let matches = try? JSONDecoder().decode([String: GalleryMatch].self, from: data) else { continue }
                    for (key, match) in matches where isExactLegacyMatch(match, key: key) {
                        try insert(match, key: key, language: language, encoder: encoder, into: connection)
                    }
                }
                try setMeta(MetaKey.legacyImported, "1", connection)
            }
        } catch {
            report(error)
            return
        }
        try? fileManager.removeItem(at: snapshotURL)
        for url in matchURLs { try? fileManager.removeItem(at: url) }
    }

    /// Misses stay misses (they retry on their own schedule); hits survive
    /// only when the stored TMDB title is exactly the parsed title.
    static func isExactLegacyMatch(_ match: GalleryMatch, key: String) -> Bool {
        guard match.tmdbID != nil else { return true }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, let title = match.title else { return false }
        return !parts[1].isEmpty && MediaNameParser.key(for: title) == parts[1]
    }
}
