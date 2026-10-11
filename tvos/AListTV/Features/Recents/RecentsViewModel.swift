import Combine
import Foundation

@MainActor
final class RecentsViewModel: ObservableObject {
    struct Entry: Equatable, Identifiable {
        let object: AListObject
        let openedAt: Date
        /// Saved resume point as a fraction of the duration, when one exists.
        let progress: Double?
        let remaining: TimeInterval?

        var id: String { object.virtualPath ?? object.name }
    }

    @Published private(set) var entries: [Entry] = []

    private let store: RecentItemsStore
    private let progressStore: PlaybackProgressStore
    private let account: RecentItemsAccount
    private let onOpen: @MainActor (AListObject) async -> Void

    init(
        store: RecentItemsStore,
        progressStore: PlaybackProgressStore,
        baseURL: URL,
        username: String,
        onOpen: @escaping @MainActor (AListObject) async -> Void = { _ in }
    ) {
        self.store = store
        self.progressStore = progressStore
        account = RecentItemsAccount(baseURL: baseURL.absoluteString, username: username)
        self.onOpen = onOpen
        reload()
    }

    /// Re-reads history and resume points, e.g. after the player saved progress.
    func reload() {
        publish(store.items(for: account))
    }

    func recordOpen(_ object: AListObject) {
        publish(store.recordOpen(object, account: account))
    }

    func open(_ entry: Entry) {
        let object = entry.object
        Task { await onOpen(object) }
    }

    func remove(_ entry: Entry) {
        guard let path = entry.object.virtualPath else { return }
        publish(store.remove(path: path, account: account))
    }

    func removeAll() {
        publish(store.removeAll(account: account))
    }

    private func publish(_ items: [RecentItem]) {
        let progress = Dictionary(
            progressStore.allRecords()
                .filter { $0.identity.baseURL == account.baseURL && $0.identity.username == account.username }
                .map { ($0.identity.virtualPath, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs }
        )
        let updated = items.prefix(RecentItemsStore.limit).map { item -> Entry in
            let record = item.object.virtualPath.flatMap { progress[$0] }
            let resumable = record.flatMap(Self.resumableFraction)
            return Entry(
                object: item.object,
                openedAt: item.openedAt,
                progress: resumable,
                remaining: resumable == nil ? nil : record.map { max(0, $0.duration - $0.position) }
            )
        }
        if updated != entries { entries = updated }
    }

    /// Mirrors the player's resume rules so the bar only shows when opening
    /// the file would actually offer to resume.
    private static func resumableFraction(_ record: PlaybackProgressRecord) -> Double? {
        guard record.position.isFinite, record.duration.isFinite, record.duration > 0,
              record.position >= 30, record.position < record.duration * 0.9 else { return nil }
        return record.position / record.duration
    }
}
