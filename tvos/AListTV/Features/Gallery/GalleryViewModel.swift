import Combine
import Foundation

@MainActor
final class GalleryNavigator: ObservableObject {
    @Published var path: [GalleryRoute] = []
}

/// A pushed Gallery screen.
enum GalleryRoute: Hashable {
    case title(GalleryTitle, focusPath: String? = nil)
    case collection(GalleryCollection)
}

enum GalleryCollection: Hashable {
    case movies
    case shows
    case unwatched
    case genre(Int)
}

/// One card in the Watching / Recently Watched shelf: a specific file, shown
/// as its movie or show.
struct GalleryPlayEntry: Identifiable, Hashable {
    enum Section { case watching, recent }

    let title: GalleryTitle
    let path: String
    let date: Date
    let section: Section
    let status: WatchStatus

    var id: String { path }
}

struct GalleryGenreTile: Identifiable, Hashable {
    let genre: TMDBGenre
    let count: Int
    /// Posters of the most recent titles, fanned across the tile.
    let posters: [String]
    let backdrop: String?

    var id: Int { genre.id }
}

struct GalleryShelves {
    var playEntries: [GalleryPlayEntry] = []
    var genres: [GalleryGenreTile] = []
    var unwatched: [GalleryTitle] = []
    var shows: [GalleryShow] = []
    var movies: [GalleryMovie] = []
}

@MainActor
final class GalleryViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(LibraryScanProgress)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var catalog = GalleryCatalog.empty
    @Published private(set) var shelves = GalleryShelves()
    @Published private(set) var watch = GalleryWatchState()
    @Published private(set) var genreNames: [Int: String] = [:]
    @Published private(set) var roots: [String]
    @Published private(set) var lastScan: Date?
    @Published private(set) var matchProgress: (done: Int, total: Int)?
    @Published private(set) var metadataIssue: String?

    /// Pushed Gallery screens. Lives in its own object so the home shell can
    /// bind navigation without redrawing on every library update.
    let navigator = GalleryNavigator()
    var path: [GalleryRoute] {
        get { navigator.path }
        set { navigator.path = newValue }
    }

    @Published private(set) var tmdb: TMDBClient?
    /// Last title put on stage, so the spotlight follows it as matches land.
    var spotlightSubject: (title: GalleryTitle, path: String?, section: GalleryPlayEntry.Section?)?
    let spotlight = GallerySpotlight()
    var hasMetadata: Bool { tmdb != nil }
    var isScanning: Bool { if case .scanning = phase { return true }; return false }

    private let api: any AListAPI
    private let store: GalleryLibraryStore
    private let progressStore: PlaybackProgressStore
    private let recentItemsStore: RecentItemsStore
    private let account: RecentItemsAccount
    private let onPlay: @MainActor (AListObject) async -> Void
    private let onUnauthorized: @MainActor () async -> Void
    private var files: [LibraryFile] = []
    private var matches: [String: GalleryMatch] = [:]
    private var scanTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var didLoad = false
    private let tmdbAPIKey: String?
    private var movieDetails: [Int: TMDBMovieDetail] = [:]
    private var showDetails: [Int: TMDBShowDetail] = [:]
    private var seasonDetails: [String: TMDBSeasonDetail] = [:]

    /// A scan older than this refreshes quietly in the background on appear.
    private let staleInterval: TimeInterval = 6 * 3600

    init(
        api: any AListAPI,
        store: GalleryLibraryStore,
        progressStore: PlaybackProgressStore,
        recentItemsStore: RecentItemsStore,
        baseURL: URL,
        username: String,
        tmdbAPIKey: String?,
        onPlay: @escaping @MainActor (AListObject) async -> Void = { _ in },
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) {
        self.api = api
        self.store = store
        self.progressStore = progressStore
        self.recentItemsStore = recentItemsStore
        account = RecentItemsAccount(baseURL: baseURL.absoluteString, username: username)
        self.tmdbAPIKey = tmdbAPIKey
        tmdb = Self.makeClient(apiKey: tmdbAPIKey, englishOnly: store.prefersEnglishMetadata)
        self.onPlay = onPlay
        self.onUnauthorized = onUnauthorized
        roots = store.roots
    }

    deinit {
        scanTask?.cancel()
        matchTask?.cancel()
    }

    // MARK: Lifecycle

    func onAppear() {
        reloadWatchState()
        guard !didLoad else {
            if let lastScan, Date().timeIntervalSince(lastScan) > staleInterval, !isScanning { rescan() }
            return
        }
        didLoad = true
        matches = store.loadMatches(language: metadataLanguage)
        if let snapshot = store.loadSnapshot(), snapshot.roots == roots {
            files = snapshot.files
            lastScan = snapshot.scannedAt
            rebuildCatalog()
            phase = .ready
            matchMissing()
            if Date().timeIntervalSince(snapshot.scannedAt) > staleInterval { rescan() }
        } else {
            rescan()
        }
        loadGenres()
    }

    func rescan() {
        scanTask?.cancel()
        let roots = roots
        let scanner = LibraryScanner(api: api)
        phase = .scanning(LibraryScanProgress(foldersScanned: 0, videosFound: 0, currentFolder: roots.first ?? "/"))
        scanTask = Task { [weak self] in
            do {
                let found = try await scanner.scan(roots: roots) { progress in
                    await MainActor.run { [weak self] in
                        guard let self, self.isScanning else { return }
                        self.phase = .scanning(progress)
                    }
                }
                guard !Task.isCancelled, let self else { return }
                let snapshot = LibrarySnapshot(files: found, roots: roots, scannedAt: Date())
                self.store.saveSnapshot(snapshot)
                self.files = found
                self.lastScan = snapshot.scannedAt
                self.rebuildCatalog()
                self.phase = .ready
                self.matchMissing()
            } catch AListAPIError.unauthorized {
                await self?.onUnauthorized()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                // Keep showing the previous index if there is one.
                self.phase = self.files.isEmpty ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) : .ready
            }
        }
    }

    var prefersEnglishMetadata: Bool { store.prefersEnglishMetadata }

    /// The TMDB language in use; also names the match cache.
    var metadataLanguage: String { tmdb?.language ?? "none" }

    /// Switches TMDB between the system language and English, then matches
    /// the library again so titles and artwork follow.
    func setPrefersEnglishMetadata(_ english: Bool) {
        guard english != store.prefersEnglishMetadata else { return }
        store.prefersEnglishMetadata = english
        tmdb = Self.makeClient(apiKey: tmdbAPIKey, englishOnly: english)
        resetMetadata(matches: store.loadMatches(language: metadataLanguage))
    }

    private static func makeClient(apiKey: String?, englishOnly: Bool) -> TMDBClient? {
        apiKey.map { TMDBClient(apiKey: $0, language: englishOnly ? "en-US" : TMDBConfiguration.language()) }
    }

    /// Forgets every TMDB match and response, then matches the library again.
    func refreshMetadata() {
        store.removeMatches(language: metadataLanguage)
        Task {
            await TMDBResponseCache().removeAll()
            resetMetadata(matches: [:])
        }
    }

    private func resetMetadata(matches newMatches: [String: GalleryMatch]) {
        matchTask?.cancel()
        matches = newMatches
        movieDetails = [:]
        showDetails = [:]
        seasonDetails = [:]
        genreNames = [:]
        rebuildCatalog()
        loadGenres()
        matchMissing()
    }

    // MARK: Library folders

    func isRoot(_ path: String) -> Bool { roots.contains(AListPath.normalize(path)) }

    func toggleRoot(_ path: String) {
        let normalized = AListPath.normalize(path)
        var updated = roots
        if let index = updated.firstIndex(of: normalized) { updated.remove(at: index) } else { updated.append(normalized) }
        setRoots(updated)
    }

    func removeRoot(_ path: String) {
        setRoots(roots.filter { $0 != path })
    }

    private func setRoots(_ newRoots: [String]) {
        store.setRoots(newRoots)
        roots = store.roots
        rescan()
    }

    // MARK: Watch state

    func reloadWatchState() {
        let mine = { (identity: PlaybackProgressIdentity) in
            identity.baseURL == self.account.baseURL && identity.username == self.account.username
        }
        var state = GalleryWatchState()
        for record in progressStore.allRecords() where mine(record.identity) {
            state.progress[record.identity.virtualPath] = record
        }
        for record in progressStore.watchedRecords() where mine(record.identity) {
            state.watched[record.identity.virtualPath] = record.watchedAt
        }
        for item in recentItemsStore.items(for: account) {
            if let path = item.object.virtualPath { state.opened[path] = item.openedAt }
        }
        if state != watch {
            watch = state
            rebuildShelves()
        }
    }

    func setWatched(_ watched: Bool, paths: [String]) {
        for path in paths {
            progressStore.setWatched(watched, identity: PlaybackProgressIdentity(baseURL: account.baseURL, username: account.username, virtualPath: path))
        }
        reloadWatchState()
    }

    func status(_ path: String) -> WatchStatus { watch.status(path) }

    func clearProgress(path: String) {
        progressStore.remove(identity: PlaybackProgressIdentity(baseURL: account.baseURL, username: account.username, virtualPath: path))
        reloadWatchState()
    }

    // MARK: Playback

    func play(_ file: LibraryFile) {
        let object = file.object
        Task { await onPlay(object) }
    }

    /// The episode a "Play" button should start: the one in progress, else
    /// the first unwatched after the last watched one, else the first.
    func nextEpisode(in show: GalleryShow) -> GalleryEpisode? {
        let episodes = show.episodes.filter { $0.season != 0 }.isEmpty ? show.episodes : show.episodes.filter { $0.season != 0 }
        if let resuming = episodes
            .filter({ watch.status($0.path).fraction != nil })
            .max(by: { (watch.progress[$0.path]?.updatedAt ?? .distantPast) < (watch.progress[$1.path]?.updatedAt ?? .distantPast) }) {
            return resuming
        }
        if let lastWatched = episodes.lastIndex(where: { watch.isWatched($0.path) }) {
            return episodes[(lastWatched + 1)...].first { !watch.isWatched($0.path) } ?? episodes.first
        }
        return episodes.first
    }

    // MARK: Details

    func cachedMovieDetail(_ id: Int?) -> TMDBMovieDetail? { id.flatMap { movieDetails[$0] } }
    func cachedShowDetail(_ id: Int?) -> TMDBShowDetail? { id.flatMap { showDetails[$0] } }

    func movieDetail(_ id: Int) async -> TMDBMovieDetail? {
        if let cached = movieDetails[id] { return cached }
        guard let tmdb, let detail = try? await tmdb.movie(id: id) else { return nil }
        movieDetails[id] = detail
        return detail
    }

    func showDetail(_ id: Int) async -> TMDBShowDetail? {
        if let cached = showDetails[id] { return cached }
        guard let tmdb, let detail = try? await tmdb.show(id: id) else { return nil }
        showDetails[id] = detail
        return detail
    }

    func seasonDetail(showID: Int, season: Int) async -> TMDBSeasonDetail? {
        let key = "\(showID)-\(season)"
        if let cached = seasonDetails[key] { return cached }
        guard let tmdb, let detail = try? await tmdb.season(showID: showID, number: season) else { return nil }
        seasonDetails[key] = detail
        return detail
    }

    // MARK: Lookups

    func genreName(_ id: Int) -> String? { genreNames[id] }

    func titles(in collection: GalleryCollection) -> [GalleryTitle] {
        switch collection {
        case .movies:
            return catalog.movies.map { .movie($0.id) }
        case .shows:
            return catalog.shows.map { .show($0.id) }
        case .unwatched:
            return shelves.unwatched
        case let .genre(id):
            return catalog.movies.filter { $0.genreIDs.contains(id) }.sorted { $0.addedAt > $1.addedAt }.map { .movie($0.id) }
        }
    }

    func collectionTitle(_ collection: GalleryCollection) -> String {
        switch collection {
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .unwatched: "Unwatched"
        case let .genre(id): genreNames[id] ?? "Genre"
        }
    }

    // MARK: Building

    private func rebuildCatalog() {
        catalog = GalleryCatalog.build(files: files, matches: matches)
        rebuildShelves()
        refreshSpotlight()
    }

    private func rebuildShelves() {
        var shelves = GalleryShelves()
        let catalog = catalog
        let watch = watch

        // Watching: files with a resume point, newest first, one card per show.
        var seenTitles = Set<GalleryTitle>()
        let inProgress = watch.progress.keys
            .compactMap { path -> (String, GalleryTitle, Date)? in
                guard case .inProgress = watch.status(path), let title = catalog.title(forPath: path) else { return nil }
                return (path, title, watch.progress[path]?.updatedAt ?? .distantPast)
            }
            .sorted { $0.2 > $1.2 }
        for (path, title, date) in inProgress where seenTitles.insert(title).inserted {
            shelves.playEntries.append(GalleryPlayEntry(title: title, path: path, date: date, section: .watching, status: watch.status(path)))
        }

        // Recently Watched: finished or opened files, excluding titles already above.
        let recent = Set(watch.watched.keys).union(watch.opened.keys)
            .compactMap { path -> (String, GalleryTitle, Date)? in
                guard let title = catalog.title(forPath: path), let date = watch.lastActivity(path) else { return nil }
                return (path, title, date)
            }
            .sorted { $0.2 > $1.2 }
        var recentCount = 0
        for (path, title, date) in recent where recentCount < 20 && seenTitles.insert(title).inserted {
            shelves.playEntries.append(GalleryPlayEntry(title: title, path: path, date: date, section: .recent, status: watch.status(path)))
            recentCount += 1
        }

        // Genres: by number of movies, artwork from the newest ones.
        var genreMovies: [Int: [GalleryMovie]] = [:]
        for movie in catalog.movies {
            for genre in movie.genreIDs { genreMovies[genre, default: []].append(movie) }
        }
        shelves.genres = genreMovies
            .compactMap { id, movies -> GalleryGenreTile? in
                guard let name = genreNames[id] else { return nil }
                let recent = movies.sorted { $0.addedAt > $1.addedAt }
                return GalleryGenreTile(
                    genre: TMDBGenre(id: id, name: name),
                    count: movies.count,
                    posters: Array(recent.compactMap(\.posterPath).prefix(3)),
                    backdrop: recent.lazy.compactMap(\.backdropPath).first
                )
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.genre.name < $1.genre.name }

        // Unwatched: untouched movies and shows not yet started, newest first.
        let untouched = { (path: String) in watch.status(path) == .unwatched }
        let unwatchedMovies = catalog.movies.filter { $0.paths.allSatisfy(untouched) }.map { (GalleryTitle.movie($0.id), $0.addedAt) }
        let unwatchedShows = catalog.shows.filter { $0.paths.allSatisfy(untouched) }.map { (GalleryTitle.show($0.id), $0.addedAt) }
        shelves.unwatched = (unwatchedMovies + unwatchedShows).sorted { $0.1 > $1.1 }.map(\.0)

        shelves.shows = catalog.shows.sorted { $0.addedAt > $1.addedAt }
        shelves.movies = catalog.movies.sorted { $0.addedAt > $1.addedAt }
        self.shelves = shelves
    }

    // MARK: Metadata

    private func loadGenres() {
        guard let tmdb else { return }
        Task { [weak self] in
            guard let genres = try? await tmdb.movieGenres() else { return }
            guard let self else { return }
            self.genreNames = Dictionary(uniqueKeysWithValues: genres.map { ($0.id, $0.name) })
            self.rebuildShelves()
        }
    }

    /// Searches TMDB for every title without a fresh match, a few at a time,
    /// refreshing the shelves as posters arrive.
    private func matchMissing() {
        guard let tmdb else { return }
        matchTask?.cancel()

        var pending: [String: ParsedMedia] = [:]
        for file in files {
            let key = GalleryMatchKey.key(for: file.parsed)
            if let existing = matches[key], !existing.isStale() { continue }
            if pending[key] == nil || (pending[key]?.year == nil && file.parsed.year != nil) {
                pending[key] = file.parsed
            }
        }
        guard !pending.isEmpty else { return }
        let work = Array(pending)
        matchProgress = (0, work.count)

        matchTask = Task { [weak self] in
            var done = 0
            var issue: String?
            await withTaskGroup(of: (String, Result<GalleryMatch, Error>).self) { group in
                var iterator = work.makeIterator()
                func enqueue() {
                    guard let next = iterator.next() else { return }
                    let (key, parsed) = next
                    group.addTask {
                        do {
                            return (key, .success(try await GalleryMatcher.match(parsed, client: tmdb)))
                        } catch {
                            return (key, .failure(error))
                        }
                    }
                }
                for _ in 0 ..< 6 { enqueue() }
                var lastPublish = Date()
                while let reply = await group.next() {
                    guard !Task.isCancelled, let self else { return }
                    done += 1
                    switch reply.1 {
                    case let .success(match):
                        self.matches[reply.0] = match
                    case .failure(TMDBError.unauthorized):
                        issue = "TMDB rejected the API key. Check TMDB.local.plist."
                    case .failure:
                        issue = issue ?? "Some titles could not reach TMDB. They will retry on the next visit."
                    }
                    self.matchProgress = (done, work.count)
                    // Fill posters in as they land without rebuilding on every reply.
                    if Date().timeIntervalSince(lastPublish) > 0.8 {
                        lastPublish = Date()
                        self.rebuildCatalog()
                    }
                    enqueue()
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.store.saveMatches(self.matches, language: self.metadataLanguage)
            self.rebuildCatalog()
            self.matchProgress = nil
            self.metadataIssue = issue
        }
    }
}

/// Picks the TMDB entry for a parsed title.
enum GalleryMatcher {
    static func match(_ parsed: ParsedMedia, client: TMDBClient) async throws -> GalleryMatch {
        let queries = MediaNameParser.searchQueries(for: parsed.title)
        switch parsed.kind {
        case .movie:
            for query in queries {
                var results = try await client.searchMovies(query: query, year: parsed.year)
                if results.isEmpty, parsed.year != nil {
                    // Release years drift by one between regions and file names.
                    results = try await client.searchMovies(query: query, year: nil)
                        .filter { result in
                            guard let year = parsed.year, let found = result.releaseDate.flatMap({ Int($0.prefix(4)) }) else { return true }
                            return abs(found - year) <= 1
                        }
                }
                if let best = bestMovie(results, query: query) {
                    let match = GalleryMatch(
                        tmdbID: best.id, title: best.title, overview: best.overview, posterPath: best.posterPath,
                        backdropPath: best.backdropPath, genreIDs: best.genreIds ?? [], date: best.releaseDate,
                        rating: best.voteAverage, matchedAt: Date()
                    )
                    return await withFallbackArtwork(match, client: client) { try await client.images(movieID: best.id) }
                }
            }
        case .episode:
            for query in queries {
                var results = try await client.searchShows(query: query, year: parsed.year)
                if results.isEmpty, parsed.year != nil {
                    results = try await client.searchShows(query: query, year: nil)
                }
                if let best = bestShow(results, query: query) {
                    let match = GalleryMatch(
                        tmdbID: best.id, title: best.name, overview: best.overview, posterPath: best.posterPath,
                        backdropPath: best.backdropPath, genreIDs: best.genreIds ?? [], date: best.firstAirDate,
                        rating: best.voteAverage, matchedAt: Date()
                    )
                    return await withFallbackArtwork(match, client: client) { try await client.images(showID: best.id) }
                }
            }
        }
        return .unmatched()
    }

    /// Localized search results omit artwork that only exists in other
    /// languages; borrow it (viewer's language, then English, then textless).
    private static func withFallbackArtwork(
        _ match: GalleryMatch,
        client: TMDBClient,
        images: () async throws -> TMDBImageSet
    ) async -> GalleryMatch {
        guard match.posterPath == nil || match.backdropPath == nil, let set = try? await images() else { return match }
        let primary = String(client.language.prefix(2))
        var updated = match
        updated.posterPath = match.posterPath ?? TMDBImageSet.best(set.posters, languages: [primary, "en", nil])
        updated.backdropPath = match.backdropPath ?? TMDBImageSet.best(set.backdrops, languages: [nil, "en", primary])
        return updated
    }

    /// An exact title match wins; otherwise the most-voted of TMDB's top
    /// results, because its relevance order can rank a one-vote TV special
    /// above the film itself.
    private static func bestMovie(_ results: [TMDBMovieResult], query: String) -> TMDBMovieResult? {
        let key = MediaNameParser.key(for: query)
        return results.first { MediaNameParser.key(for: $0.title ?? "") == key || MediaNameParser.key(for: $0.originalTitle ?? "") == key }
            ?? results.prefix(5).max { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }
    }

    private static func bestShow(_ results: [TMDBShowResult], query: String) -> TMDBShowResult? {
        let key = MediaNameParser.key(for: query)
        return results.first { MediaNameParser.key(for: $0.name ?? "") == key || MediaNameParser.key(for: $0.originalName ?? "") == key }
            ?? results.prefix(5).max { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }
    }
}
