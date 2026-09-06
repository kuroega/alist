import Combine
import Foundation
import UIKit
import VLCKit

@MainActor
final class VLCPlayerControllerAdapter: NSObject, ObservableObject, PlayerControlling, VLCMediaPlayerDelegate {
    let videoView = UIView()
    let events: AsyncStream<PlayerEvent>

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeekable = false
    @Published private(set) var isBuffering = false
    @Published private(set) var bufferedTime: TimeInterval = 0
    @Published private(set) var audioTracks: [PlaybackTrackOption] = []
    @Published private(set) var embeddedSubtitleTracks: [PlaybackTrackOption] = []
    @Published private(set) var selectedExternalSubtitleID: String?
    @Published private(set) var subtitleAppearance = SubtitleAppearance.default
    @Published private(set) var diagnostics: PlaybackDiagnosticsSnapshot?

    private let mediaPlayer = VLCMediaPlayer()
    private var continuation: AsyncStream<PlayerEvent>.Continuation!
    private var pendingSeekSeconds: TimeInterval?
    private var pendingExternalSubtitle: ExternalSubtitleOption?
    private var externalTrackIDs: [String: String] = [:]
    private var externalSubtitleTitles: [String: String] = [:]
    private var preferredAudioTrackID: String?
    private var preferredEmbeddedSubtitleTrackID: String?
    private var diagnosticsEnabled = false
    private var nextDiagnosticsUpdateTime: TimeInterval = 0
    private var hasStartedPlayback = false
    private var hasReachedEnd = false
    private var hasEmittedEnded = false
    private var lastObservedTime: TimeInterval = 0
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

    func replaceCurrentItem(url: URL, preservingSelections: Bool) {
        mediaPlayer.stop()
        currentTime = 0
        duration = 0
        isPlaying = false
        isSeekable = false
        isBuffering = false
        bufferedTime = 0
        hasStartedPlayback = false
        hasReachedEnd = false
        hasEmittedEnded = false
        lastObservedTime = 0
        pendingSeekSeconds = nil
        pendingExternalSubtitle = nil
        externalTrackIDs = [:]
        selectedExternalSubtitleID = nil
        audioTracks = []
        embeddedSubtitleTracks = []
        diagnostics = nil
        externalSubtitleTitles = [:]
        nextDiagnosticsUpdateTime = 0
        if !preservingSelections {
            preferredAudioTrackID = nil
            preferredEmbeddedSubtitleTrackID = nil
        }
#if DEBUG
        nextStatisticsLogTime = 0
#endif

        guard let media = VLCMedia(url: url) else {
            continuation.yield(.failed(message: "无法创建播放媒体。"))
            return
        }
        media.addOption(":network-caching=3000")
        media.addOption(":http-reconnect")
        subtitleAppearance.vlcMediaOptions.forEach(media.addOption)
        mediaPlayer.media = media
    }

    func play() { mediaPlayer.play() }

    func pause() { mediaPlayer.pause() }

    func seek(to seconds: TimeInterval) async {
        let target = PlaybackPresentation.clampedSeekTarget(seconds, duration: duration)
        guard mediaPlayer.isSeekable else {
            pendingSeekSeconds = target
            return
        }
        mediaPlayer.time = VLCTime(int: Int32((target * 1_000).rounded()))
        hasReachedEnd = false
        lastObservedTime = target
        currentTime = target
    }

    func selectAudioTrack(id: String) {
        guard let track = mediaPlayer.audioTracks.first(where: { $0.trackId == id }) else { return }
        track.isSelectedExclusively = true
        preferredAudioTrackID = id
        refreshTracks()
    }

    func selectEmbeddedSubtitle(id: String?) {
        guard let id else {
            mediaPlayer.deselectAllTextTracks()
            preferredEmbeddedSubtitleTrackID = nil
            selectedExternalSubtitleID = nil
            refreshTracks()
            return
        }
        guard let track = mediaPlayer.textTracks.first(where: { $0.trackId == id }), externalTrackIDs[id] == nil else { return }
        track.isSelectedExclusively = true
        preferredEmbeddedSubtitleTrackID = id
        selectedExternalSubtitleID = nil
        refreshTracks()
    }

    func selectLoadedExternalSubtitle(id: String) -> Bool {
        guard let trackID = externalTrackIDs.first(where: { $0.value == id })?.key,
              let track = mediaPlayer.textTracks.first(where: { $0.trackId == trackID }) else { return false }
        track.isSelectedExclusively = true
        selectedExternalSubtitleID = id
        preferredEmbeddedSubtitleTrackID = nil
        refreshTracks()
        return true
    }

    func addExternalSubtitle(url: URL, id: String, title: String) -> Bool {
        pendingExternalSubtitle = ExternalSubtitleOption(id: id, virtualPath: id, title: title)
        let result = mediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: true)
        guard result == 0 else {
            pendingExternalSubtitle = nil
            return false
        }
        return true
    }

    func setSubtitleAppearance(_ appearance: SubtitleAppearance) {
        subtitleAppearance = appearance
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        diagnosticsEnabled = enabled
        nextDiagnosticsUpdateTime = 0
        if enabled {
            refreshDiagnostics(force: true)
        } else {
            diagnostics = nil
        }
    }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in self?.handleStateChange(newState) }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.refreshTiming() }
    }

    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak self] in self?.handleBufferingChange(progress) }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.duration = max(0, TimeInterval(length) / 1_000)
            if self.hasStartedPlayback && PlaybackPresentation.isNearEnd(currentTime: self.currentTime, duration: self.duration) {
                self.hasReachedEnd = true
            }
        }
    }


    nonisolated func mediaPlayerTrackAdded(_ trackID: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in self?.refreshTracks() }
    }

    nonisolated func mediaPlayerTrackRemoved(_ trackID: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in self?.refreshTracks() }
    }

    nonisolated func mediaPlayerTrackUpdated(_ trackID: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in self?.refreshTracks() }
    }

    nonisolated func mediaPlayerTrackSelected(_ trackType: VLCMedia.TrackType, selectedId: String, unselectedId: String) {
        Task { @MainActor [weak self] in self?.handleTrackSelection(type: trackType, selectedID: selectedId) }
    }

    private func handleStateChange(_ state: VLCMediaPlayerState) {
        switch state {
        case .playing:
            hasStartedPlayback = true
            isPlaying = true
            isSeekable = mediaPlayer.isSeekable
            refreshTracks()
            applyPendingSeekIfPossible()
        case .paused:
            isPlaying = false
            isBuffering = false
            continuation.yield(.paused)
        case .stopped, .stopping, .nothingSpecial:
            let previouslyObservedTime = lastObservedTime
            refreshTiming(force: true)
            let stoppedTime = max(currentTime, previouslyObservedTime, TimeInterval(mediaPlayer.time.intValue) / 1_000)
            let stoppedDuration = max(duration, TimeInterval(mediaPlayer.media?.length.intValue ?? 0) / 1_000)
            let didReachEnd = hasStartedPlayback && (hasReachedEnd || PlaybackPresentation.isNearEnd(currentTime: stoppedTime, duration: stoppedDuration))
            isPlaying = false
            isBuffering = false
            bufferedTime = 0
            if didReachEnd && !hasEmittedEnded {
                hasEmittedEnded = true
                continuation.yield(.ended)
            }
        case .opening:
            break
        case .error:
            isPlaying = false
            let message = VLCLibrary.currentErrorMessage?.isEmpty == false ? VLCLibrary.currentErrorMessage! : "视频播放失败，请检查文件或网络连接。"
            continuation.yield(.failed(message: message))
        @unknown default:
            isPlaying = false
        }
    }

    private func handleBufferingChange(_ progress: Float) {
        let fraction = min(max(Double(progress), 0), 1)
        isBuffering = fraction < 1
        guard duration > 0 else {
            bufferedTime = currentTime
            return
        }
        bufferedTime = currentTime + (duration - currentTime) * fraction
    }

    private func handleTrackSelection(type: VLCMedia.TrackType, selectedID: String) {
        if type == .text, let pendingExternalSubtitle,
           mediaPlayer.textTracks.contains(where: { $0.trackId == selectedID }) {
            externalTrackIDs[selectedID] = pendingExternalSubtitle.id
            externalSubtitleTitles[pendingExternalSubtitle.id] = pendingExternalSubtitle.title
            selectedExternalSubtitleID = pendingExternalSubtitle.id
            self.pendingExternalSubtitle = nil
        } else if type == .text, externalTrackIDs[selectedID] == nil {
            selectedExternalSubtitleID = nil
        }
        refreshTracks()
    }

    private func refreshTiming(force: Bool = false) {
        let milliseconds = mediaPlayer.time.intValue
        let lengthMilliseconds = mediaPlayer.media?.length.intValue ?? 0
        if !isBuffering || force {
            currentTime = max(0, TimeInterval(milliseconds) / 1_000)
            lastObservedTime = currentTime
        }
        duration = max(0, TimeInterval(lengthMilliseconds) / 1_000)
        isSeekable = mediaPlayer.isSeekable
        if hasStartedPlayback && PlaybackPresentation.isNearEnd(currentTime: currentTime, duration: duration) {
            hasReachedEnd = true
        }
        if isSeekable { applyPendingSeekIfPossible() }
        refreshDiagnostics()
#if DEBUG
        logPlaybackStatisticsIfDue()
#endif
    }

    private func refreshTracks() {
        audioTracks = mediaPlayer.audioTracks.enumerated().map { trackOption($0.element, fallback: "Audio \($0.offset + 1)") }
        embeddedSubtitleTracks = mediaPlayer.textTracks.enumerated().compactMap { index, track in
            guard externalTrackIDs[track.trackId] == nil else { return nil }
            return trackOption(track, fallback: "Subtitle \(index + 1)")
        }
        if let preferredAudioTrackID, mediaPlayer.audioTracks.contains(where: { $0.trackId == preferredAudioTrackID }) {
            mediaPlayer.audioTracks.first(where: { $0.trackId == preferredAudioTrackID })?.isSelectedExclusively = true
        }
        if let preferredEmbeddedSubtitleTrackID,
           let track = mediaPlayer.textTracks.first(where: { $0.trackId == preferredEmbeddedSubtitleTrackID }), externalTrackIDs[track.trackId] == nil {
            track.isSelectedExclusively = true
        }
        refreshDiagnostics()
    }

    private func trackOption(_ track: VLCMediaPlayer.Track, fallback: String) -> PlaybackTrackOption {
        let title = PlaybackPresentation.trackTitle(name: track.trackName, description: track.trackDescription, language: track.language, fallback: fallback)
        let language = track.language?.nilIfEmpty
        let codec = track.codecName().nilIfEmpty
        return PlaybackTrackOption(id: track.trackId, title: title, languageCode: language, codec: codec, isSelected: track.isSelected)
    }

    private func refreshDiagnostics(force: Bool = false) {
        guard diagnosticsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now >= nextDiagnosticsUpdateTime else { return }
        nextDiagnosticsUpdateTime = now + 1
        diagnostics = collectDiagnostics()
    }

    private func collectDiagnostics() -> PlaybackDiagnosticsSnapshot {
        let statistics = mediaPlayer.media?.statistics
        let selectedVideo = mediaPlayer.videoTracks.first(where: \.isSelected)
        let selectedAudio = mediaPlayer.audioTracks.first(where: \.isSelected)
        let selectedSubtitle = mediaPlayer.textTracks.first(where: \.isSelected)
        let video = selectedVideo?.video
        let frameRate = video.flatMap { PlaybackPresentation.frameRate(numerator: $0.frameRate, denominator: $0.frameRateDenominator) }
        return PlaybackDiagnosticsSnapshot(
            currentTime: currentTime, duration: duration, isPlaying: isPlaying, isSeekable: isSeekable,
            inputBytesRead: Int64(statistics?.readBytes ?? 0), inputBitrate: Double(statistics?.inputBitrate ?? 0),
            demuxBytesRead: Int64(statistics?.demuxReadBytes ?? 0), demuxBitrate: Double(statistics?.demuxBitrate ?? 0),
            demuxCorrupted: Int64(statistics?.demuxCorrupted ?? 0), demuxDiscontinuity: Int64(statistics?.demuxDiscontinuity ?? 0),
            decodedVideo: Int64(statistics?.decodedVideo ?? 0), decodedAudio: Int64(statistics?.decodedAudio ?? 0),
            displayedPictures: Int64(statistics?.displayedPictures ?? 0), latePictures: Int64(statistics?.latePictures ?? 0),
            lostPictures: Int64(statistics?.lostPictures ?? 0), playedAudioBuffers: Int64(statistics?.playedAudioBuffers ?? 0), lostAudioBuffers: Int64(statistics?.lostAudioBuffers ?? 0),
            videoResolution: video.map { "\($0.width)×\($0.height)" }, videoFrameRate: frameRate, videoCodec: selectedVideo?.codecName().nilIfEmpty,
            audioTitle: selectedAudio.map { trackTitle($0, fallback: "Audio") }, audioLanguageCode: selectedAudio?.language?.nilIfEmpty, audioCodec: selectedAudio?.codecName().nilIfEmpty,
            subtitleTitle: selectedSubtitle.map { externalTrackIDs[$0.trackId].flatMap { externalSubtitleTitles[$0] } ?? trackTitle($0, fallback: "Subtitle") }, subtitleLanguageCode: selectedSubtitle?.language?.nilIfEmpty, subtitleCodec: selectedSubtitle?.codecName().nilIfEmpty
        )
    }

    private func trackTitle(_ track: VLCMediaPlayer.Track, fallback: String) -> String {
        PlaybackPresentation.trackTitle(name: track.trackName, description: track.trackDescription, language: track.language, fallback: fallback)
    }

#if DEBUG
    private func logPlaybackStatisticsIfDue() {
        guard isPlaying else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextStatisticsLogTime else { return }
        nextStatisticsLogTime = now + 5
        let snapshot = collectDiagnostics()
        print("VLCKitStats inputBitrate=\(snapshot.inputBitrate) demuxBitrate=\(snapshot.demuxBitrate) decodedVideo=\(snapshot.decodedVideo) displayedPictures=\(snapshot.displayedPictures) latePictures=\(snapshot.latePictures) lostPictures=\(snapshot.lostPictures) lostAudioBuffers=\(snapshot.lostAudioBuffers)")
    }
#endif

    private func applyPendingSeekIfPossible() {
        guard let pendingSeekSeconds, mediaPlayer.isSeekable else { return }
        self.pendingSeekSeconds = nil
        let target = duration > 0 ? min(pendingSeekSeconds, duration) : pendingSeekSeconds
        mediaPlayer.time = VLCTime(int: Int32((target * 1_000).rounded()))
        hasReachedEnd = false
        lastObservedTime = target
        currentTime = target
    }

    deinit {
        mediaPlayer.stop()
        continuation.finish()
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
