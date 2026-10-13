import XCTest
@testable import AListTV

final class GalleryMatcherTests: XCTestCase {
    private func movie(_ id: Int, _ title: String, original: String? = nil, votes: Int = 0, date: String? = nil) -> TMDBMovieResult {
        TMDBMovieResult(id: id, title: title, originalTitle: original ?? title, overview: nil, posterPath: nil, backdropPath: nil, genreIds: nil, releaseDate: date, voteAverage: nil, voteCount: votes, popularity: nil)
    }

    private func show(_ id: Int, _ name: String, original: String? = nil, votes: Int = 0, firstAired: String? = nil) -> TMDBShowResult {
        TMDBShowResult(id: id, name: name, originalName: original ?? name, overview: nil, posterPath: nil, backdropPath: nil, genreIds: nil, firstAirDate: firstAired, voteAverage: nil, voteCount: votes, popularity: nil)
    }

    func testOnlyAnExactTitleMatches() {
        let results = [movie(1, "Interstellar Wars", votes: 9_000), movie(2, "Interstellar", votes: 30)]
        XCTAssertEqual(GalleryMatcher.exactMovie(in: results, query: "Interstellar")?.id, 2)
        XCTAssertNil(GalleryMatcher.exactMovie(in: [movie(1, "Interstellar Wars", votes: 9_000)], query: "Interstellar"),
                     "A popular but different title is not a match")
    }

    func testCaseSpacingAndPunctuationAreIgnored() {
        XCTAssertEqual(GalleryMatcher.exactMovie(in: [movie(3, "Spider-Man: No Way Home")], query: "spider man no way home")?.id, 3)
    }

    func testOriginalTitleCounts() {
        let localized = movie(4, "星际穿越", original: "Interstellar")
        XCTAssertEqual(GalleryMatcher.exactMovie(in: [localized], query: "Interstellar")?.id, 4)
        XCTAssertEqual(GalleryMatcher.exactMovie(in: [localized], query: "星际穿越")?.id, 4)
    }

    func testMostVotedExactTitleWins() {
        let results = [movie(5, "Dune", votes: 900, date: "1984-12-14"), movie(6, "Dune", votes: 12_000, date: "2021-09-15")]
        XCTAssertEqual(GalleryMatcher.exactMovie(in: results, query: "Dune")?.id, 6)
    }

    func testEmptyQueryNeverMatches() {
        XCTAssertNil(GalleryMatcher.exactMovie(in: [movie(7, "")], query: "  -- "))
    }

    func testShowYearBreaksTiesBetweenExactNames() {
        let results = [show(10, "Doctor Who", votes: 3_000, firstAired: "2005-03-26"), show(11, "Doctor Who", votes: 500, firstAired: "1963-11-23")]
        XCTAssertEqual(GalleryMatcher.exactShow(in: results, query: "Doctor Who", year: 1963)?.id, 11)
        XCTAssertEqual(GalleryMatcher.exactShow(in: results, query: "Doctor Who", year: nil)?.id, 10)
        // A season's year that fits no first air date still takes the exact name.
        XCTAssertEqual(GalleryMatcher.exactShow(in: results, query: "Doctor Who", year: 2019)?.id, 10)
        XCTAssertNil(GalleryMatcher.exactShow(in: results, query: "Doctor Who Confidential", year: nil))
    }
}
