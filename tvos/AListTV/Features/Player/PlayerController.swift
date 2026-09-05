import Foundation

enum PlayerEvent: Equatable, Sendable {
    case failed(message: String)
    case paused
}

struct PlaybackTrackOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let languageCode: String?
    let codec: String?
    let isSelected: Bool
}

struct ExternalSubtitleOption: Identifiable, Equatable, Sendable {
    let id: String
    let virtualPath: String
    let title: String
}

enum SubtitleSelection: Equatable, Sendable {
    case off
    case embedded(trackID: String)
    case external(fileID: String)
}

struct PlaybackDiagnosticsSnapshot: Equatable, Sendable {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let isSeekable: Bool
    let inputBytesRead: Int64
    let inputBitrate: Double
    let demuxBytesRead: Int64
    let demuxBitrate: Double
    let demuxCorrupted: Int64
    let demuxDiscontinuity: Int64
    let decodedVideo: Int64
    let decodedAudio: Int64
    let displayedPictures: Int64
    let latePictures: Int64
    let lostPictures: Int64
    let playedAudioBuffers: Int64
    let lostAudioBuffers: Int64
    let videoResolution: String?
    let videoFrameRate: Double?
    let videoCodec: String?
    let audioTitle: String?
    let audioLanguageCode: String?
    let audioCodec: String?
    let subtitleTitle: String?
    let subtitleLanguageCode: String?
    let subtitleCodec: String?
}

enum PlaybackPresentation {
    static func clampedSeekTarget(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
    }

    static func clampedProgressFraction(_ value: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(value / duration, 0), 1)
    }

    static func trackTitle(name: String?, description: String?, language: String?, fallback: String) -> String {
        [name, description, language]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.contains("://") && !$0.contains("?") }) ?? fallback
    }

    static func frameRate(numerator: UInt32, denominator: UInt32) -> Double? {
        guard denominator != 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    static func diagnosticBitrate(_ bytesPerSecond: Double) -> String {
        String(format: "%.2f Mbit/s", bytesPerSecond * 8 / 1_000_000)
    }

    static func diagnosticMetadata(_ title: String?, _ language: String?, _ codec: String?) -> String {
        let values = [title, language, codec].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? "—" : values.joined(separator: " · ")
    }
}

@MainActor
protocol PlayerControlling: AnyObject {
    var events: AsyncStream<PlayerEvent> { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var isSeekable: Bool { get }
    var isBuffering: Bool { get }
    var bufferedTime: TimeInterval { get }
    var audioTracks: [PlaybackTrackOption] { get }
    var embeddedSubtitleTracks: [PlaybackTrackOption] { get }
    var selectedExternalSubtitleID: String? { get }
    var subtitleAppearance: SubtitleAppearance { get }
    var diagnostics: PlaybackDiagnosticsSnapshot? { get }

    func replaceCurrentItem(url: URL, preservingSelections: Bool)
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    func selectAudioTrack(id: String)
    func selectEmbeddedSubtitle(id: String?)
    func selectLoadedExternalSubtitle(id: String) -> Bool
    func addExternalSubtitle(url: URL, id: String, title: String) -> Bool
    func setSubtitleAppearance(_ appearance: SubtitleAppearance)
    func setDiagnosticsEnabled(_ enabled: Bool)
}

