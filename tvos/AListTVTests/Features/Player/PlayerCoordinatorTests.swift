import Foundation
import XCTest
@testable import AListTV

@MainActor
final class PlayerCoordinatorTests: XCTestCase {
    func testGetPrecedesItemCreation() async {
        let log = LockedEventLog()
        let api = PlayerFakeAPI(details: [detail(url: "https://media.example/video.mp4", path: "/video.mp4")], log: log)
        let player = PlayerFakeController(log: log)
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: object("/video.mp4"))

        XCTAssertEqual(log.values, ["get:/video.mp4", "replace:https://media.example/video.mp4"])
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(coordinator.state, .playing)
    }

    func testRejectsInsecureAndEmptyRawURL() async {
        let api = PlayerFakeAPI(details: [
            detail(url: "http://media.example/video.mp4", path: "/one.mp4"),
            detail(url: "", path: "/two.mp4")
        ])
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: object("/one.mp4"))
        guard case .failed = coordinator.state else { return XCTFail("HTTP URL was accepted") }
        XCTAssertTrue(coordinator.isPresented)
        coordinator.playerDidDisappear()
        await coordinator.play(object: object("/two.mp4"))
        guard case .failed = coordinator.state else { return XCTFail("Empty URL was accepted") }
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertTrue(player.replacedURLs.isEmpty)
    }

#if DEBUG
    func testAcceptsPrivateHTTPRawURLButRejectsLookalikeHost() throws {
        XCTAssertEqual(
            try PlayableURLValidator.validate("http://10.0.0.2:5244/video.mp4").absoluteString,
            "http://10.0.0.2:5244/video.mp4"
        )
        XCTAssertThrowsError(
            try PlayableURLValidator.validate("http://10.0.0.2.example.com:5244/video.mp4")
        ) { error in
            XCTAssertEqual(error as? AListAPIError, .invalidRawURL)
        }
    }
#endif

    func testDirectoryDoesNotRequestGet() async {
        let api = PlayerFakeAPI(details: [])
        let coordinator = makeCoordinator(api: api, player: PlayerFakeController())
        await coordinator.play(object: AListObject(virtualPath: "/Folder", name: "Folder", isDirectory: true))
        let paths = await api.getPaths
        XCTAssertEqual(paths, [])
    }

    func testFirstFailureRefreshesAndRestores() async throws {
        let api = PlayerFakeAPI(details: [
            detail(url: "https://media.example/first", path: "/video.mp4"),
            detail(url: "https://media.example/refreshed", path: "/video.mp4")
        ])
        let player = PlayerFakeController()
        player.currentTime = 42
        let coordinator = makeCoordinator(api: api, player: player)
        await coordinator.play(object: object("/video.mp4"))

        player.emit(.failed(message: "expired"))
        try await waitUntil { player.replacedURLs.count == 2 }

        XCTAssertEqual(player.replacedURLs.map(\.absoluteString), [
            "https://media.example/first",
            "https://media.example/refreshed"
        ])
        XCTAssertEqual(player.seekValues.last, 42)
        let paths = await api.getPaths
        XCTAssertEqual(paths.count, 2)
    }

    func testSecondFailureDoesNotRefresh() async throws {
        let api = PlayerFakeAPI(details: [
            detail(url: "https://media.example/first", path: "/video.mp4"),
            detail(url: "https://media.example/refreshed", path: "/video.mp4")
        ])
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player)
        await coordinator.play(object: object("/video.mp4"))
        player.emit(.failed(message: "first"))
        try await waitUntil { player.replacedURLs.count == 2 }
        player.emit(.failed(message: "second underlying failure"))
        try await waitUntil { coordinator.state == .failed(message: "second underlying failure") }

        let paths = await api.getPaths
        XCTAssertEqual(paths.count, 2)
    }

    func testNewObjectResetsRetryBudget() async throws {
        let api = PlayerFakeAPI(details: [
            detail(url: "https://media.example/a1", path: "/a.mp4"),
            detail(url: "https://media.example/a2", path: "/a.mp4"),
            detail(url: "https://media.example/b1", path: "/b.mp4"),
            detail(url: "https://media.example/b2", path: "/b.mp4")
        ])
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player)
        await coordinator.play(object: object("/a.mp4"))
        player.emit(.failed(message: "a"))
        try await waitUntil { player.replacedURLs.count == 2 }
        await coordinator.play(object: object("/b.mp4"))
        player.emit(.failed(message: "b"))
        try await waitUntil { player.replacedURLs.count == 4 }

        let paths = await api.getPaths
        XCTAssertEqual(paths, ["/a.mp4", "/a.mp4", "/b.mp4", "/b.mp4"])
    }

    func testSavedProgressShowsResumePromptUntilConfirmed() async throws {
        let suite = "PlayerCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PlaybackProgressStore(defaults: defaults)
        let identity = PlaybackProgressIdentity(baseURL: "https://alist.example", username: "alice", virtualPath: "/video.mp4")
        store.update(identity: identity, position: 60, duration: 200)
        let api = PlayerFakeAPI(details: [detail(url: "https://media.example/video", path: "/video.mp4")])
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player, store: store)

        await coordinator.play(object: object("/video.mp4"))

        XCTAssertEqual(coordinator.resumePrompt?.position, 60)
        XCTAssertEqual(coordinator.resumePrompt?.secondsRemaining, 5)
        XCTAssertTrue(player.seekValues.isEmpty)
        XCTAssertEqual(player.playCount, 0)

        coordinator.resumeFromSavedPosition()
        try await waitUntil { player.seekValues == [60] && player.playCount == 1 }
        XCTAssertNil(coordinator.resumePrompt)
    }

    func testSavedProgressTimesOutToBeginning() async throws {
        let suite = "PlayerCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PlaybackProgressStore(defaults: defaults)
        let identity = PlaybackProgressIdentity(baseURL: "https://alist.example", username: "alice", virtualPath: "/video.mp4")
        store.update(identity: identity, position: 60, duration: 200)
        let api = PlayerFakeAPI(details: [detail(url: "https://media.example/video", path: "/video.mp4")])
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player, store: store, resumeCountdownInterval: .milliseconds(1))

        await coordinator.play(object: object("/video.mp4"))
        try await waitUntil { coordinator.resumePrompt == nil && player.playCount == 1 }

        XCTAssertTrue(player.seekValues.isEmpty)
    }

    func testLeavingPlayerCancelsResumePrompt() async throws {
        let suite = "PlayerCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PlaybackProgressStore(defaults: defaults)
        let identity = PlaybackProgressIdentity(baseURL: "https://alist.example", username: "alice", virtualPath: "/video.mp4")
        store.update(identity: identity, position: 60, duration: 200)
        let api = PlayerFakeAPI(details: [detail(url: "https://media.example/video", path: "/video.mp4")])
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player, store: store, resumeCountdownInterval: .milliseconds(10))

        await coordinator.play(object: object("/video.mp4"))
        coordinator.playerDidDisappear()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(coordinator.resumePrompt)
        XCTAssertEqual(player.playCount, 0)
    }

    func testStartsFromBeginningWithoutSavedProgress() async {
        let api = PlayerFakeAPI(details: [detail(url: "https://media.example/video", path: "/video.mp4")])
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: object("/video.mp4"))

        XCTAssertTrue(player.seekValues.isEmpty)
        XCTAssertEqual(player.playCount, 1)
    }

    func testExternalSubtitleDiscoveryFiltersAndSortsPages() async throws {
        let pages = [
            [
                AListObject(virtualPath: "/Movie.en.srt", name: "Movie.en.srt", isDirectory: false),
                AListObject(virtualPath: "/Movie.idx", name: "Movie.idx", isDirectory: false),
                AListObject(virtualPath: "/Movie.sub", name: "Movie.sub", isDirectory: false)
            ],
            [
                AListObject(virtualPath: "/Other.ass", name: "Other.ass", isDirectory: false),
                AListObject(virtualPath: "/Movie.en.srt", name: "Movie.en.srt", isDirectory: false),
                AListObject(virtualPath: "/Folder", name: "Folder", isDirectory: true)
            ]
        ]
        let api = PlayerFakeAPI(details: [detail(url: "https://media.example/Movie.mp4", path: "/Movie.mp4")], listPages: pages)
        let coordinator = makeCoordinator(api: api, player: PlayerFakeController())

        await coordinator.play(object: object("/Movie.mp4"))
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }

        XCTAssertEqual(coordinator.externalSubtitles.map(\.title), ["Movie.en.srt", "Movie.idx", "Other.ass"])
    }

    func testExternalSubtitleSelectionResolvesSecureURL() async throws {
        let api = PlayerFakeAPI(
            details: [
                detail(url: "https://media.example/Movie.mp4", path: "/Movie.mp4"),
                detail(url: "https://media.example/Movie.en.srt", path: "/Movie.en.srt")
            ],
            listPages: [[AListObject(virtualPath: "/Movie.en.srt", name: "Movie.en.srt", isDirectory: false)]]
        )
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: object("/Movie.mp4"))
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }
        await coordinator.selectSubtitle(.external(fileID: "/Movie.en.srt"))

        XCTAssertEqual(coordinator.subtitleSelection, .external(fileID: "/Movie.en.srt"))
        XCTAssertEqual(coordinator.subtitleOverlay.cues.map(\.text), ["Native SRT subtitle"])
        XCTAssertTrue(player.addedExternalSubtitleIDs.isEmpty)
    }

    func testInvalidExternalSubtitleURLPreservesCurrentSelection() async throws {
        let api = PlayerFakeAPI(
            details: [
                detail(url: "https://media.example/Movie.mp4", path: "/Movie.mp4"),
                detail(url: "http://media.example/Movie.srt", path: "/Movie.srt")
            ],
            listPages: [[AListObject(virtualPath: "/Movie.srt", name: "Movie.srt", isDirectory: false)]]
        )
        let player = PlayerFakeController()
        player.embeddedSubtitleTracks = [PlaybackTrackOption(id: "embedded.en", title: "English", languageCode: "en", codec: "WebVTT", isSelected: false)]
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: object("/Movie.mp4"))
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }
        await coordinator.selectSubtitle(.embedded(trackID: "embedded.en"))
        await coordinator.selectSubtitle(.external(fileID: "/Movie.srt"))

        XCTAssertEqual(coordinator.subtitleSelection, .embedded(trackID: "embedded.en"))
        XCTAssertEqual(coordinator.subtitleSelectionError, "Unable to load subtitle “Movie.srt”.")
        XCTAssertTrue(coordinator.subtitleOverlay.cues.isEmpty)
    }

    func testInvalidNativeSubtitlePreservesEmbeddedSelection() async throws {
        let api = PlayerFakeAPI(
            details: [
                detail(url: "https://media.example/Movie.mp4", path: "/Movie.mp4"),
                detail(url: "https://media.example/Movie.srt", path: "/Movie.srt")
            ],
            listPages: [[AListObject(virtualPath: "/Movie.srt", name: "Movie.srt", isDirectory: false)]]
        )
        let player = PlayerFakeController()
        player.embeddedSubtitleTracks = [PlaybackTrackOption(id: "embedded.en", title: "English", languageCode: "en", codec: "WebVTT", isSelected: false)]
        let coordinator = makeCoordinator(api: api, player: player, subtitleDataLoader: { _ in
            throw AListAPIError.invalidResponse
        })

        await coordinator.play(object: object("/Movie.mp4"))
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }
        await coordinator.selectSubtitle(.embedded(trackID: "embedded.en"))
        await coordinator.selectSubtitle(.external(fileID: "/Movie.srt"))

        XCTAssertEqual(coordinator.subtitleSelection, .embedded(trackID: "embedded.en"))
        XCTAssertEqual(coordinator.subtitleSelectionError, "Unable to load subtitle “Movie.srt”.")
        XCTAssertTrue(coordinator.subtitleOverlay.cues.isEmpty)
    }

    func testExternalSubtitleDiscoveryFailureRetriesWithoutStoppingPlayback() async throws {
        let api = PlayerFakeAPI(
            details: [detail(url: "https://media.example/Movie.mp4", path: "/Movie.mp4")],
            listPages: [[AListObject(virtualPath: "/Movie.srt", name: "Movie.srt", isDirectory: false)]],
            listFailures: 1
        )
        let coordinator = makeCoordinator(api: api, player: PlayerFakeController())

        await coordinator.play(object: object("/Movie.mp4"))
        try await waitUntil {
            coordinator.externalSubtitleDiscoveryState == .failed(message: "Unable to load external subtitles.")
        }
        XCTAssertEqual(coordinator.state, .playing)

        coordinator.retryExternalSubtitleDiscovery()
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }
        XCTAssertEqual(coordinator.externalSubtitles.map(\.title), ["Movie.srt"])
    }

    func testStaleSessionDiscoveryIsIgnored() async throws {
        // Videos in different directories so each session lists a different parent.
        // /dir1/ list is held via continuation; /dir2/ list returns immediately.
        // After new session's discovery completes, the old session's list is released
        // and its result must NOT overwrite the new session's subtitles.
        let api = PlayerFakeAPI(
            details: [
                detail(url: "https://media.example/a.mp4", path: "/dir1/a.mp4"),
                detail(url: "https://media.example/b.mp4", path: "/dir2/b.mp4")
            ],
            listByPath: [
                "/dir1": [[AListObject(virtualPath: "/dir1/Stale.srt", name: "Stale.srt", isDirectory: false)]],
                "/dir2": [[AListObject(virtualPath: "/dir2/Fresh.srt", name: "Fresh.srt", isDirectory: false)]]
            ]
        )
        await api.holdListForPath("/dir1")
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: AListObject(virtualPath: "/dir1/a.mp4", name: "a.mp4", isDirectory: false))
        // Ensure the old discovery has actually reached the held continuation
        await api.waitForHeldList()
        // Now switch to a different video; old discovery is suspended inside api.list
        await coordinator.play(object: AListObject(virtualPath: "/dir2/b.mp4", name: "b.mp4", isDirectory: false))
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }

        // New session's discovery completed; only Fresh.srt should be present
        XCTAssertEqual(coordinator.externalSubtitles.map(\.title), ["Fresh.srt"])
        XCTAssertEqual(coordinator.state, .playing)

        // Release the old session's held list so its discovery completes
        await api.releaseHeldList()
        // Give the stale discovery a chance to run its post-list code
        try await Task.sleep(for: .milliseconds(50))

        // Stale result must NOT pollute the new session
        XCTAssertEqual(coordinator.externalSubtitles.map(\.title), ["Fresh.srt"])
        XCTAssertEqual(coordinator.externalSubtitleDiscoveryState, .loaded)
        XCTAssertEqual(coordinator.state, .playing)
    }

    func testRefreshReAddsExternalSubtitleAndClearsOnFailure() async throws {
        let api = PlayerFakeAPI(
            details: [
                detail(url: "https://media.example/Movie.mp4", path: "/Movie.mp4"),
                detail(url: "https://media.example/Movie.srt", path: "/Movie.srt"),
                detail(url: "https://media.example/refreshed.mp4", path: "/Movie.mp4"),
                detail(url: "http://insecure.example/sub.srt", path: "/Movie.srt")
            ],
            listPages: [[AListObject(virtualPath: "/Movie.srt", name: "Movie.srt", isDirectory: false)]]
        )
        let player = PlayerFakeController()
        player.currentTime = 42
        player.audioTracks = [
            PlaybackTrackOption(id: "audio.en", title: "English", languageCode: "en", codec: "AAC", isSelected: false),
            PlaybackTrackOption(id: "audio.zh", title: "Chinese", languageCode: "zh", codec: "AAC", isSelected: true)
        ]
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: object("/Movie.mp4"))
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }
        await coordinator.selectSubtitle(.external(fileID: "/Movie.srt"))
        XCTAssertEqual(coordinator.subtitleSelection, .external(fileID: "/Movie.srt"))

        // Trigger refresh via failure
        player.emit(.failed(message: "expired"))
        try await waitUntil { player.replacedURLs.count == 2 }
        // Wait for subtitle re-add attempt to complete
        try await waitUntil { coordinator.subtitleSelectionError != nil }

        XCTAssertEqual(coordinator.subtitleSelection, .off)
        XCTAssertEqual(player.preserveSelectionsValues, [false, true])
        XCTAssertEqual(player.seekValues.last, 42)
        XCTAssertEqual(player.audioTracks.first(where: { $0.isSelected })?.id, "audio.zh")
        XCTAssertNotNil(coordinator.subtitleSelectionError)
        XCTAssertEqual(coordinator.state, .playing)
        let paths = await api.getPaths
        XCTAssertEqual(paths.count, 4)

        XCTAssertEqual(paths, ["/Movie.mp4", "/Movie.srt", "/Movie.mp4", "/Movie.srt"])
        XCTAssertEqual(player.replacedURLs.count, 2)
        player.emit(.failed(message: "second"))
        try await waitUntil { coordinator.state == .failed(message: "second") }
        XCTAssertEqual(player.replacedURLs.count, 2)
    }

    func testCancellationSuppressesSubtitleErrors() async throws {
        let api = PlayerFakeAPI(
            details: [
                detail(url: "https://media.example/Movie.mp4", path: "/Movie.mp4"),
                detail(url: "https://media.example/Movie.srt", path: "/Movie.srt")
            ],
            listPages: [[AListObject(virtualPath: "/Movie.srt", name: "Movie.srt", isDirectory: false)]],
            listDelayMilliseconds: 50
        )
        await api.holdGetForPath("/Movie.srt")
        let player = PlayerFakeController()
        let coordinator = makeCoordinator(api: api, player: player)

        await coordinator.play(object: object("/Movie.mp4"))
        try await waitUntil { coordinator.externalSubtitleDiscoveryState == .loaded }

        let selectTask = Task { @MainActor in
            await coordinator.selectSubtitle(.external(fileID: "/Movie.srt"))
        }
        await api.waitForHeldGet()
        coordinator.playerDidDisappear()
        await api.releaseHeldGet()
        await selectTask.value

        XCTAssertNil(coordinator.subtitleSelectionError)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.subtitleOverlay.cues.isEmpty)
    }

    func testUpdatingSubtitleAppearanceUpdatesControllerAndReloadsPlayingMedia() async throws {
        let suite = "PlayerCoordinatorSubtitleAppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let appearanceStore = SubtitleAppearanceStore(defaults: defaults)
        let api = PlayerFakeAPI(details: [
            detail(url: "https://media.example/first", path: "/video.mp4"),
            detail(url: "https://media.example/reloaded", path: "/video.mp4")
        ])
        let player = PlayerFakeController()
        let coordinator = PlayerCoordinator(
            api: api,
            controller: player,
            progressStore: PlaybackProgressStore(defaults: defaults),
            subtitleAppearanceStore: appearanceStore,
            baseURL: URL(string: "https://alist.example")!,
            username: "alice"
        )

        await coordinator.play(object: object("/video.mp4"))
        coordinator.updateSubtitleAppearance(SubtitleAppearance(font: .serif, color: .yellow, opacity: .high))
        try await waitUntil { player.replacedURLs.count == 2 }

        XCTAssertEqual(player.subtitleAppearance, SubtitleAppearance(font: .serif, color: .yellow, opacity: .high))
        XCTAssertEqual(appearanceStore.load(), player.subtitleAppearance)
        XCTAssertEqual(player.replacedURLs.last?.absoluteString, "https://media.example/reloaded")
    }

    private func makeCoordinator(
        api: PlayerFakeAPI,
        player: PlayerFakeController,
        store: PlaybackProgressStore? = nil,
        subtitleDataLoader: @escaping @Sendable (URL) async throws -> Data = { url in try nativeSubtitleData(for: url) },
        resumeCountdownInterval: Duration = .seconds(1)
    ) -> PlayerCoordinator {
        let progressStore: PlaybackProgressStore
        if let store {
            progressStore = store
        } else {
            let suite = "PlayerCoordinatorTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            progressStore = PlaybackProgressStore(defaults: defaults)
        }
        return PlayerCoordinator(
            api: api,
            controller: player,
            progressStore: progressStore,
            subtitleAppearanceStore: SubtitleAppearanceStore(defaults: progressStoreDefaults()),
            baseURL: URL(string: "https://alist.example")!,
            username: "alice",
            subtitleDataLoader: subtitleDataLoader,
            resumeCountdownInterval: resumeCountdownInterval
        )
    }

    private func progressStoreDefaults() -> UserDefaults {
        let suite = "PlayerCoordinatorSubtitleAppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func object(_ path: String) -> AListObject {
        AListObject(virtualPath: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: false)
    }

    private func detail(url: String, path: String) -> FileDetail {
        FileDetail(rawURL: url, virtualPath: path, name: "video.mp4", size: 100, isDirectory: false, modified: nil, created: nil, type: AListFileType.video.rawValue, thumbnail: nil)
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition() {
            if clock.now >= deadline {
                throw AListAPIError.transport(message: "Timed out waiting for player state")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor PlayerFakeAPI: AListAPI {
    private var details: [FileDetail]
    private var listPages: [[AListObject]]
    private var listByPath: [String: [[AListObject]]]
    private var listFailures: Int
    private let listDelayMilliseconds: Int
    private let log: LockedEventLog?
    private(set) var getPaths: [String] = []
    private var heldPaths: Set<String> = []
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var heldGetPaths: Set<String> = []
    private var heldGetContinuation: CheckedContinuation<Void, Never>?

    init(details: [FileDetail], listPages: [[AListObject]] = [], listByPath: [String: [[AListObject]]] = [:], listFailures: Int = 0, listDelayMilliseconds: Int = 0, log: LockedEventLog? = nil) {
        self.details = details
        self.listPages = listPages
        self.listByPath = listByPath
        self.listFailures = listFailures
        self.listDelayMilliseconds = listDelayMilliseconds
        self.log = log
    }

    func holdListForPath(_ path: String) { heldPaths.insert(path) }

    /// Polls until a held continuation has been registered (i.e. the old
    /// discovery actually entered `list()` and is suspended). Releases
    /// actor isolation between polls so the discovery task can execute.
    func waitForHeldList() async {
        while heldContinuation == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseHeldList() {
        heldContinuation?.resume()
        heldContinuation = nil
    }
    func holdGetForPath(_ path: String) { heldGetPaths.insert(path) }

    func waitForHeldGet() async {
        while heldGetContinuation == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseHeldGet() {
        heldGetContinuation?.resume()
        heldGetContinuation = nil
    }

    func login(username: String, password: String, otpCode: String?) async throws -> LoginData { throw AListAPIError.invalidResponse }
    func currentUser() async throws -> CurrentUser { throw AListAPIError.invalidResponse }
    func list(path: String, page: Int, perPage: Int) async throws -> DirectoryPage {
        if listFailures > 0 {
            listFailures -= 1
            throw AListAPIError.transport(message: "List unavailable")
        }
        // Per-path responses with optional hold
        if listByPath[path] != nil {
            if heldPaths.remove(path) != nil {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    heldContinuation = c
                }
            }
            guard var pages = listByPath[path], !pages.isEmpty else { throw AListAPIError.invalidResponse }
            let content = pages.removeFirst()
            listByPath[path] = pages
            return DirectoryPage(content: content, hasMore: !pages.isEmpty, page: page, perPage: perPage)
        }
        guard !listPages.isEmpty else { throw AListAPIError.invalidResponse }
        if listDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(listDelayMilliseconds))
        }
        let content = listPages.removeFirst()
        return DirectoryPage(content: content, hasMore: !listPages.isEmpty, page: page, perPage: perPage)
    }

    func get(path: String) async throws -> FileDetail {
        getPaths.append(path)
        log?.append("get:\(path)")
        guard !details.isEmpty else { throw AListAPIError.invalidResponse }
        let detail = details.removeFirst()
        if heldGetPaths.remove(path) != nil {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                heldGetContinuation = c
            }
        }
        return detail
    }
}

@MainActor
private final class PlayerFakeController: PlayerControlling {
    let events: AsyncStream<PlayerEvent>
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 120
    var isPlaying = false
    var isSeekable = true
    var isBuffering = false
    var bufferedTime: TimeInterval = 120
    var audioTracks: [PlaybackTrackOption] = []
    var embeddedSubtitleTracks: [PlaybackTrackOption] = []
    var selectedExternalSubtitleID: String?
    var subtitleAppearance = SubtitleAppearance.default
    var diagnostics: PlaybackDiagnosticsSnapshot?
    private(set) var replacedURLs: [URL] = []
    private(set) var preserveSelectionsValues: [Bool] = []
    private(set) var seekValues: [TimeInterval] = []
    private(set) var playCount = 0
    var shouldFailExternalSubtitleAdd = false
    private(set) var addedExternalSubtitleIDs: [String] = []
    private var loadedExternalSubtitleIDs = Set<String>()
    private var continuation: AsyncStream<PlayerEvent>.Continuation!
    private let log: LockedEventLog?

    init(log: LockedEventLog? = nil) {
        self.log = log
        var captured: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func replaceCurrentItem(url: URL, preservingSelections: Bool) {
        replacedURLs.append(url)
        preserveSelectionsValues.append(preservingSelections)
        log?.append("replace:\(url.absoluteString)")
    }
    func play() { playCount += 1; isPlaying = true }
    func pause() { isPlaying = false; continuation.yield(.paused) }
    func seek(to seconds: TimeInterval) async {
        seekValues.append(seconds)
        currentTime = seconds
    }
    func selectAudioTrack(id: String) {}
    func selectEmbeddedSubtitle(id: String?) {
        embeddedSubtitleTracks = embeddedSubtitleTracks.map {
            PlaybackTrackOption(id: $0.id, title: $0.title, languageCode: $0.languageCode, codec: $0.codec, isSelected: $0.id == id)
        }
    }
    func selectLoadedExternalSubtitle(id: String) -> Bool {
        guard loadedExternalSubtitleIDs.contains(id) else { return false }
        selectedExternalSubtitleID = id
        return true
    }
    func addExternalSubtitle(url: URL, id: String, title: String) -> Bool {
        guard !shouldFailExternalSubtitleAdd else { return false }
        addedExternalSubtitleIDs.append(id)
        loadedExternalSubtitleIDs.insert(id)
        return selectLoadedExternalSubtitle(id: id)
    }
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) { subtitleAppearance = appearance }
    func setDiagnosticsEnabled(_ enabled: Bool) {}
    func emit(_ event: PlayerEvent) { continuation.yield(event) }
}

private final class LockedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ value: String) {
        lock.lock(); storage.append(value); lock.unlock()
    }
}

private func nativeSubtitleData(for url: URL) throws -> Data {
    switch url.lastPathComponent {
    case "Movie.en.srt", "Movie.srt":
        return Data("""
        1
        00:00:40,000 --> 00:00:50,000
        Native SRT subtitle
        """.utf8)
    default:
        throw AListAPIError.invalidResponse
    }
}
