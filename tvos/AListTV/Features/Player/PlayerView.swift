import SwiftUI
import UIKit

struct PlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var exitRequestID = 0

    var body: some View {
        Group {
#if DEBUG
            if let adapter = coordinator.controller as? VLCPlayerControllerAdapter {
                VLCPlayerContainerView(adapter: adapter, coordinator: coordinator, dismiss: dismiss, exitRequestID: exitRequestID)
            } else if let fixture = coordinator.controller as? FixturePlayerController {
                FixturePlayerContainerView(fixture: fixture, coordinator: coordinator, dismiss: dismiss, exitRequestID: exitRequestID)
            }
#else
            if let adapter = coordinator.controller as? VLCPlayerControllerAdapter {
                VLCPlayerContainerView(adapter: adapter, coordinator: coordinator, dismiss: dismiss, exitRequestID: exitRequestID)
            }
#endif
        }
        .interactiveDismissDisabled()
        .onExitCommand { exitRequestID += 1 }
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
    let dismiss: DismissAction
    let exitRequestID: Int

    var body: some View {
        ImmersivePlaybackStage(
            coordinator: coordinator,
            exitRequestID: exitRequestID,
            currentTime: adapter.currentTime,
            duration: adapter.duration,
            isPlaying: adapter.isPlaying,
            isSeekable: adapter.isSeekable,
            isBuffering: adapter.isBuffering,
            bufferedTime: adapter.bufferedTime,
            audioTracks: adapter.audioTracks,
            embeddedSubtitleTracks: adapter.embeddedSubtitleTracks,
            selectedExternalSubtitleID: adapter.selectedExternalSubtitleID,
            diagnostics: adapter.diagnostics,
            play: adapter.play,
            pause: adapter.pause,
            seek: { seconds in Task { await adapter.seek(to: seconds) } },
            selectAudio: adapter.selectAudioTrack,
            setDiagnosticsEnabled: adapter.setDiagnosticsEnabled,
            close: { coordinator.playerDidDisappear(); dismiss() }
        ) {
            VLCPlayerRepresentable(adapter: adapter)
        }
    }
}

#if DEBUG
struct FixturePlayerContainerView: View {
    @ObservedObject var fixture: FixturePlayerController
    @ObservedObject var coordinator: PlayerCoordinator
    let dismiss: DismissAction
    let exitRequestID: Int

    var body: some View {
        ImmersivePlaybackStage(
            coordinator: coordinator,
            exitRequestID: exitRequestID,
            currentTime: fixture.currentTime,
            duration: fixture.duration,
            isPlaying: fixture.isPlaying,
            isSeekable: fixture.isSeekable,
            isBuffering: fixture.isBuffering,
            bufferedTime: fixture.bufferedTime,
            audioTracks: fixture.audioTracks,
            embeddedSubtitleTracks: fixture.embeddedSubtitleTracks,
            selectedExternalSubtitleID: fixture.selectedExternalSubtitleID,
            diagnostics: fixture.diagnostics,
            play: fixture.play,
            pause: fixture.pause,
            seek: { seconds in Task { await fixture.seek(to: seconds) } },
            selectAudio: fixture.selectAudioTrack,
            setDiagnosticsEnabled: fixture.setDiagnosticsEnabled,
            close: { coordinator.playerDidDisappear(); dismiss() }
        ) {
            Color.black
                .overlay(Image(systemName: "play.rectangle.fill").font(.system(size: 96)).foregroundStyle(.white.opacity(0.88)))
        }
    }
}
#endif

private struct ImmersivePlaybackStage<VideoContent: View>: View {
    private enum FocusTarget: Hashable { case surface, close, playPause, rewind, timeline, forward, subtitles, audio, diagnostics, panel }
    private enum PresentedPanel: Equatable { case subtitles, audio }

    @ObservedObject var coordinator: PlayerCoordinator
    let exitRequestID: Int
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
    let close: () -> Void
    @ViewBuilder let videoContent: () -> VideoContent

    @State private var chromeVisible = true
    @State private var hideChromeTask: Task<Void, Never>?
    @State private var presentedPanel: PresentedPanel?
    @State private var scrubTarget: TimeInterval?
    @FocusState private var focus: FocusTarget?

    private var hasSubtitleOptions: Bool {
        !embeddedSubtitleTracks.isEmpty || !coordinator.externalSubtitles.isEmpty || coordinator.externalSubtitleDiscoveryState != .loaded
    }

    var body: some View {
        ZStack {
            Color.black
            MenuKeyCommandCapture(
                onMenu: handleExitCommand,
                onDirectional: { revealChrome(focus: .playPause) },
                interceptsDirectional: !chromeVisible && presentedPanel == nil && diagnostics == nil
            )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            videoContent()
            Color.clear
                .contentShape(Rectangle())
                .focusable(focus == .surface)
                .focused($focus, equals: .surface)
                .onMoveCommand(perform: handleMove)

            if chromeVisible || presentedPanel != nil || coordinator.isTerminalFailure {
                chromeBackdrop
                    .transition(.opacity)
            }

            if chromeVisible {
                chrome
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let panel = presentedPanel {
                trackPanel(panel)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let diagnostics {
                PlaybackDiagnosticsPanel(snapshot: diagnostics, close: { setDiagnosticsEnabled(false) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(46)
            }

            if case let .failed(message) = coordinator.state {
                failureCard(message: message)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focus, .playPause)
        .animation(.easeOut(duration: 0.22), value: chromeVisible)
        .animation(.easeOut(duration: 0.2), value: presentedPanel != nil)
        .onAppear {
            revealChrome(focus: .playPause)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                focus = .playPause
            }
        }
        .onDisappear { hideChromeTask?.cancel() }
        .onChange(of: isPlaying) { _, playing in
            if playing { scheduleChromeHideIfNeeded() } else { revealChrome() }
        }
        .onChange(of: isBuffering) { _, buffering in if buffering { revealChrome() } else { scheduleChromeHideIfNeeded() } }
        .onChange(of: focus) { _, target in
            guard target != nil, target != .surface else { return }
            revealChrome()
        }
        .onChange(of: exitRequestID) { _, _ in handleExitCommand() }
        .onPlayPauseCommand { togglePlayback() }
        .onTapGesture { togglePlayback() }
        .onMoveCommand(perform: handleMove)
    }

    private var chromeBackdrop: some View {
        LinearGradient(
            colors: [.black.opacity(0.68), .clear, .black.opacity(0.78)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            centerTransport
            Spacer(minLength: 24)
            transportDock
        }
        .padding(.horizontal, 74)
        .padding(.vertical, 50)
    }

    private var header: some View {
        HStack(spacing: 22) {
            Button(action: close) {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.semibold))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .close)
            .accessibilityIdentifier("player.done")
            .accessibilityLabel("Done")

            VStack(alignment: .leading, spacing: 5) {
                Text(coordinator.nowPlayingTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(nowPlayingDetail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer()
            if isBuffering || coordinator.state == .loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(isBuffering ? "Buffering" : "Loading")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private var centerTransport: some View {
        Button(action: togglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 34, weight: .bold))
                .frame(width: 106, height: 106)
                .background(.white.opacity(0.18), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.play-pause")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private var transportDock: some View {
        VStack(spacing: 22) {
            timeline
            HStack(spacing: 16) {
                Button(action: { performSeek(currentTime - 10) }) {
                    Label("Back 10 seconds", systemImage: "gobackward.10")
                }
                .disabled(!isSeekable)
                .focused($focus, equals: .rewind)
                .accessibilityIdentifier("player.seek-backward-10")

                Button(action: togglePlayback) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .focused($focus, equals: .playPause)

                Button(action: { performSeek(currentTime + 10) }) {
                    Label("Forward 10 seconds", systemImage: "goforward.10")
                }
                .disabled(!isSeekable)
                .focused($focus, equals: .forward)
                .accessibilityIdentifier("player.seek-forward-10")

                Spacer(minLength: 20)

                if hasSubtitleOptions {
                    Button(action: { openPanel(.subtitles) }) { Label("Subtitles", systemImage: "captions.bubble") }
                        .focused($focus, equals: .subtitles)
                        .accessibilityIdentifier("player.subtitles")
                }
                if audioTracks.count > 1 {
                    Button(action: { openPanel(.audio) }) { Label("Audio", systemImage: "speaker.wave.2") }
                        .focused($focus, equals: .audio)
                        .accessibilityIdentifier("player.audio")
                        .accessibilityValue(selectedAudioTitle)
                }
                Button(action: { setDiagnosticsEnabled(diagnostics == nil) }) { Label("Diagnostics", systemImage: "waveform.path.ecg") }
                    .focused($focus, equals: .diagnostics)
                    .accessibilityIdentifier("player.diagnostics-toggle")
                    .accessibilityLabel("Stats for Nerds")
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.bordered)
        }
        .padding(28)
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var timeline: some View {
        VStack(spacing: 10) {
            HStack {
                Text(timeText(displayTime)).monospacedDigit().accessibilityIdentifier("player.current-time")
                Spacer()
                if scrubTarget != nil { Text("Seek to \(timeText(displayTime))").foregroundStyle(.tint) }
                else { Text("−\(timeText(max(0, duration - currentTime))) remaining") }
            }
            PlaybackTimeline(currentTime: displayTime, bufferedTime: bufferedTime, duration: duration, isBuffering: isBuffering, isScrubbing: scrubTarget != nil)
                .frame(height: 18)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("player.progress")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(focus == .timeline ? .black.opacity(0.72) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if focus == .timeline {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.42), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusable(isSeekable)
        .focused($focus, equals: .timeline)
        .focusEffectDisabled()
        .onTapGesture { commitScrub() }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("player.timeline")
        .accessibilityLabel("Playback timeline")
        .accessibilityValue("\(timeText(displayTime)) of \(timeText(duration))")
    }

    @ViewBuilder
    private func trackPanel(_ panel: PresentedPanel) -> some View {
        let isSubtitles = panel == .subtitles
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isSubtitles ? "Subtitles" : "Audio")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("Close") { dismissPanel() }
                    .accessibilityIdentifier("player.track-panel-close")
            }
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 10) {
                    if isSubtitles {
                        trackRow(title: "Off", detail: nil, selected: isOffSelected) {
                            Task { await coordinator.selectSubtitle(.off) }
                            dismissPanel()
                        }
                        ForEach(embeddedSubtitleTracks) { track in
                            trackRow(title: trackLabel(track), detail: nil, selected: isEmbeddedSubtitleSelected(track.id)) {
                                Task { await coordinator.selectSubtitle(.embedded(trackID: track.id)) }
                                dismissPanel()
                            }
                        }
                        if coordinator.externalSubtitleDiscoveryState == .loading {
                            Label("Loading external subtitles…", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary).padding(.vertical, 14)
                        }
                        ForEach(coordinator.externalSubtitles) { option in
                            trackRow(title: option.title, detail: "External subtitle", selected: isExternalSubtitleSelected(option.id)) {
                                Task { await coordinator.selectSubtitle(.external(fileID: option.id)) }
                                dismissPanel()
                            }
                        }
                        if case .failed = coordinator.externalSubtitleDiscoveryState {
                            Button("Retry external subtitles") { coordinator.retryExternalSubtitleDiscovery() }
                                .accessibilityIdentifier("player.retry-subtitles")
                        }
                    } else {
                        ForEach(audioTracks) { track in
                            trackRow(title: trackLabel(track), detail: nil, selected: track.isSelected) {
                                selectAudio(track.id)
                                dismissPanel()
                            }
                        }
                    }
                }
            }
        }
        .padding(36)
        .frame(width: 760, height: 630, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
        .focused($focus, equals: .panel)
        .accessibilityIdentifier(isSubtitles ? "player.subtitle-panel" : "player.audio-panel")
    }

    private func trackRow(title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text((selected ? "✓ " : "") + title).lineLimit(1)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func failureCard(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(.yellow)
            Text("Playback unavailable").font(.title2.weight(.bold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
            HStack(spacing: 18) {
                Button("Try Again") { coordinator.retryPlayback() }
                    .accessibilityIdentifier("player.retry")
                Button("Done") { close() }
                    .accessibilityIdentifier("player.failure-done")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(38)
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityIdentifier("player.failure")
    }

    private var displayTime: TimeInterval { scrubTarget ?? currentTime }
    private var nowPlayingDetail: String { coordinator.nowPlayingPath ?? "Video" }
    private var selectedAudioTitle: String { audioTracks.first(where: \.isSelected)?.title ?? "Audio" }
    private var isOffSelected: Bool { selectedExternalSubtitleID == nil && !embeddedSubtitleTracks.contains(where: \.isSelected) }
    private func isEmbeddedSubtitleSelected(_ id: String) -> Bool { selectedExternalSubtitleID == nil && embeddedSubtitleTracks.first(where: { $0.id == id })?.isSelected == true }
    private func isExternalSubtitleSelected(_ id: String) -> Bool { selectedExternalSubtitleID == id }

    private func togglePlayback() { isPlaying ? pause() : play(); revealChrome() }
    private func performSeek(_ seconds: TimeInterval) { seek(PlaybackPresentation.clampedSeekTarget(seconds, duration: duration)); scrubTarget = nil; revealChrome() }
    private func commitScrub() { guard let scrubTarget else { return }; performSeek(scrubTarget) }
    private func openPanel(_ panel: PresentedPanel) { presentedPanel = panel; hideChromeTask?.cancel(); chromeVisible = true; focus = .panel }
    private func dismissPanel() {
        let target: FocusTarget = presentedPanel == .audio ? .audio : .subtitles
        presentedPanel = nil
        focus = target
        scheduleChromeHideIfNeeded()
    }
    private func timeText(_ seconds: TimeInterval) -> String { let value = max(0, Int(seconds.rounded(.down))); return value >= 3_600 ? String(format: "%d:%02d:%02d", value / 3_600, (value % 3_600) / 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60) }
    private func trackLabel(_ track: PlaybackTrackOption) -> String { [track.title, track.languageCode, track.codec].compactMap { $0 }.joined(separator: " · ") }

    private func handleExitCommand() {
        guard !coordinator.isTerminalFailure else {
            close()
            return
        }

        let hasTransientUI = chromeVisible || presentedPanel != nil || diagnostics != nil
        guard hasTransientUI else {
            close()
            return
        }

        hideChromeTask?.cancel()
        presentedPanel = nil
        if diagnostics != nil { setDiagnosticsEnabled(false) }
        focus = .surface
        chromeVisible = false
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        revealChrome()
        guard presentedPanel == nil else { return }
        if focus == .timeline, isSeekable {
            switch direction {
            case .left: scrubTarget = PlaybackPresentation.clampedSeekTarget(displayTime - 10, duration: duration)
            case .right: scrubTarget = PlaybackPresentation.clampedSeekTarget(displayTime + 10, duration: duration)
            default: break
            }
            return
        }
        if focus == .surface, isSeekable {
            switch direction {
            case .left: performSeek(currentTime - 10)
            case .right: performSeek(currentTime + 10)
            case .up, .down: focus = .playPause
            default: break
            }
        } else if direction == .up || direction == .down {
            focus = .surface
        }
    }

    private func revealChrome(focus target: FocusTarget? = nil) {
        hideChromeTask?.cancel()
        chromeVisible = true
        if let target { focus = target }
        scheduleChromeHideIfNeeded()
    }

    private func scheduleChromeHideIfNeeded() {
        hideChromeTask?.cancel()
        guard isPlaying, !isBuffering, presentedPanel == nil, !coordinator.isTerminalFailure, focus == .surface else { return }
        hideChromeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, isPlaying, !isBuffering, presentedPanel == nil, !coordinator.isTerminalFailure, focus == .surface else { return }
            chromeVisible = false
        }
    }
}

private struct PlaybackTimeline: View {
    let currentTime: TimeInterval
    let bufferedTime: TimeInterval
    let duration: TimeInterval
    let isBuffering: Bool
    let isScrubbing: Bool

    private var playedFraction: Double { PlaybackPresentation.clampedProgressFraction(currentTime, duration: duration) }
    private var bufferedFraction: Double { max(playedFraction, PlaybackPresentation.clampedProgressFraction(bufferedTime, duration: duration)) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.45)).frame(width: width * bufferedFraction)
                Capsule().fill(.tint).frame(width: width * playedFraction)
                Circle().fill(.white).frame(width: isScrubbing ? 18 : 12, height: isScrubbing ? 18 : 12).offset(x: max(0, min(width - (isScrubbing ? 18 : 12), width * playedFraction - (isScrubbing ? 9 : 6))))
            }
        }
        .accessibilityValue(isBuffering ? "Buffering" : "\(Int((playedFraction * 100).rounded())) percent played")
    }
}

private struct PlaybackDiagnosticsPanel: View {
    let snapshot: PlaybackDiagnosticsSnapshot
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Stats for Nerds").font(.title3.weight(.semibold)); Spacer(); Button("Close", action: close) }
            group("Playback", ["Time": time(snapshot.currentTime) + " / " + time(snapshot.duration), "Playing": snapshot.isPlaying ? "Yes" : "No", "Seekable": snapshot.isSeekable ? "Yes" : "No"])
            group("Network/Demux", ["Input": bytes(snapshot.inputBytesRead) + " · " + bitrate(snapshot.inputBitrate), "Demux": bytes(snapshot.demuxBytesRead) + " · " + bitrate(snapshot.demuxBitrate), "Errors": "\(snapshot.demuxCorrupted) corrupt · \(snapshot.demuxDiscontinuity) discontinuities"])
            group("Video", ["Track": "\(snapshot.videoResolution ?? "—") · \(frameRate(snapshot.videoFrameRate)) · \(snapshot.videoCodec ?? "—")", "Frames": "\(snapshot.decodedVideo) decoded · \(snapshot.displayedPictures) displayed · \(snapshot.latePictures) late"])
            group("Audio/Subtitles", ["Audio": metadata(snapshot.audioTitle, snapshot.audioLanguageCode, snapshot.audioCodec), "Subtitle": metadata(snapshot.subtitleTitle, snapshot.subtitleLanguageCode, snapshot.subtitleCodec)])
        }
        .font(.subheadline)
        .frame(width: 760, alignment: .leading)
        .padding(22)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("player.diagnostics")
    }

    private func group(_ title: String, _ rows: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(rows.keys.sorted(), id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(key).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                    Text(rows[key] ?? "—").lineLimit(1)
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

private struct MenuKeyCommandCapture: UIViewControllerRepresentable {
    let onMenu: () -> Void
    let onDirectional: () -> Void
    let interceptsDirectional: Bool

    func makeUIViewController(context: Context) -> MenuKeyCommandController {
        MenuKeyCommandController(onMenu: onMenu, onDirectional: onDirectional, interceptsDirectional: interceptsDirectional)
    }

    func updateUIViewController(_ controller: MenuKeyCommandController, context: Context) {
        controller.onMenu = onMenu
        controller.onDirectional = onDirectional
        controller.interceptsDirectional = interceptsDirectional
        controller.claimFirstResponder()
    }
}

private final class MenuKeyCommandController: UIViewController {
    var onMenu: () -> Void
    var onDirectional: () -> Void
    var interceptsDirectional: Bool

    init(onMenu: @escaping () -> Void, onDirectional: @escaping () -> Void, interceptsDirectional: Bool) {
        self.onMenu = onMenu
        self.onDirectional = onDirectional
        self.interceptsDirectional = interceptsDirectional
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        claimFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onMenu()
            return
        }
        if interceptsDirectional, presses.contains(where: Self.isDirectional) {
            onDirectional()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))]
    }

    func claimFirstResponder() {
        guard view.window != nil else { return }
        becomeFirstResponder()
    }

    @objc private func handleEscape() {
        onMenu()
    }

    private static func isDirectional(_ press: UIPress) -> Bool {
        switch press.type {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            true
        default:
            false
        }
    }
}
