import Foundation

/// How much of each video in a folder to skip: the opening (OP) at the
/// start and the ending (ED) before the end. A season usually sits in one
/// folder and repeats the same OP/ED, so the setting belongs to the folder.
struct SkipSegments: Codable, Equatable, Sendable {
    /// Seconds skipped from the start of each video.
    var opening: TimeInterval
    /// Seconds before the end at which the next video starts instead.
    var ending: TimeInterval

    static let none = SkipSegments(opening: 0, ending: 0)
    static let limit: TimeInterval = 1_200

    var isEnabled: Bool { opening > 0 || ending > 0 }

    /// Whether a mark `seconds` from the start (opening) or from the end
    /// (ending) can be kept as is.
    static func canMark(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds <= limit
    }

    /// Whole seconds within 0...limit.
    static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(max(0, seconds.rounded()), limit)
    }

    /// Where the ending starts, when it is set and leaves something to watch.
    func endingStart(duration: TimeInterval) -> TimeInterval? {
        guard ending > 0, duration.isFinite, duration > 0 else { return nil }
        let start = duration - ending
        return start > opening ? start : nil
    }
}

struct SkipSegmentsIdentity: Codable, Hashable, Sendable {
    let baseURL: String
    let username: String
    let folderPath: String
}

struct SkipSegmentsStore {
    private struct Record: Codable {
        let identity: SkipSegmentsIdentity
        var segments: SkipSegments
        var updatedAt: Date
    }

    static let defaultsKey = "com.alist.tv.skip-segments-v1"
    static let recordLimit = 1_000
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    func segments(for identity: SkipSegmentsIdentity) -> SkipSegments {
        records().first { $0.identity == identity }?.segments ?? .none
    }

    /// Saving `.none` forgets the folder.
    func save(_ segments: SkipSegments, for identity: SkipSegmentsIdentity) {
        var all = records()
        all.removeAll { $0.identity == identity }
        if segments.isEnabled {
            all.insert(Record(identity: identity, segments: segments, updatedAt: now()), at: 0)
            if all.count > Self.recordLimit { all.removeSubrange(Self.recordLimit...) }
        }
        guard let data = try? PropertyListEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func records() -> [Record] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? PropertyListDecoder().decode([Record].self, from: data) else {
            return []
        }
        return decoded
    }
}
