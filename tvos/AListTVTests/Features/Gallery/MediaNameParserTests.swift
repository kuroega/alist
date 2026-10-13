import XCTest
@testable import AListTV

final class MediaNameParserTests: XCTestCase {
    private func parse(_ path: String) -> ParsedMedia { MediaNameParser.parse(path: path) }

    // MARK: Movies

    func testReleaseNameKeepsTitleAndYearAndDropsEncodingTags() {
        let media = parse("/Movies/Interstellar (2014)/Interstellar.2014.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-EPSiLON.mkv")
        XCTAssertEqual(media.kind, .movie)
        XCTAssertEqual(media.title, "Interstellar")
        XCTAssertEqual(media.year, 2014)
        XCTAssertEqual(media.qualities, ["4K", "HDR", "Atmos", "Remux"])
    }

    func testNumbersInTitlesAreNotMistakenForYears() {
        XCTAssertEqual(parse("/M/Blade.Runner.2049.2017.1080p.mkv").title, "Blade Runner 2049")
        XCTAssertEqual(parse("/M/Blade.Runner.2049.2017.1080p.mkv").year, 2017)
        XCTAssertEqual(parse("/M/Blade.Runner.2049.mkv").title, "Blade Runner 2049")
        XCTAssertNil(parse("/M/Blade.Runner.2049.mkv").year)
        XCTAssertEqual(parse("/M/1917.2019.1080p.WEB-DL.mkv").title, "1917")
        XCTAssertEqual(parse("/M/2001.A.Space.Odyssey.1968.mkv").title, "2001 A Space Odyssey")
    }

    func testReleaseWordsBeforeTheYearStayInTheTitle() {
        XCTAssertEqual(parse("/M/Charlotte's.Web.2006.720p.mkv").title, "Charlotte's Web")
        XCTAssertEqual(parse("/M/A.Complete.Unknown.2024.mkv").title, "A Complete Unknown")
    }

    func testGenericFileNameUsesItsTitledFolder() {
        let media = parse("/Movies/A Complete Unknown (2024)/movie.mkv")
        XCTAssertEqual(media.title, "A Complete Unknown")
        XCTAssertEqual(media.year, 2024)
    }

    func testChineseSiteTagsAndSubtitleNotesAreStripped() {
        let media = parse("/Movies/[电影天堂www.dytt89.com]流浪地球2-2023_HD国语中字.mp4")
        XCTAssertEqual(media.title, "流浪地球2")
        XCTAssertEqual(media.year, 2023)
    }

    func testMixedScriptTitlesSearchEachScript() {
        let media = parse("/电影/星际穿越.Interstellar.2014.BD1080P.中英双字.mp4")
        XCTAssertEqual(media.title, "星际穿越 Interstellar")
        XCTAssertEqual(MediaNameParser.searchQueries(for: media.title), ["星际穿越 Interstellar", "星际穿越", "Interstellar"])
    }

    // MARK: Episodes

    func testSeasonEpisodeMarkerWithEpisodeTitle() {
        let media = parse("/TV Shows/Breaking Bad/Season 1/Breaking.Bad.S01E01.Pilot.720p.BluRay.x264.mkv")
        XCTAssertEqual(media.kind, .episode)
        XCTAssertEqual(media.title, "Breaking Bad")
        XCTAssertEqual(media.season, 1)
        XCTAssertEqual(media.episode, 1)
        XCTAssertEqual(media.episodeTitle, "Pilot")
    }

    func testBareEpisodeFileTakesShowAndYearFromFolders() {
        let media = parse("/TV Shows/Breaking Bad (2008)/Season 2/S02E03.mkv")
        XCTAssertEqual(media.title, "Breaking Bad")
        XCTAssertEqual(media.year, 2008)
        XCTAssertEqual(media.season, 2)
        XCTAssertEqual(media.episode, 3)
    }

    func testNumberedFilesInsideSeasonFolders() {
        let media = parse("/TV Shows/Severance/Season 1/01 Good News About Hell.mkv")
        XCTAssertEqual(media.kind, .episode)
        XCTAssertEqual(media.title, "Severance")
        XCTAssertEqual(media.episode, 1)
        XCTAssertEqual(media.episodeTitle, "Good News About Hell")
    }

    func testCrossNotationAndMultiEpisodeRanges() {
        let cross = parse("/Downloads/friends.1x05.the.one.with.the.east.german.laundry.detergent.avi")
        XCTAssertEqual(cross.season, 1)
        XCTAssertEqual(cross.episode, 5)
        let range = parse("/Downloads/The.Office.US.S03E10-E11.720p.mkv")
        XCTAssertEqual(range.title, "The Office US")
        XCTAssertEqual(range.episode, 10)
        XCTAssertNil(range.episodeTitle, "Resolution tags must not become an episode title")
        XCTAssertEqual(MediaNameParser.searchQueries(for: "The Office US"), ["The Office US", "The Office"])
    }

    func testChineseSeasonAndEpisodeMarkers() {
        let inline = parse("/美剧/庆余年第二季 第01集.mp4")
        XCTAssertEqual(inline.title, "庆余年")
        XCTAssertEqual(inline.season, 2)
        XCTAssertEqual(inline.episode, 1)
        let foldered = parse("/kk/庆余年/第一季/第05集.mp4")
        XCTAssertEqual(foldered.title, "庆余年")
        XCTAssertEqual(foldered.season, 1)
        XCTAssertEqual(foldered.episode, 5)
    }

    func testAnimeAbsoluteNumbering() {
        let media = parse("/Anime/[SubsPlease] Jujutsu Kaisen S2 - 12 (1080p).mkv")
        XCTAssertEqual(media.title, "Jujutsu Kaisen")
        XCTAssertEqual(media.season, 2)
        XCTAssertEqual(media.episode, 12)
    }

    func testSpecialsFolderKeepsTheShowName() {
        let media = parse("/TV/Dark/Specials/Dark.S00E01.mkv")
        XCTAssertEqual(media.title, "Dark")
        XCTAssertEqual(media.season, 0)
    }

    func testChineseNumerals() {
        XCTAssertEqual(MediaNameParser.chineseOrArabic("十二"), 12)
        XCTAssertEqual(MediaNameParser.chineseOrArabic("二十"), 20)
        XCTAssertEqual(MediaNameParser.chineseOrArabic("七"), 7)
        XCTAssertEqual(MediaNameParser.chineseOrArabic("03"), 3)
    }
}

final class GalleryCatalogTests: XCTestCase {
    private func file(_ path: String, size: Int64 = 1_000) -> LibraryFile {
        LibraryFile(path: path, name: (path as NSString).lastPathComponent, size: size, modified: nil, parsed: MediaNameParser.parse(path: path))
    }

    func testSpellingsOfOneMatchedMovieMergeIntoVersionsBestFirst() {
        let small = file("/M/Interstellar.2014.1080p.mkv", size: 10)
        let large = file("/M/Interstellar (2014)/Interstellar.2014.2160p.mkv", size: 50)
        var match = GalleryMatch.unmatched()
        match.tmdbID = 157_336
        match.title = "Interstellar"
        let catalog = GalleryCatalog.build(files: [small, large], matches: [GalleryMatchKey.movie(small.parsed): match])
        XCTAssertEqual(catalog.movies.count, 1)
        XCTAssertEqual(catalog.movies[0].files.map(\.path), [large.path, small.path])
        XCTAssertEqual(catalog.title(forPath: small.path), .movie("movie:157336"))
    }

    func testEpisodesGroupIntoOneShowOrderedWithSpecialsLast() {
        let catalog = GalleryCatalog.build(files: [
            file("/TV/Dark/Season 2/Dark.S02E01.mkv"),
            file("/TV/Dark/Specials/Dark.S00E01.mkv"),
            file("/TV/Dark/Season 1/Dark.S01E02.mkv"),
            file("/TV/Dark/Season 1/Dark.S01E01.mkv")
        ], matches: [:])
        XCTAssertEqual(catalog.shows.count, 1)
        XCTAssertEqual(catalog.shows[0].seasons, [1, 2, 0])
        XCTAssertEqual(catalog.shows[0].episodes.map(\.code), ["S1 · E1", "S1 · E2", "S2 · E1", "S0 · E1"])
    }

    func testWatchStateMirrorsResumeRules() {
        var state = GalleryWatchState()
        let identity = PlaybackProgressIdentity(baseURL: "b", username: "u", virtualPath: "/a.mkv")
        state.progress["/a.mkv"] = PlaybackProgressRecord(identity: identity, position: 20, duration: 100, updatedAt: Date())
        XCTAssertEqual(state.status("/a.mkv"), .unwatched, "Under 30 seconds is not a resume point")
        state.progress["/a.mkv"]?.position = 50
        XCTAssertEqual(state.status("/a.mkv"), .inProgress(fraction: 0.5, remaining: 50))
        state.progress = [:]
        state.watched["/a.mkv"] = Date()
        XCTAssertEqual(state.status("/a.mkv"), .watched)
    }

    func testScannerSkipsSamplesExtrasAndNestedRoots() {
        XCTAssertTrue(LibraryScanner.isSample("sample.mkv"))
        XCTAssertTrue(LibraryScanner.isSample("movie-sample.mkv"))
        XCTAssertFalse(LibraryScanner.isSample("Samples.of.Life.2020.mkv"))
        XCTAssertTrue(LibraryScanner.isSkippedFolder("Extras"))
        XCTAssertTrue(LibraryScanner.isSkippedFolder("@eaDir"))
        XCTAssertFalse(LibraryScanner.isSkippedFolder("Season 1"))
        XCTAssertEqual(LibraryScanner.minimalRoots(["/Media/TV", "/Media", "/Other"]), ["/Media", "/Other"])
        XCTAssertEqual(LibraryScanner.minimalRoots([]), ["/"])
    }
}

final class PlaybackWatchedTests: XCTestCase {
    func testFinishingPlaybackMarksWatchedAndUnmarkingKeepsHistoryClean() {
        let suite = "PlaybackWatchedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackProgressStore(defaults: defaults)
        let identity = PlaybackProgressIdentity(baseURL: "b", username: "u", virtualPath: "/m.mkv")

        store.update(identity: identity, position: 50, duration: 100)
        XCTAssertTrue(store.watchedRecords().isEmpty)
        store.update(identity: identity, position: 95, duration: 100)
        XCTAssertEqual(store.watchedRecords().map(\.identity), [identity])
        XCTAssertNil(store.record(for: identity))

        store.setWatched(false, identity: identity)
        XCTAssertTrue(store.watchedRecords().isEmpty)
    }
}

final class TMDBConfigurationTests: XCTestCase {
    func testMetadataLanguageFollowsTheDevicesPreferredLanguage() {
        XCTAssertEqual(TMDBConfiguration.language(preferred: ["en-US"]), "en-US")
        XCTAssertEqual(TMDBConfiguration.language(preferred: ["en-GB", "zh-Hant-TW"]), "en-GB")
        XCTAssertEqual(TMDBConfiguration.language(preferred: ["zh-Hant-JP", "en-JP"]), "zh-TW")
        XCTAssertEqual(TMDBConfiguration.language(preferred: ["zh-Hant-HK"]), "zh-HK")
        XCTAssertEqual(TMDBConfiguration.language(preferred: ["zh-Hans-CN"]), "zh-CN")
        XCTAssertEqual(TMDBConfiguration.language(preferred: []), "en-US")
    }
}
