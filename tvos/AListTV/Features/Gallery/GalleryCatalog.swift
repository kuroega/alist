import Foundation

/// Compact TMDB identity for one parsed title, persisted so the Gallery
/// renders its posters immediately on the next launch.
struct GalleryMatch: Codable, Hashable, Sendable {
    var tmdbID: Int?
    var title: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genreIDs: [Int]
    var date: String?
    var rating: Double?
    var matchedAt: Date

    static func unmatched(at date: Date = Date()) -> GalleryMatch {
        GalleryMatch(tmdbID: nil, genreIDs: [], matchedAt: date)
    }

    /// Misses are retried after two weeks in case TMDB gained the title;
    /// hits are kept until metadata is refreshed by hand.
    func isStale(now: Date = Date()) -> Bool {
        tmdbID == nil && now.timeIntervalSince(matchedAt) > 14 * 86_400
    }

    var year: Int? { date.flatMap { Int($0.prefix(4)) } }
}

enum GalleryMatchKey {
    static func movie(_ parsed: ParsedMedia) -> String {
        "movie|\(parsed.titleKey)|\(parsed.year.map(String.init) ?? "")"
    }

    static func show(_ parsed: ParsedMedia) -> String {
        "show|\(parsed.titleKey)"
    }

    static func key(for parsed: ParsedMedia) -> String {
        parsed.kind == .movie ? movie(parsed) : show(parsed)
    }
}

enum GalleryTitle: Hashable, Sendable {
    case movie(String)
    case show(String)
}

struct GalleryMovie: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var year: Int?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genreIDs: [Int]
    var rating: Double?
    var tmdbID: Int?
    /// Every copy of this movie on the server, best version first.
    var files: [LibraryFile]
    var addedAt: Date

    var primaryFile: LibraryFile { files[0] }
    var qualities: [String] { primaryFile.parsed.qualities }
    var paths: [String] { files.map(\.path) }
    /// Exactly matched on TMDB; otherwise the movie is un-indexed.
    var isIndexed: Bool { tmdbID != nil }
}

struct GalleryEpisode: Identifiable, Hashable, Sendable {
    let season: Int
    let episode: Int
    let file: LibraryFile

    var id: String { file.path }
    var path: String { file.path }
    var code: String { "S\(season) · E\(episode)" }
}

struct GalleryShow: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var year: Int?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genreIDs: [Int]
    var rating: Double?
    var tmdbID: Int?
    /// Ordered by season, then episode.
    var episodes: [GalleryEpisode]
    var addedAt: Date

    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted { lhs, rhs in
        // Specials (season 0) go last, as on TMDB and in Infuse.
        lhs == 0 ? false : (rhs == 0 ? true : lhs < rhs)
    } }

    func episodes(inSeason season: Int) -> [GalleryEpisode] {
        episodes.filter { $0.season == season }
    }

    var paths: [String] { episodes.map(\.path) }
    /// Exactly matched on TMDB; otherwise the show is un-indexed.
    var isIndexed: Bool { tmdbID != nil }
}

/// The library as titles: movies (with their versions) and shows (with
/// their episodes), joined with whatever TMDB knows about each.
struct GalleryCatalog: Sendable {
    var movies: [GalleryMovie] = []
    var shows: [GalleryShow] = []
    private(set) var movieIndex: [String: Int] = [:]
    private(set) var showIndex: [String: Int] = [:]
    private(set) var titleByPath: [String: GalleryTitle] = [:]

    static let empty = GalleryCatalog()

    var isEmpty: Bool { movies.isEmpty && shows.isEmpty }
    var videoCount: Int { titleByPath.count }

    func movie(_ id: String) -> GalleryMovie? { movieIndex[id].map { movies[$0] } }
    func show(_ id: String) -> GalleryShow? { showIndex[id].map { shows[$0] } }
    func title(forPath path: String) -> GalleryTitle? { titleByPath[path] }

    func isIndexed(_ title: GalleryTitle) -> Bool {
        switch title {
        case let .movie(id): movie(id)?.isIndexed ?? false
        case let .show(id): show(id)?.isIndexed ?? false
        }
    }

    func episode(forPath path: String) -> (show: GalleryShow, episode: GalleryEpisode)? {
        guard case let .show(id) = titleByPath[path], let show = show(id),
              let episode = show.episodes.first(where: { $0.path == path }) else { return nil }
        return (show, episode)
    }

    static func build(files: [LibraryFile], matches: [String: GalleryMatch]) -> GalleryCatalog {
        var movieGroups: [String: (match: GalleryMatch?, files: [LibraryFile])] = [:]
        var showGroups: [String: (match: GalleryMatch?, files: [LibraryFile])] = [:]

        for file in files {
            let key = GalleryMatchKey.key(for: file.parsed)
            let match = matches[key].flatMap { $0.tmdbID == nil ? nil : $0 }
            switch file.parsed.kind {
            case .movie:
                // One TMDB title may arrive under several spellings; merge them.
                let groupID = match?.tmdbID.map { "movie:\($0)" } ?? "movie-local:\(key)"
                movieGroups[groupID, default: (match, [])].files.append(file)
            case .episode:
                let groupID = match?.tmdbID.map { "show:\($0)" } ?? "show-local:\(key)"
                showGroups[groupID, default: (match, [])].files.append(file)
            }
        }

        var catalog = GalleryCatalog()
        catalog.movies = movieGroups.map { id, group in
            let files = group.files.sorted(by: versionComesFirst)
            let parsed = files[0].parsed
            let match = group.match
            return GalleryMovie(
                id: id,
                title: match?.title ?? parsed.title,
                year: match?.year ?? parsed.year,
                overview: match?.overview,
                posterPath: match?.posterPath,
                backdropPath: match?.backdropPath,
                genreIDs: match?.genreIDs ?? [],
                rating: match?.rating,
                tmdbID: match?.tmdbID,
                files: files,
                addedAt: files.map(\.addedAt).max() ?? .distantPast
            )
        }
        .sorted(by: titleComesFirst)

        catalog.shows = showGroups.map { id, group in
            // Keep the best copy of each episode.
            var byEpisode: [String: LibraryFile] = [:]
            for file in group.files {
                let slot = "\(file.parsed.season ?? 1)x\(file.parsed.episode ?? 0)"
                if let existing = byEpisode[slot], versionComesFirst(existing, file) { continue }
                byEpisode[slot] = file
            }
            let episodes = byEpisode.values
                .map { GalleryEpisode(season: $0.parsed.season ?? 1, episode: $0.parsed.episode ?? 0, file: $0) }
                .sorted { ($0.season == 0 ? Int.max : $0.season, $0.episode) < ($1.season == 0 ? Int.max : $1.season, $1.episode) }
            let parsed = group.files[0].parsed
            let match = group.match
            return GalleryShow(
                id: id,
                title: match?.title ?? parsed.title,
                year: match?.year ?? group.files.compactMap(\.parsed.year).min(),
                overview: match?.overview,
                posterPath: match?.posterPath,
                backdropPath: match?.backdropPath,
                genreIDs: match?.genreIDs ?? [],
                rating: match?.rating,
                tmdbID: match?.tmdbID,
                episodes: episodes,
                addedAt: group.files.map(\.addedAt).max() ?? .distantPast
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        for (index, movie) in catalog.movies.enumerated() {
            catalog.movieIndex[movie.id] = index
            for file in movie.files { catalog.titleByPath[file.path] = .movie(movie.id) }
        }
        for (index, show) in catalog.shows.enumerated() {
            catalog.showIndex[show.id] = index
            for file in show.episodes { catalog.titleByPath[file.path] = .show(show.id) }
        }
        return catalog
    }

    private static func titleComesFirst(_ lhs: GalleryMovie, _ rhs: GalleryMovie) -> Bool {
        let order = lhs.title.localizedStandardCompare(rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        return (lhs.year ?? 0) < (rhs.year ?? 0)
    }

    /// Higher resolution first, then the larger (less compressed) file.
    static func versionComesFirst(_ lhs: LibraryFile, _ rhs: LibraryFile) -> Bool {
        let lRank = resolutionRank(lhs.parsed.qualities)
        let rRank = resolutionRank(rhs.parsed.qualities)
        if lRank != rRank { return lRank > rRank }
        return lhs.size > rhs.size
    }

    private static func resolutionRank(_ qualities: [String]) -> Int {
        if qualities.contains("4K") { return 3 }
        if qualities.contains("1080p") { return 2 }
        if qualities.contains("720p") { return 1 }
        return 0
    }
}

// MARK: - Watch state

enum WatchStatus: Hashable, Sendable {
    case unwatched
    case inProgress(fraction: Double, remaining: TimeInterval)
    case watched

    var fraction: Double? {
        if case let .inProgress(fraction, _) = self { return fraction }
        return nil
    }
}

/// Resume points, finished files and recently opened files for one account,
/// keyed by virtual path.
struct GalleryWatchState: Sendable, Equatable {
    var progress: [String: PlaybackProgressRecord] = [:]
    var watched: [String: Date] = [:]
    var opened: [String: Date] = [:]

    func status(_ path: String) -> WatchStatus {
        if let record = progress[path], record.duration > 0, record.position >= 30, record.position < record.duration * 0.9 {
            return .inProgress(fraction: record.position / record.duration, remaining: max(0, record.duration - record.position))
        }
        return watched[path] != nil ? .watched : .unwatched
    }

    func isWatched(_ path: String) -> Bool { watched[path] != nil }

    /// Most recent interaction of any kind, for "Recently Watched" ordering.
    func lastActivity(_ path: String) -> Date? {
        [progress[path]?.updatedAt, watched[path], opened[path]].compactMap { $0 }.max()
    }
}
