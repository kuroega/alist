import Foundation

// Decoded with `.convertFromSnakeCase`, so `poster_path` arrives as `posterPath`
// and `iso_639_1` as `iso6391`.

struct TMDBPage<Result: Decodable & Sendable>: Decodable, Sendable {
    let results: [Result]
}

struct TMDBGenre: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
}

struct TMDBGenreList: Decodable, Sendable {
    let genres: [TMDBGenre]
}

struct TMDBMovieResult: Decodable, Sendable {
    let id: Int
    let title: String?
    let originalTitle: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let genreIds: [Int]?
    let releaseDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let popularity: Double?
}

struct TMDBShowResult: Decodable, Sendable {
    let id: Int
    let name: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let genreIds: [Int]?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let popularity: Double?
}

struct TMDBCredits: Decodable, Sendable {
    struct Cast: Decodable, Sendable, Identifiable {
        let id: Int
        let name: String
        let character: String?
        let profilePath: String?
    }

    struct Crew: Decodable, Sendable {
        let id: Int
        let name: String
        let job: String?
        let profilePath: String?
    }

    let cast: [Cast]?
    let crew: [Crew]?
}

struct TMDBImageSet: Decodable, Sendable {
    struct Image: Decodable, Sendable {
        let filePath: String
        let iso6391: String?
        let aspectRatio: Double?
        let voteAverage: Double?
    }

    let logos: [Image]?
    let posters: [Image]?
    let backdrops: [Image]?
}

struct TMDBMovieDetail: Decodable, Sendable {
    struct ReleaseDates: Decodable, Sendable {
        struct Country: Decodable, Sendable {
            struct Release: Decodable, Sendable { let certification: String? }
            let iso31661: String
            let releaseDates: [Release]
        }
        let results: [Country]
    }

    let id: Int
    let title: String?
    let originalTitle: String?
    let overview: String?
    let tagline: String?
    let runtime: Int?
    let releaseDate: String?
    let voteAverage: Double?
    let genres: [TMDBGenre]?
    let posterPath: String?
    let backdropPath: String?
    let credits: TMDBCredits?
    let images: TMDBImageSet?
    let releaseDates: ReleaseDates?
}

struct TMDBShowDetail: Decodable, Sendable {
    struct Season: Decodable, Sendable {
        let seasonNumber: Int
        let name: String?
        let episodeCount: Int?
        let posterPath: String?
        let airDate: String?
    }

    struct ContentRatings: Decodable, Sendable {
        struct Rating: Decodable, Sendable {
            let iso31661: String
            let rating: String?
        }
        let results: [Rating]
    }

    struct Network: Decodable, Sendable { let name: String }

    let id: Int
    let name: String?
    let originalName: String?
    let overview: String?
    let tagline: String?
    let firstAirDate: String?
    let lastAirDate: String?
    let episodeRunTime: [Int]?
    let numberOfSeasons: Int?
    let status: String?
    let voteAverage: Double?
    let genres: [TMDBGenre]?
    let posterPath: String?
    let backdropPath: String?
    let seasons: [Season]?
    let networks: [Network]?
    let credits: TMDBCredits?
    let images: TMDBImageSet?
    let contentRatings: ContentRatings?
}

struct TMDBSeasonDetail: Decodable, Sendable {
    struct Episode: Decodable, Sendable {
        let episodeNumber: Int
        let seasonNumber: Int
        let name: String?
        let overview: String?
        let stillPath: String?
        let runtime: Int?
        let airDate: String?
    }

    let seasonNumber: Int
    let name: String?
    let overview: String?
    let posterPath: String?
    let episodes: [Episode]?
}

extension TMDBImageSet {
    /// Best-rated image in the first language that has one.
    static func best(_ images: [Image]?, languages: [String?]) -> String? {
        guard let images, !images.isEmpty else { return nil }
        for language in languages {
            let matching = images.filter { $0.iso6391 == language && !$0.filePath.hasSuffix(".svg") }
            if let best = matching.max(by: { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }) { return best.filePath }
        }
        return images.first?.filePath
    }

    /// Prefers a title treatment in the viewer's language, then English, then
    /// a language-neutral one; within each, the best-rated wide logo.
    func preferredLogo(language: String) -> String? {
        guard let logos, !logos.isEmpty else { return nil }
        let primary = String(language.prefix(2))
        for candidate in [primary, "en", nil] as [String?] {
            let matching = logos.filter { $0.iso6391 == candidate && !$0.filePath.hasSuffix(".svg") }
            if let best = matching.max(by: { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }) {
                return best.filePath
            }
        }
        return nil
    }
}
