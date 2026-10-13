import Combine
import Foundation

@MainActor
final class AppContainer: ObservableObject {
    enum Route {
        case connection
        case browser
    }

    @Published private(set) var route: Route = .connection
    @Published private(set) var browserViewModel: BrowserViewModel?
    @Published private(set) var playerCoordinator: PlayerCoordinator?
    @Published private(set) var recentsViewModel: RecentsViewModel?
    @Published private(set) var galleryViewModel: GalleryViewModel?
    @Published private(set) var logoutError: String?
    @Published private(set) var isRestoringSession = true


    let connectionViewModel: ConnectionViewModel
    /// Backing store for view preferences such as the home mode and layout.
    let appStorage: UserDefaults

    private let controllerFactory: @MainActor () -> any PlayerControlling
    private let subtitleDataLoader: @Sendable (URL) async throws -> Data
    private let subtitleAppearanceStore: SubtitleAppearanceStore
    private let playbackProgressStore: PlaybackProgressStore
    private let playbackSettingsStore: PlaybackSettingsStore
    private let recentItemsStore: RecentItemsStore
    private let tmdbAPIKey: String?
    private let galleryCacheDirectory: URL?
    private var didAttemptRestore = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let credentialStore: any CredentialStore
        let preferences: ConnectionPreferences
        let subtitleAppearanceStore: SubtitleAppearanceStore
        let clientFactory: AListClientFactory
        let controllerFactory: @MainActor () -> any PlayerControlling
        let subtitleDataLoader: @Sendable (URL) async throws -> Data
        let playbackProgressStore: PlaybackProgressStore
        let playbackSettingsStore: PlaybackSettingsStore
        let recentItemsStore: RecentItemsStore
        let appStorage: UserDefaults
        var tmdbAPIKey = TMDBConfiguration.apiKey()
        var galleryCacheDirectory: URL?

#if DEBUG
        if arguments.contains("ui-testing") {
            let defaults = UserDefaults(suiteName: "com.alist.tv.ui-testing")!
            defaults.removePersistentDomain(forName: "com.alist.tv.ui-testing")
            let memoryStore = InMemoryCredentialStore()
            let fixtureAPI = FixtureAListAPI()
            credentialStore = memoryStore
            preferences = ConnectionPreferences(defaults: defaults)
            subtitleAppearanceStore = SubtitleAppearanceStore(defaults: defaults)
            playbackProgressStore = PlaybackProgressStore(defaults: defaults)
            playbackSettingsStore = PlaybackSettingsStore(defaults: defaults)
            recentItemsStore = RecentItemsStore(defaults: defaults)
            appStorage = defaults
            clientFactory = { _, _ in fixtureAPI }
            controllerFactory = { FixturePlayerController(autoCompletesPlayback: arguments.contains("ui-testing-autoplay")) }
            subtitleDataLoader = FixtureSubtitleDataLoader.load
            // UI tests stay offline and never reuse a real library index.
            tmdbAPIKey = nil
            galleryCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-ui-testing-\(UUID().uuidString)")
        } else {
            let sessionStore = SessionCredentialStore(backing: KeychainCredentialStore())
            credentialStore = sessionStore
            preferences = ConnectionPreferences()
            subtitleAppearanceStore = SubtitleAppearanceStore()
            playbackProgressStore = PlaybackProgressStore()
            playbackSettingsStore = PlaybackSettingsStore()
        recentItemsStore = RecentItemsStore()
        appStorage = .standard
            clientFactory = { baseURL, clientID in
                AListClient(
                    baseURL: baseURL,
                    clientID: clientID,
                    tokenProvider: { sessionStore.currentToken }
                )
            }
            controllerFactory = { VLCPlayerControllerAdapter() }
            subtitleDataLoader = PlayerCoordinator.loadSubtitleData
        }
#else
        let sessionStore = SessionCredentialStore(backing: KeychainCredentialStore())
        credentialStore = sessionStore
        preferences = ConnectionPreferences()
        subtitleAppearanceStore = SubtitleAppearanceStore()
        playbackProgressStore = PlaybackProgressStore()
        playbackSettingsStore = PlaybackSettingsStore()
        recentItemsStore = RecentItemsStore()
        appStorage = .standard
        clientFactory = { baseURL, clientID in
            AListClient(
                baseURL: baseURL,
                clientID: clientID,
                tokenProvider: { sessionStore.currentToken }
            )
        }
        controllerFactory = { VLCPlayerControllerAdapter() }
        subtitleDataLoader = PlayerCoordinator.loadSubtitleData
#endif

        self.controllerFactory = controllerFactory
        self.subtitleDataLoader = subtitleDataLoader
        self.subtitleAppearanceStore = subtitleAppearanceStore
        self.playbackProgressStore = playbackProgressStore
        self.playbackSettingsStore = playbackSettingsStore
        self.recentItemsStore = recentItemsStore
        self.appStorage = appStorage
        self.tmdbAPIKey = tmdbAPIKey
        self.galleryCacheDirectory = galleryCacheDirectory
        connectionViewModel = ConnectionViewModel(
            preferences: preferences,
            credentialStore: credentialStore,
            clientFactory: clientFactory
        )
    }

    func restoreSession() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        defer { isRestoringSession = false }
        await connectionViewModel.restore()
        activateConnectedSessionIfAvailable()
    }

    func retrySessionRecovery() async {
        await connectionViewModel.restore()
        activateConnectedSessionIfAvailable()
    }

    func submit(serverURL: String, username: String, password: String) async {
        await connectionViewModel.submit(serverURL: serverURL, username: username, password: password)
        activateConnectedSessionIfAvailable()
    }

    func submitOTP(_ code: String) async {
        await connectionViewModel.submitOTP(code)
        activateConnectedSessionIfAvailable()
    }
    func logout() {
        do {
            try connectionViewModel.clearSession()
        } catch {
            logoutError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        clearActiveSession()
    }

    func dismissLogoutError() {
        logoutError = nil
    }



    private func activateConnectedSessionIfAvailable() {
        guard connectionViewModel.state == .connected,
              let api = connectionViewModel.activeAPI,
              let connection = connectionViewModel.activeConnection else { return }

        let player = PlayerCoordinator(
            api: api,
            controller: controllerFactory(),
            progressStore: playbackProgressStore,
            subtitleAppearanceStore: subtitleAppearanceStore,
            playbackSettingsStore: playbackSettingsStore,
            baseURL: connection.baseURL,
            username: connection.username,
            onUnauthorized: { [weak self] in self?.handleUnauthorized() },
            onPlaybackStarted: { [weak self] object in self?.recentsViewModel?.recordOpen(object) },
            subtitleDataLoader: subtitleDataLoader
        )
        playerCoordinator = player
        recentsViewModel = RecentsViewModel(
            store: recentItemsStore,
            progressStore: playbackProgressStore,
            baseURL: connection.baseURL,
            username: connection.username,
            onOpen: { [weak player] object in await player?.play(object: object) }
        )
        browserViewModel = BrowserViewModel(
            api: api,
            onPlay: { [weak player] object in await player?.play(object: object) },
            onUnauthorized: { [weak self] in self?.handleUnauthorized() }
        )
        galleryViewModel = GalleryViewModel(
            api: api,
            store: GalleryLibraryStore(baseURL: connection.baseURL, username: connection.username, defaults: appStorage, directory: galleryCacheDirectory),
            progressStore: playbackProgressStore,
            recentItemsStore: recentItemsStore,
            baseURL: connection.baseURL,
            username: connection.username,
            tmdbAPIKey: tmdbAPIKey,
            onPlay: { [weak player] object in await player?.play(object: object) },
            onUnauthorized: { [weak self] in self?.handleUnauthorized() }
        )
        route = .browser
    }

    private func handleUnauthorized() {
        try? connectionViewModel.clearSession()
        clearActiveSession()
    }

    private func clearActiveSession() {
        playerCoordinator?.playerDidDisappear()
        playerCoordinator = nil
        browserViewModel = nil
        recentsViewModel = nil
        galleryViewModel = nil
        route = .connection
    }
}
