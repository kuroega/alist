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
    case unindexed
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

/// Every shelf but Un-indexed holds only titles with an exact TMDB match;
/// Un-indexed holds the rest, including titles still waiting for a lookup.
struct GalleryShelves {
    var playEntries: [GalleryPlayEntry] = []
    var genres: [GalleryGenreTile] = []
    var unwatched: [GalleryTitle] = []
    var shows: [GalleryShow] = []
    var movies: [GalleryMovie] = []
    var unindexed: [GalleryTitle] = []
}

@MainActor
final class GalleryViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Reading the stored library from disk.
        case loading
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
    @Published private(set) var libraryIssue: String?

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
    private var database: GalleryDatabase { store.database }
    private let progressStore: PlaybackProgressStore
    private let recentItemsStore: RecentItemsStore
    private let account: RecentItemsAccount
    private let onPlay: @MainActor (AListObject) async -> Void
    private let onUnauthorized: @MainActor () async -> Void
    private let tmdbAPIKey: String?

    /// The indexed videos, mirroring the store, keyed by path.
    private var files: [String: LibraryFile] = [:]
    private var matches: [String: GalleryMatch] = [:]
    private var scanState = GalleryScanState()
    private var didLoad = false
    private var isLoaded = false
    private var loadTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Bumped per scan so a cancelled scan's late updates are ignored.
    private var scanGeneration = 0
    private var rebuildTask: Task<Void, Never>?
    /// Bumped per catalog build so a slower, older build never lands last.
    private var catalogVersion = 0

    /// Titles waiting for a TMDB lookup, by match key.
    private var matchQueue: [String: ParsedMedia] = [:]
    private var matchingKeys = Set<String>()
    private var matchesDone = 0
    /// False until the stored matches for the current language are loaded.
    private var matchesReady = false
    private var matchTask: Task<Void, Never>?
    /// Bumped whenever matching restarts (language switch, refresh).
    private var matchGeneration = 0

    private var movieDetails: [Int: TMDBMovieDetail] = [:]
    private var showDetails: [Int: TMDBShowDetail] = [:]
    private var seasonDetails: [String: TMDBSeasonDetail] = [:]

    /// A library older than this is updated quietly in the background on appear.
    private let staleInterval: TimeInterval = 6 * 3600
    /// Folders skipped because their modified time held still are listed
    /// again this often, for servers whose folder times never change.
    private let fullScanInterval: TimeInterval = 7 * 86_400

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
        loadTask?.cancel()
        scanTask?.cancel()
        matchTask?.cancel()
        rebuildTask?.cancel()
    }

    // MARK: Lifecycle

    func onAppear() {
        reloadWatchState()
        if didLoad {
            guard isLoaded else { return }
            // Retries titles a paused or failed run left without a match.
            enqueueMatches(for: files.values)
            if !isScanning, let mode = dueScanMode() { startScan(mode) }
            return
        }
        startLoading()
    }

    /// Reads the stored library, shows it, then looks up only titles without
    /// a match and walks the server only when the last scan is due.
    private func startLoading() {
        guard !didLoad else { return }
        didLoad = true
        phase = .loading
        loadGenres()
        loadTask = Task { [weak self] in
            guard let database = self?.database, let language = self?.metadataLanguage else { return }
            let storedFiles = await database.loadFiles()
            let storedMatches = await database.loadMatches(language: language)
            let state = await database.loadScanState()
            guard let self, !Task.isCancelled else { return }
            let roots = self.roots
            for file in storedFiles where LibraryScanner.isInside(file.path, roots: roots) {
                self.files[file.path] = file
            }
            self.scanState = state
            self.lastScan = state.completedAt
            self.isLoaded = true
            // A language switch while loading has loaded its own matches.
            if language == self.metadataLanguage, !self.matchesReady {
                self.matches = storedMatches
                self.matchesReady = true
            }
            self.rebuildCatalog()
            self.phase = .ready
            self.enqueueMatches(for: self.files.values)
            if let mode = self.dueScanMode() { self.startScan(mode) }
        }
    }

    /// Nil while the stored library is fresh enough to show as it is.
    private func dueScanMode(now: Date = Date()) -> LibraryScanner.Mode? {
        guard let completed = scanState.completedAt, scanState.roots == LibraryScanner.minimalRoots(roots) else { return .quick }
        if now.timeIntervalSince(scanState.fullCompletedAt ?? .distantPast) > fullScanInterval { return .full }
        if now.timeIntervalSince(completed) > staleInterval { return .quick }
        return nil
    }

    /// Picks up what changed on the server since the last scan, listing only
    /// folders that may have changed.
    func updateLibrary() { requestScan(.quick) }

    /// Lists every library folder again. Titles already matched are kept;
    /// only new ones are looked up on TMDB.
    func rescanAllFolders() { requestScan(.full) }

    private func requestScan(_ mode: LibraryScanner.Mode) {
        guard isLoaded else {
            // The stored library loads first and scans when it finishes.
            startLoading()
            return
        }
        startScan(mode)
    }

    private func startScan(_ mode: LibraryScanner.Mode) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let roots = roots
        let scanner = LibraryScanner(api: api, database: database)
        libraryIssue = nil
        phase = .scanning(LibraryScanProgress(foldersScanned: 0, videosFound: 0, currentFolder: roots.first ?? "/"))
        let progress: @Sendable (LibraryScanProgress) async -> Void = { [weak self] progress in
            await self?.scanProgressed(progress, generation: generation)
        }
        let changes: @Sendable (LibraryChange) async -> Void = { [weak self] change in
            await self?.apply(change, generation: generation)
        }
        scanTask = Task { [weak self] in
            do {
                // Start from the store: an interrupted scan may have saved
                // listings whose changes never reached this view model.
                if let stored = await self?.database.loadFiles() {
                    self?.resync(stored, generation: generation)
                }
                try Task.checkCancellation()
                let result = try await scanner.scan(roots: roots, mode: mode, progress: progress, changes: changes)
                guard let self, self.scanGeneration == generation, !Task.isCancelled else { return }
                self.finishScan(result, roots: roots)
            } catch AListAPIError.unauthorized {
                guard let self, self.scanGeneration == generation else { return }
                await self.onUnauthorized()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.scanGeneration == generation, !Task.isCancelled else { return }
                // Keep showing the stored index if there is one.
                self.phase = self.files.isEmpty ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) : .ready
            }
        }
    }

    private func resync(_ stored: [LibraryFile], generation: Int) {
        guard scanGeneration == generation else { return }
        let roots = roots
        var fresh: [String: LibraryFile] = [:]
        for file in stored where LibraryScanner.isInside(file.path, roots: roots) { fresh[file.path] = file }
        guard fresh != files else { return }
        files = fresh
        enqueueMatches(for: files.values)
        scheduleRebuild()
    }

    private func scanProgressed(_ progress: LibraryScanProgress, generation: Int) {
        guard scanGeneration == generation, isScanning else { return }
        phase = .scanning(progress)
    }

    /// Mirrors a scan's changes. A cancelled scan's late changes are dropped;
    /// the store keeps them and the next scan re-syncs from it first.
    private func apply(_ change: LibraryChange, generation: Int) {
        guard scanGeneration == generation else { return }
        for path in change.removed { files[path] = nil }
        for (path, file) in change.upserted { files[path] = file }
        enqueueMatches(for: change.upserted.values)
        scheduleRebuild()
    }

    private func finishScan(_ result: LibraryScanResult, roots: [String]) {
        if result.isComplete {
            let now = Date()
            scanState.completedAt = now
            if result.foldersReused == 0 { scanState.fullCompletedAt = now }
            scanState.roots = LibraryScanner.minimalRoots(roots)
            lastScan = now
            forgetRemovedTitles()
        }
        if result.foldersFailed > 0 {
            libraryIssue = result.foldersListed == 0
                ? "Couldn’t reach your library folders."
                : "\(result.foldersFailed) folder\(result.foldersFailed == 1 ? "" : "s") couldn’t be read."
        }
        rebuildCatalog()
        if result.foldersListed == 0, result.foldersFailed > 0, files.isEmpty {
            phase = .failed("Couldn’t read your library folders. Check the server and try again.")
        } else {
            phase = .ready
        }
        // Titles that failed to reach TMDB, or misses due a retry, go again.
        enqueueMatches(for: files.values)
    }

    /// Mirrors the store's clean-up at the end of a complete scan: titles no
    /// indexed video has any more lose their match and are not looked up.
    private func forgetRemovedTitles() {
        let keys = Set(files.values.map { GalleryMatchKey.key(for: $0.parsed) })
        matches = matches.filter { keys.contains($0.key) }
        matchQueue = matchQueue.filter { keys.contains($0.key) }
        updateMatchProgress()
    }

    var prefersEnglishMetadata: Bool { store.prefersEnglishMetadata }

    /// The TMDB language in use; also keys the stored matches.
    var metadataLanguage: String { tmdb?.language ?? "none" }

    /// Switches TMDB between the system language and English, then matches
    /// the library again so titles and artwork follow.
    func setPrefersEnglishMetadata(_ english: Bool) {
        guard english != store.prefersEnglishMetadata else { return }
        store.prefersEnglishMetadata = english
        tmdb = Self.makeClient(apiKey: tmdbAPIKey, englishOnly: english)
        resetMetadata()
    }

    private static func makeClient(apiKey: String?, englishOnly: Bool) -> TMDBClient? {
        apiKey.map { TMDBClient(apiKey: $0, language: englishOnly ? "en-US" : TMDBConfiguration.language()) }
    }

    /// Force clean-up: forgets every stored TMDB match (in every language),
    /// every cached TMDB response and all downloaded artwork, then looks the
    /// whole library up again from scratch. The video index is kept.
    func cleanUpAndRefreshMetadata() {
        stopMatching()
        database.removeAllMatches()
        ArtworkPipeline.shared.removeAll()
        Task {
            await TMDBResponseCache().removeAll()
            resetMetadata()
        }
    }

    private func stopMatching() {
        matchTask?.cancel()
        matchTask = nil
        matchGeneration += 1
        matchQueue.removeAll()
        matchingKeys.removeAll()
        matchesDone = 0
        matchProgress = nil
        matchesReady = false
    }

    /// Drops what is known in memory and loads the stored matches for the
    /// current language before looking up whatever they do not cover.
    private func resetMetadata() {
        stopMatching()
        let generation = matchGeneration
        let language = metadataLanguage
        matches = [:]
        metadataIssue = nil
        movieDetails = [:]
        showDetails = [:]
        seasonDetails = [:]
        genreNames = [:]
        rebuildCatalog()
        loadGenres()
        Task { [weak self] in
            guard let database = self?.database else { return }
            let stored = await database.loadMatches(language: language)
            guard let self, self.matchGeneration == generation, self.metadataLanguage == language else { return }
            self.matches = stored
            self.matchesReady = true
            self.rebuildCatalog()
            self.enqueueMatches(for: self.files.values)
        }
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
        // Videos outside the folders leave at once; new ones arrive as the
        // scan finds them, reusing every folder already in the store.
        let roots = roots
        files = files.filter { LibraryScanner.isInside($0.key, roots: roots) }
        rebuildCatalog()
        requestScan(.quick)
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

    /// Drops every resume point of a title so it leaves Watching; its history
    /// and watched marks stay, so it falls back to Recently Watched.
    func removeFromWatching(_ title: GalleryTitle) {
        for path in paths(for: title) where watch.progress[path] != nil {
            progressStore.remove(identity: PlaybackProgressIdentity(baseURL: account.baseURL, username: account.username, virtualPath: path))
        }
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
            return shelves.movies.map { .movie($0.id) }
        case .shows:
            return shelves.shows.map { .show($0.id) }
        case .unwatched:
            return shelves.unwatched
        case let .genre(id):
            return shelves.movies.filter { $0.genreIDs.contains(id) }.map { .movie($0.id) }
        case .unindexed:
            return shelves.unindexed
        }
    }

    func collectionTitle(_ collection: GalleryCollection) -> String {
        switch collection {
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .unwatched: "Unwatched"
        case let .genre(id): genreNames[id] ?? "Genre"
        case .unindexed: "Un-indexed"
        }
    }

    /// An un-indexed title whose TMDB lookup has not answered yet (queued,
    /// in flight, or unable to reach TMDB), as opposed to a confirmed miss.
    func isAwaitingMatch(_ title: GalleryTitle) -> Bool {
        guard tmdb != nil, !catalog.isIndexed(title) else { return false }
        let file: LibraryFile?
        switch title {
        case let .movie(id): file = catalog.movie(id)?.files.first
        case let .show(id): file = catalog.show(id)?.episodes.first?.file
        }
        guard let file else { return false }
        return matches[GalleryMatchKey.key(for: file.parsed)] == nil
    }

    // MARK: Building

    /// Coalesces the bursts of updates a scan produces into one rebuild.
    private func scheduleRebuild() {
        guard rebuildTask == nil else { return }
        let delay: Duration = catalog.isEmpty ? .milliseconds(300) : .seconds(1)
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Cleared before building so changes arriving meanwhile schedule another.
            self.rebuildTask = nil
            self.catalogVersion += 1
            let version = self.catalogVersion
            let files = self.files
            let matches = self.matches
            // Grouping a large library is too slow for the main thread.
            let catalog = await Task.detached(priority: .userInitiated) {
                GalleryCatalog.build(files: files.values.sorted { $0.path < $1.path }, matches: matches)
            }.value
            guard version == self.catalogVersion else { return }
            self.apply(catalog)
        }
    }

    private func rebuildCatalog() {
        rebuildTask?.cancel()
        rebuildTask = nil
        catalogVersion += 1
        // Path order keeps grouping stable between rebuilds.
        apply(GalleryCatalog.build(files: files.values.sorted { $0.path < $1.path }, matches: matches))
    }

    private func apply(_ catalog: GalleryCatalog) {
        self.catalog = catalog
        rebuildShelves()
        refreshSpotlight()
    }

    private func rebuildShelves() {
        var shelves = GalleryShelves()
        let catalog = catalog
        let watch = watch
        let indexedMovies = catalog.movies.filter(\.isIndexed)
        let indexedShows = catalog.shows.filter(\.isIndexed)

        // Watching: files with a resume point, newest first, one card per show.
        var seenTitles = Set<GalleryTitle>()
        let inProgress = watch.progress.keys
            .compactMap { path -> (String, GalleryTitle, Date)? in
                guard case .inProgress = watch.status(path), let title = catalog.title(forPath: path), catalog.isIndexed(title) else { return nil }
                return (path, title, watch.progress[path]?.updatedAt ?? .distantPast)
            }
            .sorted { $0.2 > $1.2 }
        for (path, title, date) in inProgress where seenTitles.insert(title).inserted {
            shelves.playEntries.append(GalleryPlayEntry(title: title, path: path, date: date, section: .watching, status: watch.status(path)))
        }

        // Recently Watched: finished or opened files, excluding titles already above.
        let recent = Set(watch.watched.keys).union(watch.opened.keys)
            .compactMap { path -> (String, GalleryTitle, Date)? in
                guard let title = catalog.title(forPath: path), catalog.isIndexed(title), let date = watch.lastActivity(path) else { return nil }
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
        for movie in indexedMovies {
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
        let unwatchedMovies = indexedMovies.filter { $0.paths.allSatisfy(untouched) }.map { (GalleryTitle.movie($0.id), $0.addedAt) }
        let unwatchedShows = indexedShows.filter { $0.paths.allSatisfy(untouched) }.map { (GalleryTitle.show($0.id), $0.addedAt) }
        shelves.unwatched = (unwatchedMovies + unwatchedShows).sorted { $0.1 > $1.1 }.map(\.0)

        shelves.shows = indexedShows.sorted { $0.addedAt > $1.addedAt }
        shelves.movies = indexedMovies.sorted { $0.addedAt > $1.addedAt }

        // Un-indexed: everything without an exact TMDB match, newest first.
        let unindexedMovies = catalog.movies.filter { !$0.isIndexed }.map { (GalleryTitle.movie($0.id), $0.addedAt) }
        let unindexedShows = catalog.shows.filter { !$0.isIndexed }.map { (GalleryTitle.show($0.id), $0.addedAt) }
        shelves.unindexed = (unindexedMovies + unindexedShows).sorted { $0.1 > $1.1 }.map(\.0)
        self.shelves = shelves
    }

    // MARK: Metadata

    private func loadGenres() {
        guard let tmdb else { return }
        Task { [weak self] in
            guard let genres = try? await tmdb.movieGenres() else { return }
            guard let self, self.tmdb === tmdb else { return }
            self.genreNames = Dictionary(genres.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            self.rebuildShelves()
        }
    }

    /// Queues every title among `candidates` that has no fresh match.
    /// Titles matched before (in any session) are never looked up again.
    private func enqueueMatches<Files: Sequence>(for candidates: Files) where Files.Element == LibraryFile {
        guard tmdb != nil, matchesReady else { return }
        for file in candidates {
            let key = GalleryMatchKey.key(for: file.parsed)
            if let existing = matches[key], !existing.isStale() { continue }
            if matchingKeys.contains(key) { continue }
            if let queued = matchQueue[key] {
                if queued.year == nil, file.parsed.year != nil { matchQueue[key] = file.parsed }
                continue
            }
            matchQueue[key] = file.parsed
        }
        updateMatchProgress()
        startMatching()
    }

    private func updateMatchProgress() {
        let remaining = matchingKeys.count + matchQueue.count
        matchProgress = remaining == 0 ? nil : (matchesDone, matchesDone + remaining)
    }

    private func startMatching() {
        guard matchTask == nil, !matchQueue.isEmpty, let tmdb else { return }
        let generation = matchGeneration
        let language = metadataLanguage
        matchTask = Task { [weak self] in
            await self?.runMatching(client: tmdb, language: language, generation: generation)
        }
    }

    /// Lookups wait on TMDB round trips, not the CPU, so many run at once;
    /// the client's gate keeps the requests themselves within TMDB's limits.
    static let concurrentMatches = 24
    /// Lookups failing in a row on the network before matching pauses: past
    /// this, TMDB is unreachable from here and every lookup would time out.
    static let unreachableAfter = 20

    /// Looks titles up many at a time, saving answers in small batches and
    /// refreshing the shelves as posters land. Titles queued meanwhile join in.
    private func runMatching(client: TMDBClient, language: String, generation: Int) async {
        var issue: String?
        var stopped = false
        var unsaved: [String: GalleryMatch] = [:]
        var lastSave = Date()
        var networkFailures = 0
        await withTaskGroup(of: (String, Result<GalleryMatch, Error>).self) { group in
            var running = 0
            while true {
                while running < Self.concurrentMatches, !stopped, let next = matchQueue.popFirst() {
                    matchingKeys.insert(next.key)
                    running += 1
                    group.addTask {
                        do {
                            return (next.key, .success(try await GalleryMatcher.match(next.value, client: client)))
                        } catch {
                            return (next.key, .failure(error))
                        }
                    }
                }
                guard running > 0, let reply = await group.next() else { break }
                let (key, result) = reply
                running -= 1
                guard generation == matchGeneration, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                matchingKeys.remove(key)
                matchesDone += 1
                switch result {
                case let .success(match):
                    networkFailures = 0
                    matches[key] = match
                    unsaved[key] = match
                case .failure(TMDBError.unauthorized):
                    issue = "TMDB rejected the API key. Check TMDB.local.plist."
                    // Every other lookup would fail the same way.
                    stopped = true
                    matchQueue.removeAll()
                case .failure(TMDBError.transport):
                    networkFailures += 1
                    issue = issue ?? "Some titles could not reach TMDB. They will retry on the next update."
                    if networkFailures >= Self.unreachableAfter, !stopped {
                        issue = "Can't reach TMDB from this network (requests time out). Matching is paused and resumes when you reopen the Gallery."
                        stopped = true
                        matchQueue.removeAll()
                    }
                case .failure:
                    issue = issue ?? "Some titles could not reach TMDB. They will retry on the next update."
                }
                updateMatchProgress()
                if unsaved.count >= 50 || Date().timeIntervalSince(lastSave) > 1 {
                    database.saveMatches(unsaved, language: language)
                    unsaved.removeAll()
                    lastSave = Date()
                }
                // Fill posters in as they land without rebuilding on every reply.
                scheduleRebuild()
            }
        }
        // A restart (language switch, clean-up) drops what this run has not saved.
        guard generation == matchGeneration else { return }
        database.saveMatches(unsaved, language: language)
        matchTask = nil
        rebuildCatalog()
        if let issue { metadataIssue = issue }
        if matchQueue.isEmpty {
            matchesDone = 0
            if issue == nil { metadataIssue = nil }
            updateMatchProgress()
        } else {
            startMatching()
        }
    }
}

/// Picks the TMDB entry for a parsed title. Only an exact title match
/// counts: TMDB's title or original title must equal the file's title once
/// case, spacing and punctuation are ignored (in the metadata language, or
/// failing that in English). Anything else is left un-indexed.
enum GalleryMatcher {
    /// Stored with every match. Bump it whenever the rules below change so
    /// stored matches made under older rules are looked up again.
    static let version = 2

    static func match(_ parsed: ParsedMedia, client: TMDBClient) async throws -> GalleryMatch {
        let queries = MediaNameParser.searchQueries(for: parsed.title)
        let english = client.language.lowercased().hasPrefix("en")
        switch parsed.kind {
        case .movie:
            for query in queries {
                if let hit = try await findMovie(query, year: parsed.year, language: nil, client: client) {
                    return await movieMatch(hit, client: client)
                }
            }
            // English release names of foreign films: confirm the English
            // title, then take the entry in the viewer's language.
            guard !english else { break }
            for query in queries {
                guard let hit = try await findMovie(query, year: parsed.year, language: "en-US", client: client) else { continue }
                let localized = try await movieCandidates(query, year: parsed.year, language: nil, client: client).first { $0.id == hit.id }
                return await movieMatch(localized ?? hit, client: client)
            }
        case .episode:
            for query in queries {
                if let hit = try await findShow(query, year: parsed.year, language: nil, client: client) {
                    return await showMatch(hit, client: client)
                }
            }
            guard !english else { break }
            for query in queries {
                guard let hit = try await findShow(query, year: parsed.year, language: "en-US", client: client) else { continue }
                let localized = try await showCandidates(query, year: parsed.year, language: nil, client: client).first { $0.id == hit.id }
                return await showMatch(localized ?? hit, client: client)
            }
        }
        return .unmatched()
    }

    // MARK: Movies

    private static func findMovie(_ query: String, year: Int?, language: String?, client: TMDBClient) async throws -> TMDBMovieResult? {
        if let year, let hit = exactMovie(in: try await client.searchMovies(query: query, year: year, language: language), query: query) {
            return hit
        }
        return exactMovie(in: try await anyYearMovies(query, year: year, language: language, client: client), query: query)
    }

    /// The same searches `findMovie` runs (served from the response cache).
    private static func movieCandidates(_ query: String, year: Int?, language: String?, client: TMDBClient) async throws -> [TMDBMovieResult] {
        var results: [TMDBMovieResult] = []
        if let year { results += try await client.searchMovies(query: query, year: year, language: language) }
        results += try await anyYearMovies(query, year: year, language: language, client: client)
        return results
    }

    /// Unfiltered search; release years drift by one between regions and
    /// file names, so a known year still has to agree within one.
    private static func anyYearMovies(_ query: String, year: Int?, language: String?, client: TMDBClient) async throws -> [TMDBMovieResult] {
        try await client.searchMovies(query: query, year: nil, language: language).filter { result in
            guard let year, let found = result.releaseDate.flatMap({ Int($0.prefix(4)) }) else { return true }
            return abs(found - year) <= 1
        }
    }

    /// Among results whose title is exactly the query, the most-voted; ties
    /// keep TMDB's relevance order.
    static func exactMovie(in results: [TMDBMovieResult], query: String) -> TMDBMovieResult? {
        let key = MediaNameParser.key(for: query)
        guard !key.isEmpty else { return nil }
        return results
            .filter { MediaNameParser.key(for: $0.title ?? "") == key || MediaNameParser.key(for: $0.originalTitle ?? "") == key }
            .max { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }
    }

    private static func movieMatch(_ result: TMDBMovieResult, client: TMDBClient) async -> GalleryMatch {
        let match = GalleryMatch(
            tmdbID: result.id, title: result.title, overview: result.overview, posterPath: result.posterPath,
            backdropPath: result.backdropPath, genreIDs: result.genreIds ?? [], date: result.releaseDate,
            rating: result.voteAverage, matchedAt: Date()
        )
        return await withFallbackArtwork(match, client: client) { try await client.images(movieID: result.id) }
    }

    // MARK: Shows

    private static func findShow(_ query: String, year: Int?, language: String?, client: TMDBClient) async throws -> TMDBShowResult? {
        if let year, let hit = exactShow(in: try await client.searchShows(query: query, year: year, language: language), query: query, year: year) {
            return hit
        }
        // A year in an episode's name may be the season's, not the show's
        // first air date, so here it only breaks ties.
        return exactShow(in: try await client.searchShows(query: query, year: nil, language: language), query: query, year: year)
    }

    private static func showCandidates(_ query: String, year: Int?, language: String?, client: TMDBClient) async throws -> [TMDBShowResult] {
        var results: [TMDBShowResult] = []
        if let year { results += try await client.searchShows(query: query, year: year, language: language) }
        results += try await client.searchShows(query: query, year: nil, language: language)
        return results
    }

    /// Among results whose name is exactly the query, the most-voted one
    /// first aired within a year of `year`, else the most-voted overall.
    static func exactShow(in results: [TMDBShowResult], query: String, year: Int?) -> TMDBShowResult? {
        let key = MediaNameParser.key(for: query)
        guard !key.isEmpty else { return nil }
        let exact = results.filter { MediaNameParser.key(for: $0.name ?? "") == key || MediaNameParser.key(for: $0.originalName ?? "") == key }
        let mostVoted = { (candidates: [TMDBShowResult]) in candidates.max { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) } }
        if let year {
            let near = exact.filter { result in
                guard let found = result.firstAirDate.flatMap({ Int($0.prefix(4)) }) else { return false }
                return abs(found - year) <= 1
            }
            if let pick = mostVoted(near) { return pick }
        }
        return mostVoted(exact)
    }

    private static func showMatch(_ result: TMDBShowResult, client: TMDBClient) async -> GalleryMatch {
        let match = GalleryMatch(
            tmdbID: result.id, title: result.name, overview: result.overview, posterPath: result.posterPath,
            backdropPath: result.backdropPath, genreIDs: result.genreIds ?? [], date: result.firstAirDate,
            rating: result.voteAverage, matchedAt: Date()
        )
        return await withFallbackArtwork(match, client: client) { try await client.images(showID: result.id) }
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
}
