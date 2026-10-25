import Foundation

/// Server and user a recent item belongs to, so one account never sees
/// another account's history.
struct RecentItemsAccount: Codable, Hashable, Sendable {
    let baseURL: String
    let username: String
}

struct RecentItem: Codable, Equatable, Identifiable, Sendable {
    let account: RecentItemsAccount
    let object: AListObject
    var openedAt: Date

    /// Recorded objects always carry a normalized virtual path.
    var id: String { object.virtualPath ?? object.name }
}

/// Remembers the files each account opened most recently, newest first.
struct RecentItemsStore {
    static let defaultsKey = "com.alist.tv.recent-items-v1"
    static let limit = 15
    private let defaults: UserDefaults
    private let now: () -> Date
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    func items(for account: RecentItemsAccount) -> [RecentItem] {
        records()
            .filter { $0.account == account }
            .sorted { $0.openedAt > $1.openedAt }
    }

    /// Moves `object` to the front of the account's history. Folders and
    /// objects without a path are ignored because they cannot be reopened.
    @discardableResult
    func recordOpen(_ object: AListObject, account: RecentItemsAccount) -> [RecentItem] {
        guard !object.isDirectory, let rawPath = object.virtualPath, !rawPath.isEmpty else {
            return items(for: account)
        }
        let path = AListPath.normalize(rawPath)
        var all = records()
        all.removeAll { $0.account == account && $0.object.virtualPath == path }
        // The file just opened must lead even if the clock stalled or moved back.
        let latest = all.filter { $0.account == account }.map(\.openedAt).max()
        let openedAt = latest.map { max(now(), $0.addingTimeInterval(0.001)) } ?? now()
        all.append(RecentItem(account: account, object: object.withVirtualPath(path), openedAt: openedAt))
        return save(trimmed(all), returning: account)
    }

    @discardableResult
    func remove(path: String, account: RecentItemsAccount) -> [RecentItem] {
        var all = records()
        all.removeAll { $0.account == account && $0.object.virtualPath == path }
        return save(all, returning: account)
    }

    /// Points a recent item at its file's new path and name after a rename.
    @discardableResult
    func move(path: String, to newPath: String, name: String, account: RecentItemsAccount) -> [RecentItem] {
        let all = records().map { item -> RecentItem in
            guard item.account == account, item.object.virtualPath == path else { return item }
            let object = item.object
            let renamed = AListObject(
                virtualPath: newPath, name: name, size: object.size, isDirectory: object.isDirectory,
                modified: object.modified, created: object.created, type: object.type, thumbnail: object.thumbnail
            )
            return RecentItem(account: account, object: renamed, openedAt: item.openedAt)
        }
        return save(all, returning: account)
    }

    @discardableResult
    func removeAll(account: RecentItemsAccount) -> [RecentItem] {
        var all = records()
        all.removeAll { $0.account == account }
        return save(all, returning: account)
    }

    /// Keeps only the newest `limit` entries per account.
    private func trimmed(_ all: [RecentItem]) -> [RecentItem] {
        var counts: [RecentItemsAccount: Int] = [:]
        return all
            .sorted { $0.openedAt > $1.openedAt }
            .filter { item in
                counts[item.account, default: 0] += 1
                return counts[item.account, default: 0] <= Self.limit
            }
    }

    private func records() -> [RecentItem] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? decoder.decode([RecentItem].self, from: data) else {
            return []
        }
        return decoded
    }

    private func save(_ all: [RecentItem], returning account: RecentItemsAccount) -> [RecentItem] {
        if let data = try? encoder.encode(all) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        return all
            .filter { $0.account == account }
            .sorted { $0.openedAt > $1.openedAt }
    }
}
