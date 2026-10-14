import AVFoundation
import AVKit
import Combine
import UIKit
import VideoToolbox

/// AVPlayer-backed controller for streams that need Apple's Dolby Vision
/// pipeline. Profile 5 video is only correct once its RPU metadata is applied,
/// which VLC does not do; AVPlayer applies it in hardware and switches the TV
/// into Dolby Vision (or tone-maps for HDR10/SDR displays).
@MainActor
final class NativePlayerControllerAdapter: NSObject, ObservableObject, PlayerControlling {
    /// Dolby Vision decoding rides on the HEVC hardware decoder.
    static var isSupported: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) }

    let videoView = PlayerLayerView()
    let events: AsyncStream<PlayerEvent>

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeekable = false
    @Published private(set) var isBuffering = false
    @Published private(set) var bufferedTime: TimeInterval = 0
    @Published private(set) var subtitleAppearance = SubtitleAppearance.default
    @Published private(set) var diagnostics: PlaybackDiagnosticsSnapshot?
    // The stream carries one audio track and no subtitles; SRT/ASS files are
    // drawn by the coordinator's overlay.
    let audioTracks: [PlaybackTrackOption] = []
    let embeddedSubtitleTracks: [PlaybackTrackOption] = []
    let selectedExternalSubtitleID: String? = nil

    private let player = AVPlayer()
    private var continuation: AsyncStream<PlayerEvent>.Continuation!
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var pendingSeekSeconds: TimeInterval?
    private var hasEmittedEnded = false
    private var diagnosticsEnabled = false

    override init() {
        var captured: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
        super.init()

        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        playerObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.timeControlStatusChanged() }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTiming() }
        }
    }

    func replaceCurrentItem(url: URL, preservingSelections: Bool) {
        stopObservingItem()
        currentTime = 0
        duration = 0
        isPlaying = false
        isSeekable = false
        isBuffering = true
        bufferedTime = 0
        pendingSeekSeconds = nil
        hasEmittedEnded = false
        diagnostics = nil
        videoView.displayCriteria = nil

        let item = AVPlayerItem(url: url)
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.itemStatusChanged() }
            }
        ]
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitEnded() }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        stopObservingItem()
        player.replaceCurrentItem(with: nil)
        videoView.displayCriteria = nil
        isPlaying = false
        isBuffering = false
    }

    func seek(to seconds: TimeInterval) async {
        let target = PlaybackPresentation.clampedSeekTarget(seconds, duration: duration)
        guard player.currentItem?.status == .readyToPlay else {
            pendingSeekSeconds = target
            currentTime = target
            return
        }
        hasEmittedEnded = false
        currentTime = target
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func selectAudioTrack(id: String) {}
    func selectEmbeddedSubtitle(id: String?) {}
    func selectLoadedExternalSubtitle(id: String) -> Bool { false }
    // Only overlay-rendered formats (SRT/ASS) are supported on this player.
    func addExternalSubtitle(url: URL, id: String, title: String) -> Bool { false }
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) { subtitleAppearance = appearance }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        diagnosticsEnabled = enabled
        diagnostics = enabled ? collectDiagnostics() : nil
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            refreshTiming()
            let asset = item.asset
            Task { [weak self] in
                let criteria = try? await asset.load(.preferredDisplayCriteria)
                guard let self, self.player.currentItem === item else { return }
                self.videoView.displayCriteria = criteria
            }
            if let target = pendingSeekSeconds {
                pendingSeekSeconds = nil
                Task { await seek(to: target) }
            }
        case .failed:
            isPlaying = false
            isBuffering = false
            continuation.yield(.failed(message: item.error?.localizedDescription ?? "视频播放失败，请检查文件或网络连接。"))
        default:
            break
        }
    }

    private func timeControlStatusChanged() {
        switch player.timeControlStatus {
        case .playing:
            isPlaying = true
            isBuffering = false
        case .waitingToPlayAtSpecifiedRate:
            isPlaying = true
            isBuffering = true
        case .paused:
            let wasPlaying = isPlaying
            isPlaying = false
            isBuffering = false
            // AVPlayer also pauses at the end of the item; that is .ended.
            if wasPlaying && !hasEmittedEnded { continuation.yield(.paused) }
        @unknown default:
            break
        }
    }

    private func emitEnded() {
        guard !hasEmittedEnded else { return }
        hasEmittedEnded = true
        refreshTiming()
        continuation.yield(.ended)
    }

    private func refreshTiming() {
        guard let item = player.currentItem else { return }
        let time = player.currentTime().seconds
        if time.isFinite { currentTime = max(0, time) }
        let length = item.duration.seconds
        if length.isFinite { duration = max(0, length) }
        isSeekable = item.status == .readyToPlay && !item.seekableTimeRanges.isEmpty
        let loadedEnd = item.loadedTimeRanges.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }.filter(\.isFinite).max()
        bufferedTime = loadedEnd ?? 0
        if diagnosticsEnabled { diagnostics = collectDiagnostics() }
    }

    private func collectDiagnostics() -> PlaybackDiagnosticsSnapshot {
        let item = player.currentItem
        let access = item?.accessLog()?.events.last
        let size = item?.presentationSize ?? .zero
        let frameRate = item?.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.currentVideoFrameRate
        return PlaybackDiagnosticsSnapshot(
            engine: .native, currentTime: currentTime, duration: duration, isPlaying: isPlaying, isSeekable: isSeekable,
            inputBytesRead: access?.numberOfBytesTransferred ?? 0,
            inputBitrate: max(0, (access?.observedBitrate ?? 0) / 8),
            demuxBytesRead: 0, demuxBitrate: max(0, (access?.indicatedBitrate ?? 0) / 8),
            demuxCorrupted: 0, demuxDiscontinuity: 0,
            decodedVideo: 0, decodedAudio: 0, displayedPictures: 0,
            latePictures: 0, lostPictures: Int64(max(0, access?.numberOfDroppedVideoFrames ?? 0)),
            playedAudioBuffers: 0, lostAudioBuffers: 0,
            videoResolution: size == .zero ? nil : "\(Int(size.width))×\(Int(size.height))",
            videoFrameRate: frameRate.map(Double.init).flatMap { $0 > 0 ? $0 : nil },
            videoCodec: "Dolby Vision",
            audioTitle: nil, audioLanguageCode: nil, audioCodec: "AAC",
            subtitleTitle: nil, subtitleLanguageCode: nil, subtitleCodec: nil
        )
    }

    private func stopObservingItem() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        continuation.finish()
    }
}

/// UIView whose backing layer renders the player, so it resizes with layout.
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// The stream's dynamic range and frame rate. With "Match Content" on,
    /// tvOS switches the display (e.g. into Dolby Vision) while this view is
    /// on screen, and restores the user's mode once it leaves.
    var displayCriteria: AVDisplayCriteria? {
        didSet { window?.avDisplayManager.preferredDisplayCriteria = displayCriteria }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        window?.avDisplayManager.preferredDisplayCriteria = nil
        newWindow?.avDisplayManager.preferredDisplayCriteria = displayCriteria
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
