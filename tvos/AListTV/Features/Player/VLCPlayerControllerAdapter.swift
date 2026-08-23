import Combine
import Foundation
import UIKit
import VLCKit

@MainActor
final class VLCPlayerControllerAdapter:
    NSObject,
    ObservableObject,
    PlayerControlling,
    VLCMediaPlayerDelegate
{
    let videoView = UIView()
    let events: AsyncStream<PlayerEvent>

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeekable = false

    private let mediaPlayer = VLCMediaPlayer()
    private var continuation: AsyncStream<PlayerEvent>.Continuation!
    private var pendingSeekSeconds: TimeInterval?
#if DEBUG
    private var nextStatisticsLogTime: TimeInterval = 0
#endif


    override init() {
        var captured: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
        super.init()

        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoView
        mediaPlayer.timeChangeUpdateInterval = 0.5
    }

    func replaceCurrentItem(url: URL) {
        mediaPlayer.stop()
        currentTime = 0
        duration = 0
        isPlaying = false
        isSeekable = false
        pendingSeekSeconds = nil
#if DEBUG
        nextStatisticsLogTime = 0
#endif

        guard let media = VLCMedia(url: url) else {
            continuation.yield(.failed(message: "无法创建播放媒体。"))
            return
        }

        media.addOption(":network-caching=3000")
        media.addOption(":http-reconnect")
        mediaPlayer.media = media
    }

    func play() {
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func seek(to seconds: TimeInterval) async {
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)

        guard mediaPlayer.isSeekable else {
            pendingSeekSeconds = target
            return
        }

        mediaPlayer.time = VLCTime(int: Int32((target * 1_000).rounded()))
        currentTime = target
    }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.handleStateChange(newState)
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshTiming()
        }
    }

    private func handleStateChange(_ state: VLCMediaPlayerState) {
        switch state {
        case .playing:
            isPlaying = true
            isSeekable = mediaPlayer.isSeekable
            applyPendingSeekIfPossible()
        case .paused:
            isPlaying = false
            continuation.yield(.paused)
        case .stopped, .stopping, .nothingSpecial:
            isPlaying = false
        case .opening:
            break
        case .error:
            isPlaying = false
            let message = VLCLibrary.currentErrorMessage?.isEmpty == false
                ? VLCLibrary.currentErrorMessage!
                : "视频播放失败，请检查文件或网络连接。"
            continuation.yield(.failed(message: message))
        @unknown default:
            isPlaying = false
        }
    }

    private func refreshTiming() {
        let milliseconds = mediaPlayer.time.intValue
        let lengthMilliseconds = mediaPlayer.media?.length.intValue ?? 0
        currentTime = max(0, TimeInterval(milliseconds) / 1_000)
        duration = max(0, TimeInterval(lengthMilliseconds) / 1_000)
        isSeekable = mediaPlayer.isSeekable
        if isSeekable {
            applyPendingSeekIfPossible()
        }
#if DEBUG
        logPlaybackStatisticsIfDue()
#endif
    }


#if DEBUG
    private func logPlaybackStatisticsIfDue() {
        guard isPlaying, let media = mediaPlayer.media else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextStatisticsLogTime else { return }
        nextStatisticsLogTime = now + 5

        let statistics = media.statistics
        print(
            "VLCKitStats inputBitrate=\(statistics.inputBitrate) " +
            "demuxBitrate=\(statistics.demuxBitrate) " +
            "decodedVideo=\(statistics.decodedVideo) " +
            "displayedPictures=\(statistics.displayedPictures) " +
            "latePictures=\(statistics.latePictures) " +
            "lostPictures=\(statistics.lostPictures) " +
            "lostAudioBuffers=\(statistics.lostAudioBuffers)"
        )
    }
#endif

    private func applyPendingSeekIfPossible() {
        guard let pendingSeekSeconds, mediaPlayer.isSeekable else { return }
        self.pendingSeekSeconds = nil
        let target = duration > 0 ? min(pendingSeekSeconds, duration) : pendingSeekSeconds
        mediaPlayer.time = VLCTime(int: Int32((target * 1_000).rounded()))
        currentTime = target
    }

    deinit {
        mediaPlayer.stop()
        continuation.finish()
    }
}
