import SwiftUI
import UIKit

struct PlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
#if DEBUG
            if let adapter = coordinator.controller as? VLCPlayerControllerAdapter {
                VLCPlayerContainerView(adapter: adapter, coordinator: coordinator)
            } else if let fixture = coordinator.controller as? FixturePlayerController {
                FixturePlayerContainerView(fixture: fixture, coordinator: coordinator, dismiss: dismiss)
            }
#else
            if let adapter = coordinator.controller as? VLCPlayerControllerAdapter {
                VLCPlayerContainerView(adapter: adapter, coordinator: coordinator)
            }
#endif
        }
        .overlay(alignment: .bottom) {
            if case let .failed(message) = coordinator.state {
                Text(message).padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(50)
            }
        }
        .onExitCommand { coordinator.playerDidDisappear(); dismiss() }
        .onDisappear { coordinator.playerDidDisappear() }
    }
}

struct VLCPlayerRepresentable: UIViewRepresentable {
    let adapter: VLCPlayerControllerAdapter
    func makeUIView(context: Context) -> UIView { adapter.videoView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
struct VLCPlayerContainerView: View {
    @ObservedObject var adapter: VLCPlayerControllerAdapter
    @ObservedObject var coordinator: PlayerCoordinator
    var body: some View {
        PlaybackChrome(coordinator: coordinator, currentTime: adapter.currentTime, duration: adapter.duration, isPlaying: adapter.isPlaying, isSeekable: adapter.isSeekable, isBuffering: adapter.isBuffering, bufferedTime: adapter.bufferedTime, audioTracks: adapter.audioTracks, embeddedSubtitleTracks: adapter.embeddedSubtitleTracks, selectedExternalSubtitleID: adapter.selectedExternalSubtitleID, diagnostics: adapter.diagnostics, play: adapter.play, pause: adapter.pause, seek: { seconds in Task { await adapter.seek(to: seconds) } }, selectAudio: adapter.selectAudioTrack, setDiagnosticsEnabled: adapter.setDiagnosticsEnabled) {
            VLCPlayerRepresentable(adapter: adapter)
        }
    }
}

#if DEBUG
struct FixturePlayerContainerView: View {
    @ObservedObject var fixture: FixturePlayerController
    @ObservedObject var coordinator: PlayerCoordinator
    let dismiss: DismissAction
    var body: some View {
        PlaybackChrome(coordinator: coordinator, currentTime: fixture.currentTime, duration: fixture.duration, isPlaying: fixture.isPlaying, isSeekable: fixture.isSeekable, isBuffering: fixture.isBuffering, bufferedTime: fixture.bufferedTime, audioTracks: fixture.audioTracks, embeddedSubtitleTracks: fixture.embeddedSubtitleTracks, selectedExternalSubtitleID: fixture.selectedExternalSubtitleID, diagnostics: fixture.diagnostics, play: fixture.play, pause: fixture.pause, seek: { seconds in Task { await fixture.seek(to: seconds) } }, selectAudio: fixture.selectAudioTrack, setDiagnosticsEnabled: fixture.setDiagnosticsEnabled) {
            Color.black.overlay(Image(systemName: "play.rectangle.fill").font(.system(size: 96)).foregroundStyle(.white))
        }
        .overlay(alignment: .topTrailing) {
            Button("Done") { coordinator.playerDidDisappear(); dismiss() }
                .accessibilityIdentifier("player.done")
                .padding(40)
        }
    }
}
#endif

private struct PlaybackChrome<VideoContent: View>: View {
    private enum FocusTarget: Hashable { case surface, playPause, rewind, forward, subtitles, audio, diagnostics }
    @ObservedObject var coordinator: PlayerCoordinator
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let isSeekable: Bool
    let isBuffering: Bool
    let bufferedTime: TimeInterval
    let audioTracks: [PlaybackTrackOption]
    let embeddedSubtitleTracks: [PlaybackTrackOption]
    let selectedExternalSubtitleID: String?
    let diagnostics: PlaybackDiagnosticsSnapshot?
    let play: () -> Void
    let pause: () -> Void
    let seek: (TimeInterval) -> Void
    let selectAudio: (String) -> Void
    let setDiagnosticsEnabled: (Bool) -> Void
    @ViewBuilder let videoContent: () -> VideoContent

    @State private var controlsVisible = true
    @State private var surfaceEnabled = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var subtitleDialogVisible = false
    @State private var audioDialogVisible = false
    @FocusState private var focus: FocusTarget?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            videoContent()
                .focusable(surfaceEnabled)
                .focused($focus, equals: .surface)
            if let diagnostics { PlaybackDiagnosticsPanel(snapshot: diagnostics).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(48) }
            if controlsVisible || !isPlaying { controls.transition(.opacity) }
        }
        .ignoresSafeArea()
        .defaultFocus($focus, .playPause)
        .onAppear {
            surfaceEnabled = false
            focus = .playPause
            controlsVisible = true
            revealControls()
        }
        .onDisappear { hideControlsTask?.cancel() }
        .onChange(of: isPlaying) { _, playing in if playing { revealControls() } else { hideControlsTask?.cancel(); controlsVisible = true } }
        .onChange(of: focus) { _, target in if target != nil { revealControls() } }
        .onTapGesture { togglePlayback() }
        .onPlayPauseCommand { togglePlayback() }
        .onMoveCommand { direction in
            if focus == .surface {
                moveSurface(direction)
            } else if direction == .up || direction == .down {
                surfaceEnabled = true
                focus = .surface
            }
        }
        .confirmationDialog("Subtitles", isPresented: $subtitleDialogVisible, titleVisibility: .visible) {
            Button {
                Task { await coordinator.selectSubtitle(.off) }
            } label: {
                Text("\(isOffSelected ? "✓ " : "")Off")
            }
            .accessibilityLabel("Off")
            .accessibilityValue(isOffSelected ? "Selected" : "Not selected")
            ForEach(embeddedSubtitleTracks) { track in
                Button {
                    Task { await coordinator.selectSubtitle(.embedded(trackID: track.id)) }
                } label: {
                    Text("\(isEmbeddedSubtitleSelected(track.id) ? "✓ " : "")\(trackLabel(track))")
                }
                .accessibilityLabel(trackLabel(track))
                .accessibilityValue(isEmbeddedSubtitleSelected(track.id) ? "Selected" : "Not selected")
            }
            if coordinator.externalSubtitleDiscoveryState == .loading { Button("Loading external subtitles…") {}.disabled(true) }
            ForEach(coordinator.externalSubtitles) { option in
                Button {
                    Task { await coordinator.selectSubtitle(.external(fileID: option.id)) }
                } label: {
                    Text("\(isExternalSubtitleSelected(option.id) ? "✓ " : "")\(option.title)")
                }
                .accessibilityLabel(option.title)
                .accessibilityValue(isExternalSubtitleSelected(option.id) ? "Selected" : "Not selected")
            }
            if case .failed = coordinator.externalSubtitleDiscoveryState { Button("Retry external subtitles") { coordinator.retryExternalSubtitleDiscovery() } }
        }
        .confirmationDialog("Audio", isPresented: $audioDialogVisible, titleVisibility: .visible) {
            ForEach(audioTracks) { track in
                Button {
                    selectAudio(track.id)
                } label: {
                    Text("\(track.isSelected ? "✓ " : "")\(trackLabel(track))")
                }
                .accessibilityLabel(trackLabel(track))
                .accessibilityValue(track.isSelected ? "Selected" : "Not selected")
            }
        }
        .alert("Subtitle", isPresented: Binding(get: { coordinator.subtitleSelectionError != nil }, set: { if !$0 { coordinator.subtitleSelectionError = nil } })) {
            Button("OK", role: .cancel) { coordinator.subtitleSelectionError = nil }
        } message: { Text(coordinator.subtitleSelectionError ?? "") }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
                .focused($focus, equals: .playPause)
                .accessibilityIdentifier("player.play-pause")
            Button(action: { seek(currentTime - 10) }) { Image(systemName: "gobackward.10") }
                .disabled(!isSeekable).focused($focus, equals: .rewind).accessibilityIdentifier("player.seek-backward-10").accessibilityLabel("Rewind 10 seconds")
            Button(action: { seek(currentTime + 10) }) { Image(systemName: "goforward.10") }
                .disabled(!isSeekable).focused($focus, equals: .forward).accessibilityIdentifier("player.seek-forward-10").accessibilityLabel("Forward 10 seconds")
            Text(timeText(currentTime)).monospacedDigit().frame(minWidth: 64, alignment: .leading).accessibilityIdentifier("player.current-time")
            PlaybackTimeline(currentTime: currentTime, bufferedTime: bufferedTime, duration: duration, isBuffering: isBuffering)
                .frame(width: 560, height: 14)
                .accessibilityIdentifier("player.progress")
            Text(duration > 0 ? timeText(duration) : "--:--").monospacedDigit().frame(minWidth: 64, alignment: .trailing)
            if !embeddedSubtitleTracks.isEmpty || !coordinator.externalSubtitles.isEmpty || coordinator.externalSubtitleDiscoveryState != .loaded {
                Button(action: { subtitleDialogVisible = true }) { Image(systemName: "captions.bubble") }
                    .focused($focus, equals: .subtitles)
                    .accessibilityIdentifier("player.subtitles")
            }
            if audioTracks.count > 1 {
                Button(action: { audioDialogVisible = true }) {
                    Image(systemName: "speaker.wave.2")
                }
                .focused($focus, equals: .audio)
                .accessibilityIdentifier("player.audio")
                .accessibilityLabel("Audio")
                .accessibilityValue(audioTracks.first(where: \.isSelected).map { "Selected \($0.title)" } ?? "Not selected")
            }
            Button(action: { setDiagnosticsEnabled(diagnostics == nil) }) { Image(systemName: "info.circle") }
                .focused($focus, equals: .diagnostics)
                .accessibilityIdentifier("player.diagnostics-toggle")
                .accessibilityLabel("Stats for Nerds")
        }
        .font(.title3).buttonStyle(.bordered).padding(.horizontal, 24).padding(.vertical, 20)
    }
    private func moveSurface(_ direction: MoveCommandDirection) {
        revealControls()
        switch direction {
        case .down, .up:
            focus = .playPause
        case .left where isSeekable:
            seek(currentTime - 10)
        case .right where isSeekable:
            seek(currentTime + 10)
        default:
            break
        }
    }

    private func togglePlayback() { isPlaying ? pause() : play(); revealControls() }
    private func revealControls() {
        hideControlsTask?.cancel()
        controlsVisible = true
        guard isPlaying, surfaceEnabled, focus == .surface, !subtitleDialogVisible, !audioDialogVisible else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isPlaying, surfaceEnabled, focus == .surface, !subtitleDialogVisible, !audioDialogVisible else { return }
            controlsVisible = false
        }
    }
    private func timeText(_ seconds: TimeInterval) -> String { let value = max(0, Int(seconds.rounded(.down))); return value >= 3_600 ? String(format: "%d:%02d:%02d", value / 3_600, (value % 3_600) / 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60) }
    private func trackLabel(_ track: PlaybackTrackOption) -> String { [track.title, track.languageCode, track.codec].compactMap { $0 }.joined(separator: " · ") }
    private var isOffSelected: Bool {
        selectedExternalSubtitleID == nil && !embeddedSubtitleTracks.contains(where: \.isSelected)
    }

    private func isEmbeddedSubtitleSelected(_ id: String) -> Bool {
        selectedExternalSubtitleID == nil && embeddedSubtitleTracks.first(where: { $0.id == id })?.isSelected == true
    }

    private func isExternalSubtitleSelected(_ id: String) -> Bool {
        selectedExternalSubtitleID == id
    }
}

private struct PlaybackTimeline: View {
    let currentTime: TimeInterval
    let bufferedTime: TimeInterval
    let duration: TimeInterval
    let isBuffering: Bool

    private var playedFraction: Double {
        PlaybackPresentation.clampedProgressFraction(currentTime, duration: duration)
    }

    private var bufferedFraction: Double {
        max(playedFraction, PlaybackPresentation.clampedProgressFraction(bufferedTime, duration: duration))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.42)).frame(width: width * bufferedFraction)
                Capsule().fill(.tint).frame(width: width * playedFraction)
                Rectangle()
                    .fill(.white)
                    .frame(width: 3)
                    .offset(x: max(0, min(width - 3, width * playedFraction - 1.5)))
            }
        }
        .accessibilityLabel("Playback progress")
        .accessibilityValue(isBuffering ? "Buffering" : "\(Int((playedFraction * 100).rounded())) percent played")
    }
}

private struct PlaybackDiagnosticsPanel: View {
    let snapshot: PlaybackDiagnosticsSnapshot

    private let panelWidth: CGFloat = 800
    private let labelWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stats for Nerds")
                .font(.system(size: 24, weight: .semibold, design: .default))
            group("Playback", ["Time": "\(time(snapshot.currentTime)) / \(time(snapshot.duration))", "Playing": snapshot.isPlaying ? "Yes" : "No", "Seekable": snapshot.isSeekable ? "Yes" : "No"])
            group("Network/Demux", ["Input": "\(bytes(snapshot.inputBytesRead)) · \(bitrate(snapshot.inputBitrate))", "Demux": "\(bytes(snapshot.demuxBytesRead)) · \(bitrate(snapshot.demuxBitrate))", "Errors": "\(snapshot.demuxCorrupted) corrupt · \(snapshot.demuxDiscontinuity) discontinuities"])
            group("Video", ["Track": "\(snapshot.videoResolution ?? "—") · \(frameRate(snapshot.videoFrameRate)) · \(snapshot.videoCodec ?? "—")", "Frames": "\(snapshot.decodedVideo) decoded · \(snapshot.displayedPictures) displayed · \(snapshot.latePictures) late · \(snapshot.lostPictures) lost"])
            group("Audio/Subtitles", ["Audio": metadata(snapshot.audioTitle, snapshot.audioLanguageCode, snapshot.audioCodec), "Subtitle": metadata(snapshot.subtitleTitle, snapshot.subtitleLanguageCode, snapshot.subtitleCodec), "Buffers": "\(snapshot.playedAudioBuffers) played · \(snapshot.lostAudioBuffers) lost"])
        }
        .font(.system(size: 18, weight: .regular, design: .default))
        .frame(width: panelWidth, alignment: .leading)
        .padding(18)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("player.diagnostics")
    }

    private func group(_ title: String, _ rows: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .default))
            ForEach(rows.keys.sorted(), id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(key)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(rows[key] ?? "—")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func time(_ value: TimeInterval) -> String { String(format: "%.1fs", value) }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
    private func bitrate(_ value: Double) -> String { PlaybackPresentation.diagnosticBitrate(value) }
    private func frameRate(_ value: Double?) -> String { value.map { String(format: "%.2f fps", $0) } ?? "—" }
    private func metadata(_ title: String?, _ language: String?, _ codec: String?) -> String { PlaybackPresentation.diagnosticMetadata(title, language, codec) }
}
