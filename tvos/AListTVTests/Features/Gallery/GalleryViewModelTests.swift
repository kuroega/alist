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

    func testExcludingDropsVideosAtOnceAndIncludingBringsThemBack() async throws {
        let server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
        let store = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        store.setRoots(["/Movies", "/TV"])
        let viewModel = makeViewModel(server: server, store: store, progress: PlaybackProgressStore(defaults: defaults))
        viewModel.onAppear()
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.videoCount == 4 }

        viewModel.exclude(["/TV/Dark"])
        XCTAssertEqual(viewModel.catalog.videoCount, 2)
        XCTAssertTrue(viewModel.isExcluded("/TV/Dark/Season 1/Dark.S01E01.mkv"))
        await waitUntil { viewModel.phase == .ready }
        await store.database.flush()
        var stored = await store.database.loadFiles()
        XCTAssertEqual(stored.count, 2, "The next update drops excluded videos from the index")
        XCTAssertEqual(store.excluded, ["/TV/Dark"])

        viewModel.include("/TV/Dark")
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.videoCount == 4 }
        await store.database.flush()
        stored = await store.database.loadFiles()
        XCTAssertEqual(stored.count, 4)
        XCTAssertTrue(viewModel.excluded.isEmpty)
    }

    func testOnlyPathsInsideLibraryFoldersCanBeExcluded() async throws {
        let server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
        let store = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        store.setRoots(["/Movies", "/TV"])
        let viewModel = makeViewModel(server: server, store: store, progress: PlaybackProgressStore(defaults: defaults))
        viewModel.onAppear()
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.videoCount == 4 }

        XCTAssertFalse(viewModel.canExclude("/Movies"), "A library folder is removed, not excluded")
        XCTAssertFalse(viewModel.canExclude("/Music"))
        XCTAssertTrue(viewModel.canExclude("/Movies/Arrival (2016)"))
        let interstellar = try XCTUnwrap(viewModel.catalog.title(forPath: "/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv"))
        XCTAssertEqual(viewModel.excludableFolder(for: interstellar), "/Movies/Interstellar (2014)")
        let dark = try XCTUnwrap(viewModel.catalog.title(forPath: "/TV/Dark/Season 1/Dark.S01E01.mkv"))
        XCTAssertEqual(viewModel.excludableFolder(for: dark), "/TV/Dark/Season 1")

        viewModel.exclude(["/TV/Dark/Season 1/Dark.S01E01.mkv"])
        viewModel.exclude(["/TV/Dark"])
        XCTAssertEqual(viewModel.excluded, ["/TV/Dark"], "An exclusion inside a newly excluded folder is dropped")
        XCTAssertFalse(viewModel.canExclude("/TV/Dark/Season 1"), "Already excluded through its parent")
        XCTAssertFalse(viewModel.isExclusion("/TV/Dark/Season 1"))

        viewModel.removeRoot("/TV")
        XCTAssertTrue(viewModel.excluded.isEmpty, "Exclusions outside every library folder are forgotten")
        await waitUntil { viewModel.phase == .ready }
    }

    func testRemovingATitleFromWatchingClearsOnlyItsResumePoints() async throws {
        let server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
        let store = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        store.setRoots(["/Movies", "/TV"])
        store.database.saveMatches([
            "movie|interstellar|2014": GalleryMatch(tmdbID: 157_336, title: "Interstellar", genreIDs: [878], date: "2014-11-05", matchedAt: Date()),
            "show|dark": GalleryMatch(tmdbID: 70_523, title: "Dark", genreIDs: [], date: "2017-12-01", matchedAt: Date())
        ], language: "none")
        let progress = PlaybackProgressStore(defaults: defaults)
        let identity = { (path: String) in PlaybackProgressIdentity(baseURL: self.baseURL.absoluteString, username: "alice", virtualPath: path) }
        let episodes = ["/TV/Dark/Season 1/Dark.S01E01.mkv", "/TV/Dark/Season 1/Dark.S01E02.mkv"]
        let movie = "/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv"
        for path in episodes + [movie] {
            progress.update(identity: identity(path), position: 600, duration: 3_000)
        }
        RecentItemsStore(defaults: defaults).recordOpen(
            AListObject(virtualPath: episodes[1], name: "Dark.S01E02.mkv", isDirectory: false),
            account: RecentItemsAccount(baseURL: baseURL.absoluteString, username: "alice")
        )

        let viewModel = makeViewModel(server: server, store: store, progress: progress)
        viewModel.onAppear()
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.videoCount == 4 }
        let dark = try XCTUnwrap(viewModel.shelves.playEntries.first { $0.path.hasPrefix("/TV/Dark") }?.title)
        XCTAssertEqual(viewModel.shelves.playEntries.filter { $0.section == .watching }.count, 2)

        viewModel.removeFromWatching(dark)

        // Both episodes lose their resume point, so the show cannot resurface
        // under Watching through the other one; the movie keeps its own.
        XCTAssertTrue(episodes.allSatisfy { progress.record(for: identity($0)) == nil })
        XCTAssertNotNil(progress.record(for: identity(movie)))
        XCTAssertEqual(viewModel.shelves.playEntries.filter { $0.section == .watching }.map(\.path), [movie])
        // The opened episode stays in history, under Recently Watched.
        XCTAssertEqual(viewModel.shelves.playEntries.filter { $0.section == .recent }.map(\.path), [episodes[1]])
    }
}
