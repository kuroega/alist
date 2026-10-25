import Foundation

/// A TMDB entry offered when a title has no exact match.
struct GalleryCandidate: Identifiable, Hashable, Sendable {
    let tmdbID: Int
    let kind: ParsedMedia.Kind
    var title: String
    var originalTitle: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genreIDs: [Int]
    var date: String?
    var rating: Double?
    var voteCount: Int

    var id: Int { tmdbID }
    var year: Int? { date.flatMap { Int($0.prefix(4)) } }

    init(movie: TMDBMovieResult) {
        tmdbID = movie.id
        kind = .movie
        title = movie.title ?? movie.originalTitle ?? ""
        originalTitle = movie.originalTitle
        overview = movie.overview
        posterPath = movie.posterPath
        backdropPath = movie.backdropPath
        genreIDs = movie.genreIds ?? []
        date = movie.releaseDate.flatMap { $0.isEmpty ? nil : $0 }
        rating = movie.voteAverage
        voteCount = movie.voteCount ?? 0
    }

    init(show: TMDBShowResult) {
        tmdbID = show.id
        kind = .episode
        title = show.name ?? show.originalName ?? ""
        originalTitle = show.originalName
        overview = show.overview
        posterPath = show.posterPath
        backdropPath = show.backdropPath
        genreIDs = show.genreIds ?? []
        date = show.firstAirDate.flatMap { $0.isEmpty ? nil : $0 }
        rating = show.voteAverage
        voteCount = show.voteCount ?? 0
    }
}

/// A chosen entry, ready to store and to name files after.
struct GalleryMatchProposal: Sendable {
    let candidate: GalleryCandidate
    /// In the metadata language, as the shelves show it.
    let match: GalleryMatch
    /// The original-language title files are named after.
    let fileTitle: String
    let year: Int?
    let plan: GalleryRenamePlan
}

extension GalleryMatcher {
    static let candidateLimit = 10

    /// TMDB's nearest entries for a title without an exact match, best first.
    /// Searches the metadata language and English, with the parsed title, its
    /// script-split forms and shorter prefixes, unless `query` replaces them.
    static func closestCandidates(
        to parsed: ParsedMedia,
        query: String? = nil,
        client: TMDBClient,
        limit: Int = candidateLimit
    ) async throws -> [GalleryCandidate] {
        let typed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queries = typed.map { $0.isEmpty ? [] : [$0] } ?? looseQueries(for: parsed.title)
        let english = client.language.lowercased().hasPrefix("en")
        // The metadata language first, so its titles win over English ones.
        let languages: [String?] = english ? [nil] : [nil, "en-US"]
        var found: [Int: GalleryCandidate] = [:]
        var order: [Int] = []
        var failure: Error?
        for language in languages {
            for query in queries {
                do {
                    let results: [GalleryCandidate]
                    switch parsed.kind {
                    case .movie: results = try await client.searchMovies(query: query, year: nil, language: language).map(GalleryCandidate.init(movie:))
                    case .episode: results = try await client.searchShows(query: query, year: nil, language: language).map(GalleryCandidate.init(show:))
                    }
                    for result in results where found[result.tmdbID] == nil && !result.title.isEmpty {
                        found[result.tmdbID] = result
                        order.append(result.tmdbID)
                    }
                } catch {
                    failure = failure ?? error
                }
            }
        }
        if found.isEmpty, let failure { throw failure }
        let ranked = rank(order.compactMap { found[$0] }, title: typed.flatMap { $0.isEmpty ? nil : $0 } ?? parsed.title, year: parsed.year)
        return Array(ranked.prefix(limit))
    }

    /// The usual search forms, then the title cut down a word at a time
    /// (to two words) for names that carry extra words TMDB doesn't.
    static func looseQueries(for title: String) -> [String] {
        var queries = MediaNameParser.searchQueries(for: title)
        var words = title.split(separator: " ").map(String.init)
        while words.count > 2, queries.count < 6 {
            words.removeLast()
            let shorter = words.joined(separator: " ")
            if !queries.contains(shorter) { queries.append(shorter) }
        }
        return queries
    }

    /// Closest name first, then the nearest year, then the better known entry.
    static func rank(_ candidates: [GalleryCandidate], title: String, year: Int?) -> [GalleryCandidate] {
        let key = MediaNameParser.key(for: title)
        func score(_ candidate: GalleryCandidate) -> Double {
            let names = [candidate.title, candidate.originalTitle].compactMap { $0 }
            let closeness = names.map { similarity(key, MediaNameParser.key(for: $0)) }.max() ?? 0
            let yearScore: Double
            if let year, let found = candidate.year {
                yearScore = max(0, 1 - Double(abs(found - year)) / 5)
            } else {
                yearScore = 0.5
            }
            let fame = min(1, log10(Double(candidate.voteCount) + 1) / 4)
            return closeness * 0.7 + yearScore * 0.2 + fame * 0.1
        }
        return candidates
            .map { ($0, score($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.tmdbID < $1.0.tmdbID }
            .map(\.0)
    }

    /// 1 for equal keys, falling with the edit distance; a name holding the
    /// other whole (`dark` in `darkmatter`) scores at least 0.8.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0 ... b.count)
        for i in 1 ... a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1 ... b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        var value = 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
        if min(a.count, b.count) >= 3, lhs.contains(rhs) || rhs.contains(lhs) { value = max(value, 0.8) }
        return value
    }

    /// The chosen entry in the metadata language, with the original-language
    /// title and year files are named after.
    static func resolve(_ candidate: GalleryCandidate, client: TMDBClient) async throws -> (match: GalleryMatch, fileTitle: String, year: Int?) {
        var match = GalleryMatch(
            tmdbID: candidate.tmdbID, title: candidate.title, overview: candidate.overview, posterPath: candidate.posterPath,
            backdropPath: candidate.backdropPath, genreIDs: candidate.genreIDs, date: candidate.date,
            rating: candidate.rating, matchedAt: Date()
        )
        var original = candidate.originalTitle
        switch candidate.kind {
        case .movie:
            let detail = try await client.movie(id: candidate.tmdbID)
            match.title = detail.title ?? match.title
            match.overview = detail.overview ?? match.overview
            match.posterPath = detail.posterPath ?? match.posterPath
            match.backdropPath = detail.backdropPath ?? match.backdropPath
            match.genreIDs = detail.genres.map { $0.map(\.id) } ?? match.genreIDs
            match.date = detail.releaseDate.flatMap { $0.isEmpty ? nil : $0 } ?? match.date
            match.rating = detail.voteAverage ?? match.rating
            original = detail.originalTitle ?? original
            match = await withFallbackArtwork(match, client: client) { try await client.images(movieID: candidate.tmdbID) }
        case .episode:
            let detail = try await client.show(id: candidate.tmdbID)
            match.title = detail.name ?? match.title
            match.overview = detail.overview ?? match.overview
            match.posterPath = detail.posterPath ?? match.posterPath
            match.backdropPath = detail.backdropPath ?? match.backdropPath
            match.genreIDs = detail.genres.map { $0.map(\.id) } ?? match.genreIDs
            match.date = detail.firstAirDate.flatMap { $0.isEmpty ? nil : $0 } ?? match.date
            match.rating = detail.voteAverage ?? match.rating
            original = detail.originalName ?? original
            match = await withFallbackArtwork(match, client: client) { try await client.images(showID: candidate.tmdbID) }
        }
        let fileTitle = original.flatMap { $0.isEmpty ? nil : $0 } ?? match.title ?? candidate.title
        return (match, fileTitle, match.year)
    }
}

/// What applying a chosen match did.
struct GalleryMatchOutcome: Sendable {
    var renamed: [GalleryRename] = []
    var failures: [GalleryRenamePlan.Skip] = []
    var matched = false
}

// MARK: - Renaming

/// One entry to rename within its folder.
struct GalleryRename: Hashable, Sendable {
    let path: String
    let newName: String

    var folder: String { AListPath.parent(of: path) }
    var name: String { String(path.split(separator: "/").last ?? "") }
    var newPath: String { (try? AListPath.join(parent: folder, name: newName)) ?? path }
}

/// Every rename a chosen match calls for. Each video travels with the
/// subtitles named after it; nothing is ever renamed over an existing entry.
struct GalleryRenamePlan: Sendable {
    struct Group: Hashable, Sendable {
        var video: GalleryRename
        var subtitles: [GalleryRename]
    }

    struct Skip: Hashable, Sendable {
        let path: String
        let reason: String
    }

    var groups: [Group] = []
    /// Videos already named this way.
    var unchanged: [String] = []
    var skipped: [Skip] = []

    var fileCount: Int { groups.reduce(0) { $0 + 1 + $1.subtitles.count } }
}

/// Names files the way TMDB matching reads them best, following the
/// project's media naming rules: `Original Title (Year)` for movies and
/// `Original Name (Year) S01E02` for episodes, keeping release tags.
enum GalleryRenamer {
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "cdg", "utf", "aqt", "jss", "psb", "rt"]

    /// `folderContents` holds the full listing (names) of every folder the
    /// videos sit in, so new names are checked against everything there.
    static func plan(videos: [LibraryFile], title: String, year: Int?, folderContents: [String: [String]]) -> GalleryRenamePlan {
        var plan = GalleryRenamePlan()
        var taken = folderContents.mapValues { Set($0.map { $0.lowercased() }) }
        for file in videos.sorted(by: { $0.path < $1.path }) {
            let folder = AListPath.parent(of: file.path)
            guard let names = folderContents[folder] else {
                plan.skipped.append(.init(path: file.path, reason: "Its folder couldn’t be read."))
                continue
            }
            guard let newName = videoName(for: file, title: title, year: year) else {
                plan.skipped.append(.init(path: file.path, reason: "A new name wouldn’t keep its episode number."))
                continue
            }
            if newName == file.name {
                plan.unchanged.append(file.path)
                continue
            }
            let videoStem = stem(of: file.name)
            let newStem = stem(of: newName)
            let subtitles = names
                .filter { owner(ofSubtitle: $0, in: names) == videoStem }
                .map { GalleryRename(path: folder == "/" ? "/" + $0 : folder + "/" + $0, newName: newStem + $0.dropFirst(videoStem.count)) }
            let renames = [GalleryRename(path: file.path, newName: newName)] + subtitles
            let sources = Set(renames.map { $0.name.lowercased() })
            let targets = renames.map { $0.newName.lowercased() }
            let clash = renames.first { rename in
                let target = rename.newName.lowercased()
                return (taken[folder]?.contains(target) == true && !sources.contains(target)) || targets.filter { $0 == target }.count > 1
            }
            if let clash {
                plan.skipped.append(.init(path: file.path, reason: "“\(clash.newName)” already exists."))
                continue
            }
            taken[folder, default: []].formUnion(targets)
            plan.groups.append(.init(video: renames[0], subtitles: Array(renames.dropFirst())))
        }
        return plan
    }

    /// The new name, keeping the extension and release tags; nil when no
    /// name keeps the file recognized as the same movie or episode.
    static func videoName(for file: LibraryFile, title: String, year: Int?) -> String? {
        let fileExtension = (file.name as NSString).pathExtension
        var base = safeName(title)
        guard !base.isEmpty else { return nil }
        if let year { base += " (\(year))" }
        if file.parsed.kind == .episode, let episode = file.parsed.episode {
            base += String(format: " S%02dE%02d", file.parsed.season ?? 1, episode)
            if let episodeTitle = file.parsed.episodeTitle.map(safeName), !episodeTitle.isEmpty { base += " " + episodeTitle }
        }
        let folder = AListPath.parent(of: file.path)
        let tail = MediaNameParser.technicalTail(of: stem(of: file.name))
        for tail in tail == nil ? [nil] : [tail, nil] {
            let name = [base, tail].compactMap { $0 }.joined(separator: " ") + (fileExtension.isEmpty ? "" : "." + fileExtension)
            let parsed = MediaNameParser.parse(path: folder == "/" ? "/" + name : folder + "/" + name)
            guard parsed.kind == file.parsed.kind else { continue }
            if parsed.kind == .episode, parsed.season != (file.parsed.season ?? 1) || parsed.episode != file.parsed.episode { continue }
            return name
        }
        return nil
    }

    /// The stem of the video a subtitle is named after: the longest other
    /// file stem it starts with, then a dot (`Show.S01E04.en.srt`).
    static func owner(ofSubtitle name: String, in names: [String]) -> String? {
        guard subtitleExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        let lowered = name.lowercased()
        return names
            .filter { !subtitleExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { stem(of: $0) }
            .filter { lowered.hasPrefix($0.lowercased() + ".") }
            .max { $0.count < $1.count }
    }

    /// TMDB spelling, minus what storage providers refuse in names.
    static func safeName(_ text: String) -> String {
        var result = text.replacingOccurrences(of: ":", with: " -")
        for character in ["/", "\\", "|"] { result = result.replacingOccurrences(of: character, with: "-") }
        for character in ["*", "?", "\"", "<", ">"] { result = result.replacingOccurrences(of: character, with: "") }
        let collapsed = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
