import Combine
import Foundation

enum BrowserSortCriterion: String, CaseIterable, Hashable {
    case name
    case modified
    case size

    var title: String {
        switch self {
        case .name:
            return "Name"
        case .modified:
            return "Modified date"
        case .size:
            return "Size"
        }
    }
}

@MainActor
final class BrowserViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case loadingMore
        case failed(message: String)
        case forbidden
        case loadMoreFailed(message: String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var path = "/"
    @Published private(set) var items: [AListObject] = []
    @Published var focusedVirtualPath: String?
    @Published private(set) var sortCriterion: BrowserSortCriterion = .name
    @Published private(set) var isSortAscending = true
    @Published private(set) var hasMore = false
    @Published private(set) var isRefreshing = false
    /// Set when a refresh fails while the previous listing stays on screen.
    @Published var refreshError: String?


    private struct PageKey: Hashable {
        let path: String
        let page: Int
    }

    private let api: any AListAPI
    private let perPage: Int
    private let onPlay: @MainActor (AListObject) async -> Void
    private let onUnauthorized: @MainActor () async -> Void
    private var directoryItems: [AListObject] = []
    private var fileItems: [AListObject] = []
    private var seenPaths: Set<String> = []
    private var requestedPages: Set<PageKey> = []
    private var inFlight: Set<PageKey> = []
    private var nextPage = 1
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var focusHistory: [String: String] = [:]
    private var pendingRestoredFocus: String?
    private var failedNextPage: Int?

    init(
        api: any AListAPI,
        perPage: Int = 200,
        onPlay: @escaping @MainActor (AListObject) async -> Void = { _ in },
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) {
        self.api = api
        self.perPage = perPage
        self.onPlay = onPlay
        self.onUnauthorized = onUnauthorized
    }

    deinit {
        loadTask?.cancel()
    }


    func loadInitial() {
        beginLoading(path: path, restoredFocus: pendingRestoredFocus)
    }

    func loadNextPageIfNeeded(currentItem: AListObject) {
        guard hasMore, !isRefreshing, !items.isEmpty,
              let currentPath = currentItem.virtualPath,
              let index = items.firstIndex(where: { $0.virtualPath == currentPath }) else {
            return
        }
        let threshold = max(0, items.count - min(8, items.count))
        guard index >= threshold else { return }
        requestPage(nextPage, initial: false, generation: generation, requestedPath: path)
    }

    func open(_ object: AListObject) {
        guard object.isDirectory else {
            Task { await onPlay(object) }
            return
        }
        do {
            let childPath = try AListPath.join(parent: path, name: object.name)
            if let focusedPath = object.virtualPath {
                focusHistory[path] = focusedPath
            }
            path = childPath
            pendingRestoredFocus = nil
            beginLoading(path: childPath, restoredFocus: nil)
        } catch {
            state = .failed(message: "This folder has an invalid name.")
        }
    }

    /// Opens the folder containing `object` and focuses it there.
    func reveal(_ object: AListObject) {
        guard let rawPath = object.virtualPath, !rawPath.isEmpty else { return }
        let filePath = AListPath.normalize(rawPath)
        let parent = AListPath.parent(of: filePath)
        path = parent
        beginLoading(path: parent, restoredFocus: filePath)
    }

    func moveToParent() {
        guard path != "/" else { return }
        let parent = AListPath.parent(of: path)
        path = parent
        let restored = focusHistory[parent]
        pendingRestoredFocus = restored
        beginLoading(path: parent, restoredFocus: restored)
    }
    func retry() {
        guard !isRefreshing else { return }
        if let page = failedNextPage, !items.isEmpty {
            requestPage(page, initial: false, generation: generation, requestedPath: path)
        } else {
            beginLoading(path: path, restoredFocus: pendingRestoredFocus)
        }
    }

    /// Re-reads the current folder with `refresh: true`, keeping the current
    /// listing visible until the fresh first page arrives.
    func refresh() {
        guard !isRefreshing, state != .loading else { return }
        loadTask?.cancel()
        generation = UUID()
        let currentGeneration = generation
        let requestedPath = path
        let restoredFocus = focusedVirtualPath
        inFlight.removeAll()
        isRefreshing = true
        refreshError = nil
        // Any in-flight or failed "load more" belongs to the stale listing.
        if state == .loadingMore || isLoadMoreFailure { state = .loaded }
        loadTask = Task { [weak self] in
            await self?.performRefresh(generation: currentGeneration, requestedPath: requestedPath, restoredFocus: restoredFocus)
        }
    }

    func setSort(criterion: BrowserSortCriterion, ascending: Bool) {
        guard sortCriterion != criterion || isSortAscending != ascending else { return }
        sortCriterion = criterion
        isSortAscending = ascending
        updateItems()
    }

    private var isLoadMoreFailure: Bool {
        if case .loadMoreFailed = state { return true }
        return false
    }

    private func beginLoading(path requestedPath: String, restoredFocus: String?) {
        loadTask?.cancel()
        generation = UUID()
        let currentGeneration = generation
        inFlight.removeAll()
        resetListing()
        pendingRestoredFocus = restoredFocus
        focusedVirtualPath = nil
        isRefreshing = false
        refreshError = nil
        state = .loading
        loadTask = Task { [weak self] in
            await self?.fetchPage(1, initial: true, generation: currentGeneration, requestedPath: requestedPath, restoredFocus: restoredFocus)
        }
    }

    private func resetListing() {
        requestedPages.removeAll()
        directoryItems.removeAll(keepingCapacity: true)
        fileItems.removeAll(keepingCapacity: true)
        seenPaths.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        hasMore = false
        nextPage = 1
        failedNextPage = nil
    }

    private func performRefresh(generation requestGeneration: UUID, requestedPath: String, restoredFocus: String?) async {
        do {
            let page = try await api.list(path: requestedPath, page: 1, perPage: perPage, refresh: true)
            guard !Task.isCancelled, generation == requestGeneration, path == requestedPath else { return }
            isRefreshing = false
            resetListing()
            requestedPages.insert(PageKey(path: requestedPath, page: 1))
            appendPage(page.content, parentPath: requestedPath)
            hasMore = page.hasMore ?? (page.content.count == perPage)
            nextPage = 2
            state = items.isEmpty && !hasMore ? .empty : .loaded
            if let restoredFocus, items.contains(where: { $0.virtualPath == restoredFocus }) {
                focusedVirtualPath = restoredFocus
            }
        } catch AListAPIError.unauthorized {
            guard generation == requestGeneration, path == requestedPath else { return }
            isRefreshing = false
            await onUnauthorized()
        } catch {
            guard !Task.isCancelled, generation == requestGeneration, path == requestedPath else { return }
            isRefreshing = false
            if case let AListAPIError.server(code, _) = error, code == 403 {
                refreshError = "Refreshing requires write permission for this folder."
            } else {
                refreshError = Self.message(for: error)
            }
        }
    }

    private func requestPage(_ page: Int, initial: Bool, generation: UUID, requestedPath: String) {
        let key = PageKey(path: requestedPath, page: page)
        guard !requestedPages.contains(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        if !initial { state = .loadingMore }
        loadTask = Task { [weak self] in
            await self?.fetchPage(page, initial: initial, generation: generation, requestedPath: requestedPath, restoredFocus: nil)
        }
    }

    private func fetchPage(
        _ pageNumber: Int,
        initial: Bool,
        generation requestGeneration: UUID,
        requestedPath: String,
        restoredFocus: String?
    ) async {
        let key = PageKey(path: requestedPath, page: pageNumber)
        if !inFlight.contains(key) { inFlight.insert(key) }
        defer { inFlight.remove(key) }

        do {
            let page = try await api.list(path: requestedPath, page: pageNumber, perPage: perPage)
            guard !Task.isCancelled, generation == requestGeneration, path == requestedPath else { return }
            requestedPages.insert(key)
            appendPage(page.content, parentPath: requestedPath)
            hasMore = page.hasMore ?? (page.content.count == perPage)
            nextPage = pageNumber + 1
            failedNextPage = nil
            state = items.isEmpty && !hasMore ? .empty : .loaded
            let targetFocus = restoredFocus ?? pendingRestoredFocus
            if let targetFocus, items.contains(where: { $0.virtualPath == targetFocus }) {
                focusedVirtualPath = targetFocus
                pendingRestoredFocus = nil
            } else if targetFocus != nil, hasMore {
                requestPage(nextPage, initial: false, generation: requestGeneration, requestedPath: requestedPath)
            } else if !hasMore {
                pendingRestoredFocus = nil
            }
        } catch AListAPIError.unauthorized {
            guard generation == requestGeneration, path == requestedPath else { return }
            await onUnauthorized()
        } catch let AListAPIError.server(code, _) where code == 403 {
            guard generation == requestGeneration, path == requestedPath else { return }
            failedNextPage = initial ? nil : pageNumber
            state = .forbidden
        } catch {
            guard !Task.isCancelled, generation == requestGeneration, path == requestedPath else { return }
            failedNextPage = initial ? nil : pageNumber
            state = initial
                ? .failed(message: Self.message(for: error))
                : .loadMoreFailed(message: Self.message(for: error))
        }
    }

    private func appendPage(_ page: [AListObject], parentPath: String) {
        for object in page {
            let virtualPath: String
            if let provided = object.virtualPath, !provided.isEmpty {
                virtualPath = AListPath.normalize(provided)
            } else if let derived = try? AListPath.join(parent: parentPath, name: object.name) {
                virtualPath = derived
            } else {
                continue
            }
            guard seenPaths.insert(virtualPath).inserted else { continue }
            let normalized = object.withVirtualPath(virtualPath)
            if normalized.isDirectory {
                directoryItems.append(normalized)
            } else {
                fileItems.append(normalized)
            }
        }
        updateItems()
    }

    private func updateItems() {
        items = sorted(directoryItems) + sorted(fileItems)
    }

    private func sorted(_ objects: [AListObject]) -> [AListObject] {
        objects.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sortCriterion {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .modified:
                result = (lhs.modified ?? "").compare(rhs.modified ?? "")
            case .size:
                result = lhs.size == rhs.size
                    ? lhs.name.localizedStandardCompare(rhs.name)
                    : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            }
            return isSortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
