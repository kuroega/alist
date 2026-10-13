import XCTest
@testable import AListTV

@MainActor
final class GalleryViewModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let baseURL = URL(string: "https://media.example.test")!

    override func setUp() async throws {
        directory = try GalleryFixtures.temporaryDirectory()
        suiteName = "gallery-view-model-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeViewModel(server: FakeLibraryServer, store: GalleryLibraryStore, progress: PlaybackProgressStore) -> GalleryViewModel {
        GalleryViewModel(
            api: server,
            store: store,
            progressStore: progress,
            recentItemsStore: RecentItemsStore(defaults: defaults),
            baseURL: baseURL,
            username: "alice",
            tmdbAPIKey: nil
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }

    func testOnlyExactlyMatchedTitlesLeaveTheUnindexedShelf() async throws {
        let server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
        let store = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        store.setRoots(["/Movies", "/TV"])
        // Without a TMDB key the language is "none"; seed it as if Interstellar had matched.
        store.database.saveMatches([
            "movie|interstellar|2014": GalleryMatch(tmdbID: 157_336, title: "Interstellar", genreIDs: [878], date: "2014-11-05", matchedAt: Date()),
            "movie|arrival|2016": .unmatched()
        ], language: "none")
        let progress = PlaybackProgressStore(defaults: defaults)
        progress.update(
            identity: PlaybackProgressIdentity(baseURL: baseURL.absoluteString, username: "alice", virtualPath: "/TV/Dark/Season 1/Dark.S01E01.mkv"),
            position: 600, duration: 3_000
        )

        let viewModel = makeViewModel(server: server, store: store, progress: progress)
        viewModel.onAppear()
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.videoCount == 4 }

        XCTAssertEqual(viewModel.shelves.movies.map(\.title), ["Interstellar"])
        XCTAssertTrue(viewModel.shelves.shows.isEmpty)
        XCTAssertEqual(viewModel.shelves.unwatched.count, 1)
        // The in-progress episode belongs to an un-indexed show, so it is not under Watching.
        XCTAssertTrue(viewModel.shelves.playEntries.isEmpty)
        let unindexed = Set(viewModel.shelves.unindexed.compactMap { viewModel.card(for: $0)?.title })
        XCTAssertEqual(unindexed, ["Arrival", "Dark"])
        XCTAssertEqual(viewModel.titles(in: .unindexed), viewModel.shelves.unindexed)
        XCTAssertEqual(viewModel.collectionTitle(.unindexed), "Un-indexed")
    }

    func testReopeningShowsTheStoredLibraryWithoutWalkingTheServer() async throws {
        let server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
        let store = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        store.setRoots(["/Movies", "/TV"])
        let progress = PlaybackProgressStore(defaults: defaults)

        let first = makeViewModel(server: server, store: store, progress: progress)
        first.onAppear()
        await waitUntil { first.phase == .ready && first.lastScan != nil }
        XCTAssertEqual(first.catalog.videoCount, 4)
        await store.database.flush()
        await server.resetListed()

        // A new session (e.g. after relaunch) reads the store and finds the scan fresh.
        let reopenedStore = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        let second = makeViewModel(server: server, store: reopenedStore, progress: progress)
        second.onAppear()
        await waitUntil { second.phase == .ready && second.catalog.videoCount == 4 }
        try await Task.sleep(for: .milliseconds(200))
        let listed = await server.listed
        XCTAssertTrue(listed.isEmpty, "A fresh stored library is shown without listing any folder")
        XCTAssertFalse(second.isScanning)
    }

    func testChangingLibraryFoldersDropsVideosOutsideThemImmediately() async throws {
        let server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
        let store = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        store.setRoots(["/Movies", "/TV"])
        let viewModel = makeViewModel(server: server, store: store, progress: PlaybackProgressStore(defaults: defaults))
        viewModel.onAppear()
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.videoCount == 4 }

        viewModel.removeRoot("/TV")
        XCTAssertEqual(viewModel.catalog.videoCount, 2)
        await waitUntil { viewModel.phase == .ready }
        XCTAssertEqual(viewModel.catalog.videoCount, 2)
        let stored = await store.database.loadFiles()
        XCTAssertEqual(stored.count, 2)
    }
}
