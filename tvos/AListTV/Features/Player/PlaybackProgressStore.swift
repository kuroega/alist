import Foundation

struct PlaybackProgressIdentity: Codable, Hashable, Sendable {
    let baseURL: String
    let username: String
    let virtualPath: String
}

struct PlaybackProgressRecord: Codable, Equatable, Sendable {
    let identity: PlaybackProgressIdentity
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date
}

/// A file played to the end (or marked as watched by hand).
struct WatchedRecord: Codable, Equatable, Sendable {
    let identity: PlaybackProgressIdentity
    var watchedAt: Date
}

struct PlaybackProgressStore {
    static let defaultsKey = "com.alist.tv.playback-progress-v1"
    static let watchedDefaultsKey = "com.alist.tv.watched-v1"
    static let watchedLimit = 5_000
    private let defaults: UserDefaults
    private let now: () -> Date
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    func record(for identity: PlaybackProgressIdentity) -> PlaybackProgressRecord? {
        records().first { $0.identity == identity }
    }

    func update(identity: PlaybackProgressIdentity, position: TimeInterval, duration: TimeInterval) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        var all = records()
        let ratio = max(0, position) / duration
        if ratio >= 0.9 {
            all.removeAll { $0.identity == identity }
            save(all)
            setWatched(true, identity: identity)
            return
        }
        guard position >= 30 else { return }

        let record = PlaybackProgressRecord(
            identity: identity,
            position: min(position, duration),
            duration: duration,
            updatedAt: now()
        )
        if let index = all.firstIndex(where: { $0.identity == identity }) {
            all[index] = record
        } else {
            all.append(record)
        }
        all.sort { $0.updatedAt > $1.updatedAt }
        if all.count > 500 {
            all.removeSubrange(500...)
        }
        save(all)
    }

    func remove(identity: PlaybackProgressIdentity) {
        var all = records()
        all.removeAll { $0.identity == identity }
        save(all)
    }

    func allRecords() -> [PlaybackProgressRecord] {
        records()
    }

    func watchedRecords() -> [WatchedRecord] {
        guard let data = defaults.data(forKey: Self.watchedDefaultsKey),
              let decoded = try? decoder.decode([WatchedRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Marking a file watched also drops its resume point, matching what
    /// finishing playback does; unmarking leaves any resume point alone.
    func setWatched(_ watched: Bool, identity: PlaybackProgressIdentity) {
        var all = watchedRecords()
        all.removeAll { $0.identity == identity }
        if watched {
            all.insert(WatchedRecord(identity: identity, watchedAt: now()), at: 0)
            if all.count > Self.watchedLimit { all.removeSubrange(Self.watchedLimit...) }
            remove(identity: identity)
        }
        guard let data = try? encoder.encode(all) else { return }
        defaults.set(data, forKey: Self.watchedDefaultsKey)
    }

    /// Carries a file's resume point and watched mark over to its new path
    /// after it was renamed on the server.
    func move(from old: PlaybackProgressIdentity, to new: PlaybackProgressIdentity) {
        guard old != new else { return }
        var all = records()
        if let index = all.firstIndex(where: { $0.identity == old }) {
            let record = all.remove(at: index)
            all.removeAll { $0.identity == new }
            all.append(PlaybackProgressRecord(identity: new, position: record.position, duration: record.duration, updatedAt: record.updatedAt))
            all.sort { $0.updatedAt > $1.updatedAt }
            save(all)
        }
        var watched = watchedRecords()
        if let index = watched.firstIndex(where: { $0.identity == old }) {
            let record = watched.remove(at: index)
            watched.removeAll { $0.identity == new }
            watched.insert(WatchedRecord(identity: new, watchedAt: record.watchedAt), at: min(index, watched.count))
            guard let data = try? encoder.encode(watched) else { return }
            defaults.set(data, forKey: Self.watchedDefaultsKey)
        }
    }

    private func records() -> [PlaybackProgressRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? decoder.decode([PlaybackProgressRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private func save(_ records: [PlaybackProgressRecord]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
