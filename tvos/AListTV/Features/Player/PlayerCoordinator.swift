import Combine
import Foundation

enum PlayableURLValidator {
    static func validate(_ rawValue: String) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              let host = components.host, !host.isEmpty,
              ServerURLValidator.isAllowedConnection(scheme: components.scheme, host: host),
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw AListAPIError.invalidRawURL
        }
        return url
    }
}

@MainActor
final class PlayerCoordinator: ObservableObject {
    enum State: Equatable { case idle, loading, playing, failed(message: String) }
    enum ExternalSubtitleDiscoveryState: Equatable { case idle, loading, loaded, failed(message: String) }

    @Published private(set) var state: State = .idle
    @Published var isPresented = false
    @Published private(set) var externalSubtitles: [ExternalSubtitleOption] = []
    @Published private(set) var externalSubtitleDiscoveryState: ExternalSubtitleDiscoveryState = .idle
    @Published var subtitleSelectionError: String?
    @Published private(set) var subtitleSelection: SubtitleSelection = .off

    let controller: any PlayerControlling
    private let api: any AListAPI
    private let progressStore: PlaybackProgressStore
    private let baseURL: URL
    private let username: String
    private let onUnauthorized: @MainActor () async -> Void
    private var currentObject: AListObject?
    private var sessionID = UUID()
    private var refreshCount = 0
    private var eventTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var subtitleSelectionTask: Task<Void, Never>?

    init(api: any AListAPI, controller: any PlayerControlling, progressStore: PlaybackProgressStore, baseURL: URL, username: String, onUnauthorized: @escaping @MainActor () async -> Void = {}) {
        self.api = api
        self.controller = controller
        self.progressStore = progressStore
        self.baseURL = baseURL
        self.username = username
        self.onUnauthorized = onUnauthorized
    }

    deinit {
        eventTask?.cancel()
        progressTask?.cancel()
        discoveryTask?.cancel()
        subtitleSelectionTask?.cancel()
    }

    func play(object: AListObject) async {
        guard !object.isDirectory, let path = object.virtualPath, !path.isEmpty else {
            state = .failed(message: "Folders cannot be played.")
            return
        }
        finishMonitoring(saveProgress: true)
        discoveryTask?.cancel()
        subtitleSelectionTask?.cancel()
        currentObject = object
        sessionID = UUID()
        let activeSession = sessionID
        refreshCount = 0
        externalSubtitles = []
        externalSubtitleDiscoveryState = .idle
        subtitleSelectionError = nil
        subtitleSelection = .off
        state = .loading

        do {
            let detail = try await api.get(path: path)
            guard sessionID == activeSession else { return }
            let url = try PlayableURLValidator.validate(detail.rawURL)
            controller.replaceCurrentItem(url: url, preservingSelections: false)
            guard sessionID == activeSession else { return }
            controller.play()
            state = .playing
            isPresented = true
            startMonitoring(session: activeSession)
            discoverExternalSubtitles(session: activeSession, videoPath: path)
        } catch AListAPIError.unauthorized {
            await onUnauthorized()
        } catch {
            isPresented = true
            state = .failed(message: Self.message(for: error))
        }
    }

    func playerDidDisappear() {
        sessionID = UUID()
        finishMonitoring(saveProgress: true)
        discoveryTask?.cancel()
        discoveryTask = nil
        subtitleSelectionTask?.cancel()
        subtitleSelectionTask = nil
        controller.setDiagnosticsEnabled(false)
        controller.pause()
        isPresented = false
        state = .idle
        currentObject = nil
        externalSubtitles = []
        externalSubtitleDiscoveryState = .idle
        subtitleSelectionError = nil
        subtitleSelection = .off
    }

    func retryExternalSubtitleDiscovery() {
        guard let path = currentObject?.virtualPath else { return }
        discoverExternalSubtitles(session: sessionID, videoPath: path)
    }

    func selectSubtitle(_ selection: SubtitleSelection) async {
        subtitleSelectionTask?.cancel()
        subtitleSelectionError = nil
        let activeSession = sessionID
        switch selection {
        case .off:
            controller.selectEmbeddedSubtitle(id: nil)
            subtitleSelection = .off
        case let .embedded(trackID):
            controller.selectEmbeddedSubtitle(id: trackID)
            subtitleSelection = controller.embeddedSubtitleTracks.first(where: { $0.id == trackID && $0.isSelected }) == nil ? subtitleSelection : selection
        case let .external(fileID):
            guard let option = externalSubtitles.first(where: { $0.id == fileID }) else { return }
            if controller.selectLoadedExternalSubtitle(id: fileID) {
                subtitleSelection = selection
                return
            }
            subtitleSelectionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let detail = try await self.api.get(path: option.virtualPath)
                    guard !Task.isCancelled, self.sessionID == activeSession else { return }
                    let url = try PlayableURLValidator.validate(detail.rawURL)
                    guard self.controller.addExternalSubtitle(url: url, id: option.id, title: option.title) else {
                        self.publishSubtitleError(for: option)
                        return
                    }
                    self.subtitleSelection = selection
                } catch AListAPIError.unauthorized {
                    guard !Task.isCancelled, self.sessionID == activeSession else { return }
                    await self.onUnauthorized()
                } catch {
                    guard !Task.isCancelled, self.sessionID == activeSession else { return }
                    self.publishSubtitleError(for: option)
                }
            }
            await subtitleSelectionTask?.value
        }
    }

    func saveProgress() {
        guard let identity = progressIdentity else { return }
        progressStore.update(identity: identity, position: controller.currentTime, duration: controller.duration)
    }

    private func discoverExternalSubtitles(session: UUID, videoPath: String) {
        discoveryTask?.cancel()
        externalSubtitles = []
        externalSubtitleDiscoveryState = .loading
        let parent = AListPath.parent(of: videoPath)
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            var pageNumber = 1
            var unique: [String: ExternalSubtitleOption] = [:]
            do {
                while !Task.isCancelled {
                    let page = try await self.api.list(path: parent, page: pageNumber, perPage: 200)
                    guard !Task.isCancelled, self.sessionID == session else { return }
                    for object in page.content where !object.isDirectory {
                        guard let virtualPath = self.normalizedPath(for: object, parent: parent), virtualPath != AListPath.normalize(videoPath), Self.isSupportedSubtitle(path: virtualPath) else { continue }
                        unique[virtualPath] = ExternalSubtitleOption(id: virtualPath, virtualPath: virtualPath, title: URL(fileURLWithPath: virtualPath).lastPathComponent)
                    }
                    let hasMore = page.hasMore ?? (page.content.count == 200)
                    guard hasMore else { break }
                    pageNumber += 1
                }
                guard !Task.isCancelled, self.sessionID == session else { return }
                self.externalSubtitles = Self.filteredAndSortedSubtitles(Array(unique.values), videoPath: videoPath)
                self.externalSubtitleDiscoveryState = .loaded
            } catch AListAPIError.unauthorized {
                guard !Task.isCancelled, self.sessionID == session else { return }
                await self.onUnauthorized()
            } catch {
                guard !Task.isCancelled, self.sessionID == session else { return }
                self.externalSubtitleDiscoveryState = .failed(message: "Unable to load external subtitles.")
            }
        }
    }

    private func normalizedPath(for object: AListObject, parent: String) -> String? {
        if let path = object.virtualPath, !path.isEmpty { return AListPath.normalize(path) }
        return try? AListPath.join(parent: parent, name: object.name)
    }

    private func startMonitoring(session: UUID) {
        if eventTask == nil {
            let events = controller.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self else { return }
                    guard self.currentObject != nil else { continue }
                    switch event {
                    case let .failed(message): await self.handleFailure(message, session: self.sessionID)
                    case .paused: self.saveProgress()
                    }
                }
            }
        }
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                self.saveProgress()
            }
        }
    }

    private func handleFailure(_ message: String, session: UUID) async {
        guard sessionID == session, let path = currentObject?.virtualPath else { return }
        guard refreshCount == 0 else {
            controller.pause()
            state = .failed(message: message)
            return
        }
        refreshCount = 1
        let position = controller.currentTime
        let selectionToRestore = subtitleSelection
        do {
            let detail = try await api.get(path: path)
            guard sessionID == session else { return }
            let url = try PlayableURLValidator.validate(detail.rawURL)
            controller.replaceCurrentItem(url: url, preservingSelections: true)
            if position > 0 { await controller.seek(to: position) }
            guard sessionID == session else { return }
            controller.play()
            state = .playing
            if case let .external(fileID) = selectionToRestore {
                await selectSubtitle(.external(fileID: fileID))
                if subtitleSelectionError != nil {
                    subtitleSelection = .off
                }
            }
        } catch AListAPIError.unauthorized {
            await onUnauthorized()
        } catch {
            controller.pause()
            state = .failed(message: Self.message(for: error))
        }
    }

    private func publishSubtitleError(for option: ExternalSubtitleOption) {
        subtitleSelectionError = "Unable to load subtitle “\(option.title)”."
    }

    private func finishMonitoring(saveProgress shouldSave: Bool) {
        if shouldSave { saveProgress() }
        progressTask?.cancel()
        progressTask = nil
    }

    private var progressIdentity: PlaybackProgressIdentity? {
        guard let path = currentObject?.virtualPath else { return nil }
        return PlaybackProgressIdentity(baseURL: baseURL.absoluteString, username: username, virtualPath: path)
    }

    private static let supportedSubtitleExtensions: Set<String> = ["cdg", "idx", "srt", "sub", "utf", "ass", "ssa", "aqt", "jss", "psb", "rt", "smi"]

    private static func isSupportedSubtitle(path: String) -> Bool {
        supportedSubtitleExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func filteredAndSortedSubtitles(_ options: [ExternalSubtitleOption], videoPath: String) -> [ExternalSubtitleOption] {
        let stemsWithIDX = Set(options.filter { $0.title.lowercased().hasSuffix(".idx") }.map { URL(fileURLWithPath: $0.title).deletingPathExtension().lastPathComponent.lowercased() })
        let filtered = options.filter {
            let fileURL = URL(fileURLWithPath: $0.title)
            return fileURL.pathExtension.lowercased() != "sub" || !stemsWithIDX.contains(fileURL.deletingPathExtension().lastPathComponent.lowercased())
        }
        let videoBase = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent.lowercased()
        return filtered.sorted {
            let lhs = $0.title.lowercased()
            let rhs = $1.title.lowercased()
            let lhsMatches = lhs == videoBase || lhs.hasPrefix(videoBase + ".")
            let rhsMatches = rhs == videoBase || rhs.hasPrefix(videoBase + ".")
            if lhsMatches != rhsMatches { return lhsMatches }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
