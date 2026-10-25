import XCTest
@testable import AListTV

final class GalleryMatchFixingTests: XCTestCase {
    private func file(_ path: String) -> LibraryFile {
        LibraryFile(path: path, name: String(path.split(separator: "/").last ?? ""), size: 1, modified: nil, parsed: MediaNameParser.parse(path: path))
    }

    // MARK: Names

    func testTechnicalTailKeepsReleaseTagsAsWritten() {
        XCTAssertEqual(MediaNameParser.technicalTail(of: "American.Horror.Story.S13E08.2160p.HULU.WEB-DL.DDP5.1.H.265-SmartWeb"), "2160p.HULU.WEB-DL.DDP5.1.H.265-SmartWeb")
        XCTAssertEqual(MediaNameParser.technicalTail(of: "[Group] Frieren - 05 [1080p]"), "[1080p]")
        XCTAssertNil(MediaNameParser.technicalTail(of: "Dark S01E01"))
    }

    func testEpisodeNameUsesTitleYearAndCodeAndKeepsReleaseTags() throws {
        let episode = file("/kk/电视剧/American.Horror.Story.2011.S13.2160p.HULU.WEB-DL.DDP5.1.H.265-SmartWeb/American.Horror.Story.S13E08.2160p.HULU.WEB-DL.DDP5.1.H.265-SmartWeb.mkv")
        let name = try XCTUnwrap(GalleryRenamer.videoName(for: episode, title: "American Horror Story", year: 2011))
        XCTAssertEqual(name, "American Horror Story (2011) S13E08 2160p.HULU.WEB-DL.DDP5.1.H.265-SmartWeb.mkv")
    }

    func testMovieNameIsReadBackAsTheSameTitleAndYear() throws {
        let movie = file("/Movies/amelie.2001.1080p.BluRay.x264.mkv")
        let name = try XCTUnwrap(GalleryRenamer.videoName(for: movie, title: "Le Fabuleux Destin d'Amélie Poulain", year: 2001))
        XCTAssertEqual(name, "Le Fabuleux Destin d'Amélie Poulain (2001) 1080p.BluRay.x264.mkv")
        let parsed = MediaNameParser.parse(path: "/Movies/" + name)
        XCTAssertEqual(parsed.kind, .movie)
        XCTAssertEqual(parsed.year, 2001)
        XCTAssertEqual(parsed.titleKey, MediaNameParser.key(for: "Le Fabuleux Destin d'Amélie Poulain"))
    }

    func testSafeNameDropsCharactersStorageRefuses() {
        XCTAssertEqual(GalleryRenamer.safeName("Mission: Impossible"), "Mission - Impossible")
        XCTAssertEqual(GalleryRenamer.safeName("AC/DC: Live?"), "AC-DC - Live")
    }

    // MARK: Plan

    func testPlanPairsSubtitlesSkipsClashesAndKeepsCorrectNames() {
        let folder = "/Shows/Show"
        let names = [
            "Show.S01E01.mkv", "Show.S01E01.en.srt",
            "Show.S01E01.Directors.Cut.mkv", "Show.S01E01.Directors.Cut.zh.ass",
            "Show.S01E02.mkv", "Show (2020) S01E02.mkv",
            "Show (2020) S01E03.mkv", "notes.txt"
        ]
        let videos = ["Show.S01E01.mkv", "Show.S01E01.Directors.Cut.mkv", "Show.S01E02.mkv", "Show (2020) S01E03.mkv"].map { file(folder + "/" + $0) }
        let plan = GalleryRenamer.plan(videos: videos, title: "Show", year: 2020, folderContents: [folder: names])

        let renames = Dictionary(uniqueKeysWithValues: plan.groups.flatMap { [$0.video] + $0.subtitles }.map { ($0.name, $0.newName) })
        XCTAssertEqual(renames, [
            "Show.S01E01.mkv": "Show (2020) S01E01.mkv",
            "Show.S01E01.en.srt": "Show (2020) S01E01.en.srt",
            "Show.S01E01.Directors.Cut.mkv": "Show (2020) S01E01 Directors Cut.mkv",
            "Show.S01E01.Directors.Cut.zh.ass": "Show (2020) S01E01 Directors Cut.zh.ass"
        ])
        XCTAssertEqual(plan.fileCount, 4)
        XCTAssertEqual(plan.skipped.map(\.path), [folder + "/Show.S01E02.mkv"])
        XCTAssertEqual(plan.unchanged, [folder + "/Show (2020) S01E03.mkv"])
    }

    func testPlanLeavesVideosInUnreadableFoldersAlone() {
        let plan = GalleryRenamer.plan(videos: [file("/Offline/Dark.S01E01.mkv")], title: "Dark", year: 2017, folderContents: [:])
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertEqual(plan.skipped.first?.reason, "Its folder couldn’t be read.")
    }

    // MARK: Ranking

    func testRankingPutsTheClosestNameAndYearFirst() {
        func show(_ id: Int, _ name: String, _ date: String, votes: Int) -> GalleryCandidate {
            GalleryCandidate(show: TMDBShowResult(id: id, name: name, originalName: name, overview: nil, posterPath: nil, backdropPath: nil, genreIds: nil, firstAirDate: date, voteAverage: 7, voteCount: votes, popularity: nil))
        }
        let ranked = GalleryMatcher.rank([
            show(1, "Breaking Bad", "2008-01-20", votes: 15_000),
            show(2, "Dark Matter", "2024-05-08", votes: 500),
            show(3, "Darkk", "2017-12-01", votes: 60),
            show(4, "The Dark Knight Returns", "2012-01-01", votes: 30_000)
        ], title: "Dark", year: 2017)
        // Closest name first; equally close names go to the better known
        // entry; fame never lifts an unrelated name above close ones.
        XCTAssertEqual(ranked.map(\.tmdbID), [3, 4, 2, 1])
        XCTAssertEqual(GalleryMatcher.similarity("dark", "dark"), 1)
        XCTAssertGreaterThanOrEqual(GalleryMatcher.similarity("dark", "darkmatter"), 0.8)
    }

    func testLooseQueriesShortenLongNames() {
        XCTAssertEqual(GalleryMatcher.looseQueries(for: "The Office US Extras"), ["The Office US Extras", "The Office US", "The Office"])
    }

    // MARK: Path-keyed state

    func testRenamedFileKeepsItsResumePointWatchedMarkAndRecentEntry() throws {
        let suite = "match-fixing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = { PlaybackProgressIdentity(baseURL: "https://media.example.test", username: "alice", virtualPath: $0) }
        let progress = PlaybackProgressStore(defaults: defaults)
        progress.update(identity: identity("/a.mkv"), position: 600, duration: 3_000)
        progress.setWatched(true, identity: identity("/b.mkv"))
        progress.move(from: identity("/a.mkv"), to: identity("/A (2020).mkv"))
        progress.move(from: identity("/b.mkv"), to: identity("/B (2020).mkv"))
        XCTAssertNil(progress.record(for: identity("/a.mkv")))
        XCTAssertEqual(progress.record(for: identity("/A (2020).mkv"))?.position, 600)
        XCTAssertEqual(progress.watchedRecords().map(\.identity.virtualPath), ["/B (2020).mkv"])

        let account = RecentItemsAccount(baseURL: "https://media.example.test", username: "alice")
        let recents = RecentItemsStore(defaults: defaults)
        recents.recordOpen(AListObject(virtualPath: "/a.mkv", name: "a.mkv", isDirectory: false), account: account)
        let moved = recents.move(path: "/a.mkv", to: "/A (2020).mkv", name: "A (2020).mkv", account: account)
        XCTAssertEqual(moved.map(\.object.virtualPath), ["/A (2020).mkv"])
        XCTAssertEqual(moved.first?.object.name, "A (2020).mkv")
    }
}

@MainActor
final class GalleryMatchApplyTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let baseURL = URL(string: "https://media.example.test")!

    override func setUp() async throws {
        directory = try GalleryFixtures.temporaryDirectory()
        suiteName = "gallery-match-apply-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }

    func testRenamingAndMatchingIndexesTheShowAndCarriesItsProgress() async throws {
        let server = FakeLibraryServer()
        await GalleryFixtures.populate(server)
        let season = "/TV/Dark/Season 1"
        await server.setFolder(season, [
            GalleryFixtures.video("\(season)/Dark.S01E01.mkv"),
            AListObject(virtualPath: "\(season)/Dark.S01E01.en.srt", name: "Dark.S01E01.en.srt", isDirectory: false),
            GalleryFixtures.video("\(season)/Dark.S01E02.mkv")
        ])
        await server.setRefusesRename(["\(season)/Dark.S01E02.mkv"])
        let store = GalleryLibraryStore(baseURL: baseURL, username: "alice", defaults: defaults, directory: directory)
        store.setRoots(["/TV"])
        let progress = PlaybackProgressStore(defaults: defaults)
        let identity = { PlaybackProgressIdentity(baseURL: self.baseURL.absoluteString, username: "alice", virtualPath: $0) }
        progress.update(identity: identity("\(season)/Dark.S01E01.mkv"), position: 600, duration: 3_000)

        let viewModel = GalleryViewModel(
            api: server, store: store, progressStore: progress, recentItemsStore: RecentItemsStore(defaults: defaults),
            baseURL: baseURL, username: "alice", tmdbAPIKey: nil
        )
        viewModel.onAppear()
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.videoCount == 2 }
        let title = try XCTUnwrap(viewModel.shelves.unindexed.first)
        XCTAssertEqual(viewModel.parsedMedia(for: title)?.title, "Dark")

        let match = GalleryMatch(tmdbID: 70_523, title: "Dark", genreIDs: [18], date: "2017-12-01", matchedAt: Date())
        let candidate = GalleryCandidate(show: TMDBShowResult(id: 70_523, name: "Dark", originalName: "Dark", overview: nil, posterPath: nil, backdropPath: nil, genreIds: [18], firstAirDate: "2017-12-01", voteAverage: 8.4, voteCount: 6_000, popularity: nil))
        let plan = GalleryRenamer.plan(videos: viewModel.videos(for: title), title: "Dark", year: 2017, folderContents: [season: await server.names(in: season)])
        XCTAssertEqual(plan.fileCount, 3)
        let proposal = GalleryMatchProposal(candidate: candidate, match: match, fileTitle: "Dark", year: 2017, plan: plan)

        let outcome = await viewModel.apply(proposal, to: title, renaming: true)

        XCTAssertTrue(outcome.matched)
        XCTAssertEqual(outcome.renamed.map(\.newName), ["Dark (2017) S01E01.mkv", "Dark (2017) S01E01.en.srt"])
        XCTAssertEqual(outcome.failures.map(\.path), ["\(season)/Dark.S01E02.mkv"])
        // Indexed at once, before the folder is read again.
        XCTAssertEqual(viewModel.shelves.shows.map(\.tmdbID), [70_523])
        XCTAssertNil(progress.record(for: identity("\(season)/Dark.S01E01.mkv")))
        XCTAssertEqual(progress.record(for: identity("\(season)/Dark (2017) S01E01.mkv"))?.position, 600)

        // The follow-up scan picks up the new names and the show stays matched.
        await waitUntil { viewModel.phase == .ready && viewModel.catalog.title(forPath: "\(season)/Dark (2017) S01E01.mkv") != nil }
        XCTAssertNil(viewModel.catalog.title(forPath: "\(season)/Dark.S01E01.mkv"))
        XCTAssertEqual(viewModel.shelves.shows.map(\.tmdbID), [70_523])
        XCTAssertEqual(viewModel.shelves.shows.first?.episodes.count, 2)
        XCTAssertTrue(viewModel.shelves.unindexed.isEmpty)
    }
}
