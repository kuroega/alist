import XCTest
@testable import AListTV

final class GalleryDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try GalleryFixtures.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ path: String) -> LibraryFile {
        LibraryFile(path: path, name: String(path.split(separator: "/").last ?? ""), size: 42, modified: "2026-01-02T00:00:00Z", parsed: MediaNameParser.parse(path: path))
    }

    private func match(_ id: Int?, title: String?) -> GalleryMatch {
        GalleryMatch(tmdbID: id, title: title, overview: "Overview", posterPath: "/p.jpg", backdropPath: nil, genreIDs: [878, 18], date: "2014-11-05", rating: 8.4, matchedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testListingsAndMatchesSurviveReopening() async throws {
        let episode = file("/TV/Dark/Season 1/Dark.S01E02 Lies.mkv")
        let movie = file("/Movies/Interstellar (2014)/Interstellar.2014.2160p.HDR.mkv")
        do {
            let database = GalleryDatabase(directory: directory)
            database.recordListing(folder: GalleryFolderRecord(path: "/TV/Dark/Season 1", parent: "/TV/Dark", modified: "2026-01-01T00:00:00Z", listedAt: Date()), subfolders: [], files: [episode], scanID: 1)
            database.recordListing(folder: GalleryFolderRecord(path: "/Movies/Interstellar (2014)", parent: "/Movies", modified: nil, listedAt: Date()), subfolders: [], files: [movie], scanID: 1)
            database.saveMatches(["movie|interstellar|2014": match(157_336, title: "Interstellar")], language: "en-US")
            await database.flush()
        }

        let reopened = GalleryDatabase(directory: directory)
        let files = await reopened.loadFiles().sorted { $0.path < $1.path }
        XCTAssertEqual(files, [movie, episode].sorted { $0.path < $1.path })
        XCTAssertEqual(files.first { $0.path == episode.path }?.parsed.episodeTitle, episode.parsed.episodeTitle)
        XCTAssertEqual(files.first { $0.path == movie.path }?.parsed.qualities, movie.parsed.qualities)

        let english = await reopened.loadMatches(language: "en-US")
        XCTAssertEqual(english, ["movie|interstellar|2014": match(157_336, title: "Interstellar")])
        let chinese = await reopened.loadMatches(language: "zh-CN")
        XCTAssertTrue(chinese.isEmpty, "Matches are kept per language")

        let baseline = await reopened.beginScan()
        XCTAssertEqual(baseline.folders["/TV/Dark/Season 1"]?.modified, "2026-01-01T00:00:00Z")
        XCTAssertEqual(baseline.filesByFolder["/TV/Dark/Season 1"], [episode])
        let next = await reopened.beginScan()
        XCTAssertEqual(next.scanID, baseline.scanID + 1)
    }

    func testRemovingMatchesOnlyAffectsThatLanguage() async {
        let database = GalleryDatabase(directory: directory)
        database.saveMatches(["show|dark": match(70_523, title: "Dark")], language: "en-US")
        database.saveMatches(["show|dark": match(70_523, title: "暗黑")], language: "zh-CN")
        database.removeMatches(language: "en-US")
        let english = await database.loadMatches(language: "en-US")
        let chinese = await database.loadMatches(language: "zh-CN")
        XCTAssertTrue(english.isEmpty)
        XCTAssertEqual(chinese["show|dark"]?.title, "暗黑")
    }

    func testRemovingAllMatchesClearsEveryLanguageButKeepsVideos() async {
        let database = GalleryDatabase(directory: directory)
        let video = file("/TV/Dark/Season 1/Dark.S01E01.mkv")
        database.recordListing(folder: GalleryFolderRecord(path: "/TV/Dark/Season 1", listedAt: Date()), subfolders: [], files: [video], scanID: 1)
        database.saveMatches(["show|dark": match(70_523, title: "Dark")], language: "en-US")
        database.saveMatches(["show|dark": match(70_523, title: "暗黑")], language: "zh-CN")
        database.removeAllMatches()
        let english = await database.loadMatches(language: "en-US")
        let chinese = await database.loadMatches(language: "zh-CN")
        XCTAssertTrue(english.isEmpty)
        XCTAssertTrue(chinese.isEmpty)
        let files = await database.loadFiles()
        XCTAssertEqual(files, [video])
    }

    func testFinishScanRemovesUnseenFoldersAndReportedFiles() async {
        let database = GalleryDatabase(directory: directory)
        let kept = file("/Movies/A/A.mkv")
        let gone = file("/Movies/B/B.mkv")
        database.recordListing(folder: GalleryFolderRecord(path: "/Movies/A", parent: "/Movies", modified: "2026-01-01T00:00:00Z", listedAt: Date()), subfolders: [], files: [kept], scanID: 1)
        database.recordListing(folder: GalleryFolderRecord(path: "/Movies/B", parent: "/Movies", modified: "2026-01-01T00:00:00Z", listedAt: Date()), subfolders: [], files: [gone], scanID: 1)
        database.markSeen(["/Movies/A"], scanID: 2)
        database.finishScan(scanID: 2, removedFiles: [gone.path], roots: ["/Movies"], full: false, at: Date(timeIntervalSince1970: 1_900_000_000))

        let files = await database.loadFiles()
        XCTAssertEqual(files, [kept])
        let baseline = await database.beginScan()
        XCTAssertEqual(Set(baseline.folders.keys), ["/Movies/A"])
        let state = await database.loadScanState()
        XCTAssertEqual(state.completedAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertNil(state.fullCompletedAt)
        XCTAssertEqual(state.roots, ["/Movies"])
    }

    func testFirstReleaseJSONCacheIsImportedOnceKeepingOnlyExactMatches() async throws {
        struct LegacySnapshot: Encodable {
            var files: [LibraryFile]
            var roots: [String]
            var scannedAt: Date
        }
        let movie = file("/Movies/Interstellar (2014)/Interstellar.2014.mkv")
        let scannedAt = Date(timeIntervalSince1970: 1_790_000_000)
        try JSONEncoder().encode(LegacySnapshot(files: [movie], roots: ["/Movies"], scannedAt: scannedAt))
            .write(to: directory.appendingPathComponent("library.json"))
        let legacyMatches: [String: GalleryMatch] = [
            "movie|interstellar|2014": match(157_336, title: "Interstellar"),
            // A fuzzy pick from the old matcher: TMDB's title differs from the file's.
            "movie|arrivals|": match(329_865, title: "Arrival"),
            "movie|homevideo|": match(nil, title: nil)
        ]
        try JSONEncoder().encode(legacyMatches).write(to: directory.appendingPathComponent("matches-en-US.json"))

        let database = GalleryDatabase(directory: directory)
        let files = await database.loadFiles()
        XCTAssertEqual(files, [movie])
        let matches = await database.loadMatches(language: "en-US")
        XCTAssertEqual(Set(matches.keys), ["movie|interstellar|2014", "movie|homevideo|"])
        let state = await database.loadScanState()
        XCTAssertEqual(state.completedAt, scannedAt)
        XCTAssertEqual(state.roots, ["/Movies"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("matches-en-US.json").path))

        // Imported once: a later stray JSON file is not read again.
        try JSONEncoder().encode(LegacySnapshot(files: [file("/Movies/Other/Other.mkv")], roots: [], scannedAt: scannedAt))
            .write(to: directory.appendingPathComponent("library.json"))
        let reopened = GalleryDatabase(directory: directory)
        let reopenedFiles = await reopened.loadFiles()
        XCTAssertEqual(reopenedFiles, [movie])
    }

    func testDamagedStoreStartsOver() async throws {
        try Data("not a database".utf8).write(to: directory.appendingPathComponent(GalleryDatabase.fileName))
        let database = GalleryDatabase(directory: directory)
        database.saveMatches(["show|dark": match(70_523, title: "Dark")], language: "en-US")
        let matches = await database.loadMatches(language: "en-US")
        XCTAssertEqual(matches.count, 1)
    }

    func testStoredParseIsTrustedAtTheCurrentParserVersion() async throws {
        let database = GalleryDatabase(directory: directory)
        let stale = LibraryFile(path: "/TV/Dark/Season 1/Dark.S01E03.mkv", name: "Dark.S01E03.mkv", size: 1, modified: nil, parsed: ParsedMedia(kind: .movie, title: "Wrong", qualities: []))
        database.recordListing(folder: GalleryFolderRecord(path: "/TV/Dark/Season 1", listedAt: Date()), subfolders: [], files: [stale], scanID: 1)
        await database.flush()
        let files = await database.loadFiles()
        // Same parser version: the stored result is trusted as is.
        XCTAssertEqual(files.first?.parsed.title, "Wrong")
    }

    func testLegacyMatchExactness() {
        XCTAssertTrue(GalleryDatabase.isExactLegacyMatch(match(1, title: "Spider-Man: No Way Home"), key: "movie|spidermannowayhome|2021"))
        XCTAssertTrue(GalleryDatabase.isExactLegacyMatch(match(nil, title: nil), key: "show|whatever"))
        XCTAssertFalse(GalleryDatabase.isExactLegacyMatch(match(1, title: "The Office"), key: "show|theofficeus"))
        XCTAssertFalse(GalleryDatabase.isExactLegacyMatch(match(1, title: nil), key: "show|dark"))
    }
}
