#if DEBUG
import Combine
import Foundation

final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    func loadToken() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func saveToken(_ token: String) throws { lock.lock(); self.token = token; lock.unlock() }
    func deleteToken() throws { lock.lock(); token = nil; lock.unlock() }
}

actor FixtureAListAPI: AListAPI {
    func login(username: String, password: String, otpCode: String?) async throws -> LoginData {
        if username == "otp", otpCode != "123456" { throw AListAPIError.otpRequired }
        return LoginData(token: "fixture-token", deviceKey: "fixture-device")
    }
    func currentUser() async throws -> CurrentUser { CurrentUser(id: 1, username: "fixture") }
    func list(path: String, page: Int, perPage: Int) async throws -> DirectoryPage {
        let content: [AListObject]
        if path == "/" {
            content = [
                AListObject(virtualPath: "/Shows", name: "Shows", isDirectory: true, type: 1),
                AListObject(virtualPath: "/Sample.mp4", name: "Sample.mp4", size: 12_000_000, isDirectory: false, type: AListFileType.video.rawValue),
                AListObject(virtualPath: "/Sample.zh.srt", name: "Sample.zh.srt", size: 1_000, isDirectory: false),
                AListObject(virtualPath: "/Unrelated.ass", name: "Unrelated.ass", size: 1_000, isDirectory: false)
            ]
        } else {
            content = [AListObject(virtualPath: "\(path)/Episode.mp4", name: "Episode.mp4", size: 24_000_000, isDirectory: false, type: AListFileType.video.rawValue)]
        }
        return DirectoryPage(content: content, hasMore: false, page: page, perPage: perPage)
    }
    func get(path: String) async throws -> FileDetail {
        let rawURL: String
        let type: Int
        switch path {
        case "/Sample.zh.srt":
            rawURL = "https://media.example.test/Sample.zh.srt"
            type = 0
        case "/Unrelated.ass":
            rawURL = "https://media.example.test/Unrelated.ass"
            type = 0
        default:
            rawURL = "https://media.example.test/video.mp4"
            type = AListFileType.video.rawValue
        }
        return FileDetail(rawURL: rawURL, virtualPath: path, name: URL(fileURLWithPath: path).lastPathComponent, size: 12_000_000, isDirectory: false, modified: nil, created: nil, type: type, thumbnail: nil)
    }
}

enum FixtureSubtitleDataLoader {
    static func load(from url: URL) async throws -> Data {
        switch url.lastPathComponent {
        case "Sample.zh.srt":
            return Data("""
            1
            00:00:40,000 --> 00:00:50,000
            你好，世界
            """.utf8)
        case "Unrelated.ass":
            return Data("""
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:40.00,0:00:50.00,Default,,0,0,0,,Fixture ASS subtitle
            """.utf8)
        default:
            throw AListAPIError.invalidResponse
        }
    }
}

@MainActor
final class FixturePlayerController: ObservableObject, PlayerControlling {
    let events: AsyncStream<PlayerEvent>
    private var continuation: AsyncStream<PlayerEvent>.Continuation!
    @Published private(set) var currentTime: TimeInterval = 45
    @Published private(set) var duration: TimeInterval = 120
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeekable = true
    @Published private(set) var isBuffering = false
    @Published private(set) var bufferedTime: TimeInterval = 120
    @Published private(set) var audioTracks = [
        PlaybackTrackOption(id: "audio.en", title: "English", languageCode: "en", codec: "AAC", isSelected: true),
        PlaybackTrackOption(id: "audio.zh", title: "Chinese", languageCode: "zh", codec: "AAC", isSelected: false)
    ]
    @Published private(set) var embeddedSubtitleTracks = [PlaybackTrackOption(id: "subtitle.en", title: "English", languageCode: "en", codec: "WebVTT", isSelected: true)]
    @Published private(set) var selectedExternalSubtitleID: String?
    @Published private(set) var subtitleAppearance = SubtitleAppearance.default
    @Published private(set) var diagnostics: PlaybackDiagnosticsSnapshot?
    private var loadedExternalIDs = Set<String>()
    var shouldFailExternalSubtitleAdd = false

    init() { var captured: AsyncStream<PlayerEvent>.Continuation!; events = AsyncStream { captured = $0 }; continuation = captured }
    func replaceCurrentItem(url: URL, preservingSelections: Bool) { currentTime = 45; if !preservingSelections { selectedExternalSubtitleID = nil } }
    func play() { isPlaying = true }
    func pause() { isPlaying = false; continuation.yield(.paused) }
    func seek(to seconds: TimeInterval) async { currentTime = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds) }
    func selectAudioTrack(id: String) { audioTracks = audioTracks.map { PlaybackTrackOption(id: $0.id, title: $0.title, languageCode: $0.languageCode, codec: $0.codec, isSelected: $0.id == id) } }
    func selectEmbeddedSubtitle(id: String?) { selectedExternalSubtitleID = nil; embeddedSubtitleTracks = embeddedSubtitleTracks.map { PlaybackTrackOption(id: $0.id, title: $0.title, languageCode: $0.languageCode, codec: $0.codec, isSelected: $0.id == id) } }
    func selectLoadedExternalSubtitle(id: String) -> Bool { guard loadedExternalIDs.contains(id) else { return false }; selectedExternalSubtitleID = id; embeddedSubtitleTracks = embeddedSubtitleTracks.map { PlaybackTrackOption(id: $0.id, title: $0.title, languageCode: $0.languageCode, codec: $0.codec, isSelected: false) }; return true }
    func addExternalSubtitle(url: URL, id: String, title: String) -> Bool { if shouldFailExternalSubtitleAdd { return false }; loadedExternalIDs.insert(id); return selectLoadedExternalSubtitle(id: id) }
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) { subtitleAppearance = appearance }
    func setDiagnosticsEnabled(_ enabled: Bool) {
        diagnostics = enabled ? PlaybackDiagnosticsSnapshot(currentTime: currentTime, duration: duration, isPlaying: isPlaying, isSeekable: isSeekable, inputBytesRead: 1_024_000, inputBitrate: 125_000, demuxBytesRead: 1_000_000, demuxBitrate: 120_000, demuxCorrupted: 0, demuxDiscontinuity: 0, decodedVideo: 300, decodedAudio: 500, displayedPictures: 298, latePictures: 1, lostPictures: 1, playedAudioBuffers: 500, lostAudioBuffers: 0, videoResolution: "1920×1080", videoFrameRate: 24, videoCodec: "H.264", audioTitle: "English", audioLanguageCode: "en", audioCodec: "AAC", subtitleTitle: "English", subtitleLanguageCode: "en", subtitleCodec: "WebVTT") : nil
    }
    deinit { continuation.finish() }
}
#endif
