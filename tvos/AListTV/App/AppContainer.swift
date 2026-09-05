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
    @Published private(set) var logoutError: String?


    let connectionViewModel: ConnectionViewModel

    private let controllerFactory: @MainActor () -> any PlayerControlling
    private let subtitleDataLoader: @Sendable (URL) async throws -> Data
    private let subtitleAppearanceStore: SubtitleAppearanceStore
    private let playbackProgressStore: PlaybackProgressStore
    private var didAttemptRestore = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let credentialStore: any CredentialStore
        let preferences: ConnectionPreferences
        let subtitleAppearanceStore: SubtitleAppearanceStore
        let clientFactory: AListClientFactory
        let controllerFactory: @MainActor () -> any PlayerControlling
        let subtitleDataLoader: @Sendable (URL) async throws -> Data
        let playbackProgressStore: PlaybackProgressStore

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
            clientFactory = { _, _ in fixtureAPI }
            controllerFactory = { FixturePlayerController() }
            subtitleDataLoader = FixtureSubtitleDataLoader.load
        } else {
            let sessionStore = SessionCredentialStore(backing: KeychainCredentialStore())
            credentialStore = sessionStore
            preferences = ConnectionPreferences()
            subtitleAppearanceStore = SubtitleAppearanceStore()
            playbackProgressStore = PlaybackProgressStore()
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
        connectionViewModel = ConnectionViewModel(
            preferences: preferences,
            credentialStore: credentialStore,
            clientFactory: clientFactory
        )
    }

    func restoreSession() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
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
            baseURL: connection.baseURL,
            username: connection.username,
            onUnauthorized: { [weak self] in self?.handleUnauthorized() },
            subtitleDataLoader: subtitleDataLoader
        )
        playerCoordinator = player
        browserViewModel = BrowserViewModel(
            api: api,
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
        route = .connection
    }
}
