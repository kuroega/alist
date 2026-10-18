import XCTest
@testable import AListTV

final class LibraryScannerTests: XCTestCase {
    private var directory: URL!
    private var database: GalleryDatabase!
    private var server: FakeLibraryServer!
    private let roots = ["/Movies", "/TV"]

    override func setUp() async throws {
        directory = try GalleryFixtures.temporaryDirectory()
        database = GalleryDatabase(directory: directory)
        server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func scan(_ mode: LibraryScanner.Mode, excluded: [String] = [], recorder: ScanRecorder = ScanRecorder()) async throws -> LibraryScanResult {
        var scanner = LibraryScanner(api: server, database: database)
        scanner.excluded = excluded
        let result = try await scanner.scan(roots: roots, mode: mode, progress: { _ in }, changes: { recorder.record($0) })
        await database.flush()
        return result
    }

    private func storedPaths() async -> Set<String> {
        Set(await database.loadFiles().map(\.path))
    }

    private let allVideos: Set<String> = [
        "/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv",
        "/Movies/Arrival (2016)/Arrival.2016.1080p.mkv",
        "/TV/Dark/Season 1/Dark.S01E01.mkv",
        "/TV/Dark/Season 1/Dark.S01E02.mkv"
    ]

    func testFirstScanIndexesEveryVideoAndSavesIt() async throws {
        let recorder = ScanRecorder()
        let result = try await scan(.quick, recorder: recorder)

        XCTAssertEqual(result, LibraryScanResult(isComplete: true, foldersListed: 6, foldersReused: 0, foldersFailed: 0))
        XCTAssertEqual(Set(recorder.upserted.keys), allVideos)
        XCTAssertTrue(recorder.removed.isEmpty)
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos)
        let state = await database.loadScanState()
        XCTAssertNotNil(state.completedAt)
        XCTAssertNotNil(state.fullCompletedAt, "A pass that listed every folder counts as full")
        XCTAssertEqual(state.roots, roots)
    }

    func testUpdateSkipsUnchangedFoldersWithoutSubfolders() async throws {
        try await scan(.quick)
        await server.resetListed()

        let recorder = ScanRecorder()
        let result = try await scan(.quick, recorder: recorder)

        let listed = await server.listed
        XCTAssertEqual(Set(listed), ["/Movies", "/TV", "/TV/Dark"])
        XCTAssertEqual(result.foldersReused, 3)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(recorder.upserted.isEmpty && recorder.removed.isEmpty, "Nothing changed, so nothing is reported")
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos)
        let state = await database.loadScanState()
        XCTAssertNotNil(state.fullCompletedAt)
    }

    func testFolderWithNewModifiedTimeIsListedAndOnlyNewVideosAreReported() async throws {
        try await scan(.quick)
        await server.setFolder("/TV/Dark", [GalleryFixtures.folder("/TV/Dark/Season 1", modified: "2026-03-01T00:00:00Z")])
        await server.setFolder("/TV/Dark/Season 1", [
            GalleryFixtures.video("/TV/Dark/Season 1/Dark.S01E01.mkv"),
            GalleryFixtures.video("/TV/Dark/Season 1/Dark.S01E02.mkv"),
            GalleryFixtures.video("/TV/Dark/Season 1/Dark.S01E03.mkv")
        ])
        await server.resetListed()

        let recorder = ScanRecorder()
        try await scan(.quick, recorder: recorder)

        let listed = await server.listed
        XCTAssertTrue(listed.contains("/TV/Dark/Season 1"))
        XCTAssertFalse(listed.contains("/Movies/Arrival (2016)"))
        XCTAssertEqual(Set(recorder.upserted.keys), ["/TV/Dark/Season 1/Dark.S01E03.mkv"])
        XCTAssertEqual(recorder.upserted["/TV/Dark/Season 1/Dark.S01E03.mkv"]?.parsed.episode, 3)
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos.union(["/TV/Dark/Season 1/Dark.S01E03.mkv"]))
    }

    func testExcludedFolderIsNotListedAndExcludedVideoIsNotIndexed() async throws {
        let arrival = "/Movies/Arrival (2016)/Arrival.2016.1080p.mkv"
        let recorder = ScanRecorder()
        try await scan(.quick, excluded: ["/TV/Dark", arrival], recorder: recorder)

        let listed = await server.listed
        XCTAssertFalse(listed.contains { $0.hasPrefix("/TV/Dark") }, "Nothing below an excluded folder is listed")
        XCTAssertEqual(Set(recorder.upserted.keys), ["/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv"])
        let stored = await storedPaths()
        XCTAssertEqual(stored, ["/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv"])
    }

    func testExcludingAfterAScanRemovesWhatWasStoredAndIncludingBringsItBack() async throws {
        let arrival = "/Movies/Arrival (2016)/Arrival.2016.1080p.mkv"
        try await scan(.quick)

        // The view model makes the folders holding a changed path list again.
        database.forgetListing(of: "/TV")
        database.forgetListing(of: "/Movies/Arrival (2016)")
        let recorder = ScanRecorder()
        try await scan(.quick, excluded: ["/TV/Dark", arrival], recorder: recorder)
        XCTAssertEqual(recorder.removed, ["/TV/Dark/Season 1/Dark.S01E01.mkv", "/TV/Dark/Season 1/Dark.S01E02.mkv", arrival])
        var stored = await storedPaths()
        XCTAssertEqual(stored, ["/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv"])

        database.forgetListing(of: "/TV")
        database.forgetListing(of: "/Movies/Arrival (2016)")
        let restored = ScanRecorder()
        try await scan(.quick, recorder: restored)
        XCTAssertEqual(Set(restored.upserted.keys), allVideos.subtracting(["/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv"]))
        stored = await storedPaths()
        XCTAssertEqual(stored, allVideos)
    }

    func testDeletedFolderRemovesItsVideos() async throws {
        try await scan(.quick)
        await server.setFolder("/Movies", [GalleryFixtures.folder("/Movies/Interstellar (2014)")])
        await server.removeFolder("/Movies/Arrival (2016)")

        let recorder = ScanRecorder()
        try await scan(.quick, recorder: recorder)

        XCTAssertEqual(recorder.removed, ["/Movies/Arrival (2016)/Arrival.2016.1080p.mkv"])
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos.subtracting(["/Movies/Arrival (2016)/Arrival.2016.1080p.mkv"]))
    }

    func testDeletedVideoInListedFolderIsRemoved() async throws {
        try await scan(.quick)
        await server.setFolder("/TV/Dark", [GalleryFixtures.folder("/TV/Dark/Season 1", modified: "2026-04-01T00:00:00Z")])
        await server.setFolder("/TV/Dark/Season 1", [GalleryFixtures.video("/TV/Dark/Season 1/Dark.S01E01.mkv")])

        let recorder = ScanRecorder()
        try await scan(.quick, recorder: recorder)

        XCTAssertEqual(recorder.removed, ["/TV/Dark/Season 1/Dark.S01E02.mkv"])
        XCTAssertTrue(recorder.upserted.isEmpty)
        let stored = await storedPaths()
        XCTAssertFalse(stored.contains("/TV/Dark/Season 1/Dark.S01E02.mkv"))
    }

    func testDeletedLibraryFolderRemovesEverythingBelowIt() async throws {
        try await scan(.quick)
        await server.removeFolder("/TV")

        let recorder = ScanRecorder()
        let result = try await scan(.quick, recorder: recorder)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.foldersMissing, 1)
        XCTAssertEqual(result.foldersFailed, 0, "A folder the server says is gone is not an unreadable one")
        XCTAssertEqual(recorder.removed, ["/TV/Dark/Season 1/Dark.S01E01.mkv", "/TV/Dark/Season 1/Dark.S01E02.mkv"])
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos.filter { $0.hasPrefix("/Movies/") })
        let baseline = await database.beginScan()
        XCTAssertNil(baseline.folders["/TV/Dark"])
        XCTAssertNil(baseline.folders["/TV/Dark/Season 1"])
    }

    func testEveryLibraryFolderDeletedEmptiesTheLibrary() async throws {
        try await scan(.quick)
        for path in roots { await server.removeFolder(path) }

        let recorder = ScanRecorder()
        let result = try await scan(.quick, recorder: recorder)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(recorder.removed, allVideos)
        let stored = await storedPaths()
        XCTAssertTrue(stored.isEmpty)
    }

    func testCompleteScanForgetsMatchesOfRemovedTitles() async throws {
        try await scan(.quick)
        let key = { (path: String) in GalleryMatchKey.key(for: MediaNameParser.parse(path: path)) }
        let arrival = key("/Movies/Arrival (2016)/Arrival.2016.1080p.mkv")
        let interstellar = key("/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv")
        let dark = key("/TV/Dark/Season 1/Dark.S01E01.mkv")
        let hit = GalleryMatch(tmdbID: 1, title: "Title", genreIDs: [], matchedAt: Date())
        for language in ["en-US", "zh-CN"] {
            database.saveMatches([arrival: hit, interstellar: hit, dark: hit], language: language)
        }
        await server.setFolder("/Movies", [GalleryFixtures.folder("/Movies/Interstellar (2014)")])
        await server.removeFolder("/Movies/Arrival (2016)")

        try await scan(.quick)

        for language in ["en-US", "zh-CN"] {
            let matches = await database.loadMatches(language: language)
            XCTAssertEqual(Set(matches.keys), [interstellar, dark], language)
        }
    }

    func testIncompleteScanKeepsMatches() async throws {
        try await scan(.quick)
        let arrival = GalleryMatchKey.key(for: MediaNameParser.parse(path: "/Movies/Arrival (2016)/Arrival.2016.1080p.mkv"))
        database.saveMatches([arrival: GalleryMatch(tmdbID: 1, title: "Arrival", genreIDs: [], matchedAt: Date())], language: "en-US")
        for path in roots { await server.setUnreadable(path, true) }

        try await scan(.full)

        let matches = await database.loadMatches(language: "en-US")
        XCTAssertEqual(Set(matches.keys), [arrival])
    }

    func testOnlyNotFoundCountsAsDeleted() {
        XCTAssertTrue(LibraryScanner.isNotFound(AListAPIError.server(code: 500, message: "failed get objs: failed get dir: object not found")))
        XCTAssertFalse(LibraryScanner.isNotFound(AListAPIError.server(code: 500, message: "failed get storage: storage not found; please add a storage first")))
        XCTAssertFalse(LibraryScanner.isNotFound(AListAPIError.server(code: 500, message: "storage not init: network error")))
        XCTAssertFalse(LibraryScanner.isNotFound(AListAPIError.transport(message: "object not found")))
    }

    func testUnreadableFolderKeepsWhatWasKnownBelowIt() async throws {
        try await scan(.quick)
        await server.setUnreadable("/TV/Dark", true)

        let recorder = ScanRecorder()
        let result = try await scan(.quick, recorder: recorder)

        XCTAssertEqual(result.foldersFailed, 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(recorder.removed.isEmpty)
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos)

        // Once it reads again, the reused season is still known and nothing churns.
        await server.setUnreadable("/TV/Dark", false)
        let later = ScanRecorder()
        try await scan(.quick, recorder: later)
        XCTAssertTrue(later.upserted.isEmpty && later.removed.isEmpty)
        let restored = await storedPaths()
        XCTAssertEqual(restored, allVideos)
    }

    func testUnreachableServerRemovesNothing() async throws {
        try await scan(.quick)
        for path in roots { await server.setUnreadable(path, true) }

        let recorder = ScanRecorder()
        let result = try await scan(.full, recorder: recorder)

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.foldersListed, 0)
        XCTAssertTrue(recorder.removed.isEmpty)
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos)
    }

    func testFullScanListsEveryFolder() async throws {
        try await scan(.quick)
        await server.resetListed()

        let result = try await scan(.full)

        let listed = await server.listed
        XCTAssertEqual(listed.count, 6)
        XCTAssertEqual(result.foldersReused, 0)
    }

    func testFoldersWithoutRealModifiedTimesAreAlwaysListed() async throws {
        await server.setFolder("/Movies", [
            GalleryFixtures.folder("/Movies/Interstellar (2014)", modified: "0001-01-01T00:00:00Z"),
            GalleryFixtures.folder("/Movies/Arrival (2016)", modified: "")
        ])
        try await scan(.quick)
        await server.resetListed()

        try await scan(.quick)

        let listed = await server.listed
        XCTAssertTrue(listed.contains("/Movies/Interstellar (2014)"))
        XCTAssertTrue(listed.contains("/Movies/Arrival (2016)"))
        XCTAssertFalse(listed.contains("/TV/Dark/Season 1"))
    }

    func testFilesOutsideTheLibraryFoldersAreDroppedAfterRootsChange() async throws {
        try await scan(.quick)
        let scanner = LibraryScanner(api: server, database: database)
        let recorder = ScanRecorder()
        let result = try await scanner.scan(roots: ["/Movies"], mode: .quick, progress: { _ in }, changes: { recorder.record($0) })
        await database.flush()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(recorder.removed, ["/TV/Dark/Season 1/Dark.S01E01.mkv", "/TV/Dark/Season 1/Dark.S01E02.mkv"])
        let stored = await storedPaths()
        XCTAssertEqual(stored, allVideos.filter { $0.hasPrefix("/Movies/") })
    }

    func testTrustworthyModifiedTimes() {
        XCTAssertTrue(LibraryScanner.isTrustworthyModified("2024-05-01T10:00:00.123456789+08:00"))
        XCTAssertFalse(LibraryScanner.isTrustworthyModified("0001-01-01T00:00:00Z"))
        XCTAssertFalse(LibraryScanner.isTrustworthyModified(""))
        XCTAssertFalse(LibraryScanner.isTrustworthyModified("1970-01-01T00:00:00Z"))
    }

    func testIsInsideRoots() {
        XCTAssertTrue(LibraryScanner.isInside("/Movies/A/a.mkv", roots: ["/Movies"]))
        XCTAssertFalse(LibraryScanner.isInside("/Movies2/a.mkv", roots: ["/Movies"]))
        XCTAssertTrue(LibraryScanner.isInside("/Anything/a.mkv", roots: []))
    }
}
