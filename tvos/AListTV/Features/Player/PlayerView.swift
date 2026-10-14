import SwiftUI
import UIKit

struct PlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var exitRequestID = 0

    var body: some View {
        Group {
#if DEBUG
            if let fixture = coordinator.controller as? FixturePlayerController {
                FixturePlayerContainerView(fixture: fixture, coordinator: coordinator, dismiss: dismiss, exitRequestID: exitRequestID)
            } else {
                playerContainer
            }
#else
            playerContainer
#endif
        }
        .interactiveDismissDisabled()
        .onExitCommand { exitRequestID += 1 }
        .onDisappear { coordinator.playerDidDisappear() }
    }

    @ViewBuilder private var playerContainer: some View {
        if let adapter = coordinator.controller as? VLCPlayerControllerAdapter {
            VLCPlayerContainerView(adapter: adapter, coordinator: coordinator, dismiss: dismiss, exitRequestID: exitRequestID)
        } else if let adapter = coordinator.controller as? NativePlayerControllerAdapter {
            NativePlayerContainerView(adapter: adapter, coordinator: coordinator, dismiss: dismiss, exitRequestID: exitRequestID)
        }
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
            subtitleAppearance: coordinator.subtitleAppearance,
            subtitleOverlay: coordinator.subtitleOverlay,
            updateSubtitleAppearance: coordinator.updateSubtitleAppearance,
            diagnostics: adapter.diagnostics,
            play: adapter.play,
            pause: adapter.pause,
            seek: { seconds in Task { await adapter.seek(to: seconds) } },
            seekAndPlay: { seconds in Task { await adapter.seek(to: seconds); adapter.play() } },
            selectAudio: adapter.selectAudioTrack,
            setDiagnosticsEnabled: adapter.setDiagnosticsEnabled,
            close: { coordinator.playerDidDisappear(); dismiss() }
        ) {
            VLCPlayerRepresentable(adapter: adapter)
        }
    }
}

struct NativePlayerRepresentable: UIViewRepresentable {
    let adapter: NativePlayerControllerAdapter
    func makeUIView(context: Context) -> UIView { adapter.videoView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct NativePlayerContainerView: View {
    @ObservedObject var adapter: NativePlayerControllerAdapter
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
            subtitleAppearance: coordinator.subtitleAppearance,
            subtitleOverlay: coordinator.subtitleOverlay,
            updateSubtitleAppearance: coordinator.updateSubtitleAppearance,
            diagnostics: adapter.diagnostics,
            play: adapter.play,
            pause: adapter.pause,
            seek: { seconds in Task { await adapter.seek(to: seconds) } },
            seekAndPlay: { seconds in Task { await adapter.seek(to: seconds); adapter.play() } },
            selectAudio: adapter.selectAudioTrack,
            setDiagnosticsEnabled: adapter.setDiagnosticsEnabled,
            close: { coordinator.playerDidDisappear(); dismiss() }
        ) {
            NativePlayerRepresentable(adapter: adapter)
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
            subtitleAppearance: coordinator.subtitleAppearance,
            subtitleOverlay: coordinator.subtitleOverlay,
            updateSubtitleAppearance: coordinator.updateSubtitleAppearance,
            diagnostics: fixture.diagnostics,
            play: fixture.play,
            pause: fixture.pause,
            seek: { seconds in Task { await fixture.seek(to: seconds) } },
            seekAndPlay: { seconds in Task { await fixture.seek(to: seconds); fixture.play() } },
            selectAudio: fixture.selectAudioTrack,
            setDiagnosticsEnabled: fixture.setDiagnosticsEnabled,
            close: { coordinator.playerDidDisappear(); dismiss() }
        ) {
            Color.black
        }
    }
}
#endif

private struct ImmersivePlaybackStage<VideoContent: View>: View {
    private enum FocusTarget: Hashable { case surface, close, playPause, rewind, timeline, forward, subtitles, audio, autoplay, diagnostics, panel, panelItem, appearance, appearanceFont, appearanceReset, appearanceBack, resume, startOver, coverFlow }
    private enum PresentedPanel: Equatable { case subtitles, audio, subtitleAppearance }

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
    let subtitleAppearance: SubtitleAppearance
    @ObservedObject var subtitleOverlay: SubtitleOverlayModel
    let updateSubtitleAppearance: (SubtitleAppearance) -> Void
    let diagnostics: PlaybackDiagnosticsSnapshot?
    let play: () -> Void
    let pause: () -> Void
    let seek: (TimeInterval) -> Void
    let seekAndPlay: (TimeInterval) -> Void
    let selectAudio: (String) -> Void
    let setDiagnosticsEnabled: (Bool) -> Void
    let close: () -> Void
    @ViewBuilder let videoContent: () -> VideoContent

    @State private var chromeVisible = true
    @State private var hideChromeTask: Task<Void, Never>?
    @State private var presentedPanel: PresentedPanel?
    @State private var scrubTarget: TimeInterval?
    @State private var touchScrubOrigin: TimeInterval?
    @State private var panOriginFocus: FocusTarget??
    @State private var isCoverFlowVisible = false
    @State private var coverFlowIndex = 0
    @State private var coverFlowPanOrigin: Int?
    @State private var coverFlowPanMovedAt: Date?
    @State private var coverFlowIdleTask: Task<Void, Never>?
    @FocusState private var focus: FocusTarget?

    private var hasSubtitleOptions: Bool {
        !embeddedSubtitleTracks.isEmpty || !coordinator.externalSubtitles.isEmpty || coordinator.externalSubtitleDiscoveryState != .loaded
    }

    var body: some View {
        ZStack {
            Color.black
            MenuKeyCommandCapture(
                onMenu: handleExitCommand,
                onDirectional: handleInterceptedDirection,
                onSelect: handleSelectCommand,
                onPlayPause: togglePlayback,
                onPanChanged: handleTouchPanChanged,
                onPanEnded: handleTouchPanEnded,
                interceptsDirectional: !chromeVisible && presentedPanel == nil && diagnostics == nil && !isCoverFlowVisible,
                interceptsSelect: shouldInterceptSelect,
                interceptsPlayPause: !chromeVisible && presentedPanel == nil && diagnostics == nil && coordinator.resumePrompt == nil
            )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            videoContent()
            SubtitleOverlayView(text: subtitleOverlay.activeText, appearance: subtitleAppearance)
            Color.clear
                .contentShape(Rectangle())
                .focusable(!isCoverFlowVisible && (!chromeVisible || focus == .surface))
                .focused($focus, equals: .surface)
                .onMoveCommand(perform: handleMove)

            if chromeVisible || presentedPanel != nil || coordinator.isTerminalFailure {
                chromeBackdrop
                    .transition(.opacity)
            }

            if chromeVisible {
                chrome
                    .disabled(presentedPanel != nil)
                    .opacity(presentedPanel != nil ? 0.3 : 1)
                    .transition(.opacity.combined(with: .offset(y: 24)))
            }

            if isCoverFlowVisible {
                coverFlowLayer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let panel = presentedPanel {
                if panel == .subtitleAppearance {
                    subtitleAppearancePanel
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    trackPanel(panel)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }

            if let diagnostics {
                PlaybackDiagnosticsPanel(snapshot: diagnostics, close: { setDiagnosticsEnabled(false) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 150)
                    .padding(.trailing, 88)
                    .transition(.opacity)
            }

            if case let .failed(message) = coordinator.state {
                failureCard(message: message)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focus, coordinator.resumePrompt == nil ? .playPause : .resume)
        .animation(.easeOut(duration: 0.3), value: chromeVisible)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: presentedPanel)
        .animation(.easeOut(duration: 0.2), value: diagnostics != nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: isCoverFlowVisible)
        .onAppear {
            revealChrome(focus: coordinator.resumePrompt == nil ? .playPause : .resume)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                focus = coordinator.resumePrompt == nil ? .playPause : .resume
            }
        }
        .onDisappear {
            hideChromeTask?.cancel()
            coverFlowIdleTask?.cancel()
        }
        .onChange(of: coordinator.siblingMedia) { _, _ in
            guard isCoverFlowVisible, let index = nowPlayingCoverIndex else { return }
            coverFlowIndex = index
        }
        .onChange(of: coordinator.resumePrompt) { _, prompt in
            if prompt != nil {
                hideChromeTask?.cancel()
                chromeVisible = true
                focus = .resume
            } else if focus == .resume || focus == .startOver {
                revealChrome(focus: .playPause)
            }
        }
        .onChange(of: currentTime) { _, time in subtitleOverlay.update(time: time) }
        .onChange(of: isPlaying) { _, playing in
            if playing { scheduleChromeHideIfNeeded() } else { revealChrome() }
        }
        .onChange(of: isBuffering) { _, buffering in if buffering { revealChrome() } else { scheduleChromeHideIfNeeded() } }
        .onChange(of: diagnostics) { _, snapshot in
            if snapshot == nil { scheduleChromeHideIfNeeded() } else { hideChromeTask?.cancel() }
        }
        .onChange(of: focus) { _, target in
            guard target != nil, target != .surface else { return }
            revealChrome()
        }
        .onChange(of: exitRequestID) { _, _ in handleExitCommand() }
        .onPlayPauseCommand { togglePlayback() }
        .onTapGesture { togglePlayback() }
        .onMoveCommand(perform: handleMove)
    }

    private var coverFlowLayer: some View {
        Button(action: playSelectedCover) {
            MediaCoverFlowPanel(
                items: coordinator.siblingMedia,
                state: coordinator.siblingMediaState,
                selectedIndex: coverFlowIndex,
                nowPlayingPath: coordinator.nowPlayingPath,
                isPlaying: isPlaying,
                folderTitle: coverFlowFolderTitle
            )
        }
        .buttonStyle(CoverFlowSurfaceButtonStyle())
        .focused($focus, equals: .coverFlow)
        .onMoveCommand(perform: handleCoverFlowMove)
        // Never more than half the screen, anchored to the bottom edge.
        .containerRelativeFrame(.vertical, alignment: .bottom) { height, _ in height * 0.5 }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityIdentifier("player.cover-flow")
        .accessibilityLabel(selectedCover?.name ?? "Folder")
        .accessibilityValue(coordinator.siblingMedia.isEmpty ? "" : "\(coverFlowIndex + 1) of \(coordinator.siblingMedia.count)")
    }

    private var chromeBackdrop: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.72), location: 0),
                    .init(color: .black.opacity(0.0), location: 0.28),
                    .init(color: .black.opacity(0.0), location: 0.52),
                    .init(color: .black.opacity(0.86), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            if presentedPanel != nil || coordinator.isTerminalFailure {
                Color.black.opacity(0.35)
            }
        }
        .allowsHitTesting(false)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            transportDock
        }
        .padding(.horizontal, 88)
        .padding(.top, 60)
        .padding(.bottom, 64)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            Button(action: close) {
                Label("Done", systemImage: "chevron.backward")
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 64))
            .focused($focus, equals: .close)
            .accessibilityIdentifier("player.done")
            .accessibilityLabel("Done")

            VStack(alignment: .leading, spacing: 6) {
                Text(coordinator.nowPlayingTitle)
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(1)
                    .accessibilityIdentifier("player.now-playing-title")
                if let detail = nowPlayingDetail {
                    Text(detail)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer()
            if isBuffering || coordinator.state == .loading {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    Text(isBuffering ? "Buffering" : "Loading")
                }
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 24)
                .frame(height: 56)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isBuffering)
    }

    private var transportDock: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let prompt = coordinator.resumePrompt {
                resumePromptView(prompt)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            timeline
            HStack(spacing: 26) {
                Button(action: { performSeek(currentTime - 10) }) {
                    Label("Back 10 seconds", systemImage: "gobackward.10")
                }
                .disabled(!isSeekable)
                .focused($focus, equals: .rewind)
                .accessibilityIdentifier("player.seek-backward-10")

                Button(action: togglePlayback) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(GlassIconButtonStyle(diameter: 92))
                .focused($focus, equals: .playPause)
                .accessibilityIdentifier("player.play-pause")
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button(action: { performSeek(currentTime + 10) }) {
                    Label("Forward 10 seconds", systemImage: "goforward.10")
                }
                .disabled(!isSeekable)
                .focused($focus, equals: .forward)
                .accessibilityIdentifier("player.seek-forward-10")

                Spacer(minLength: 20)

                if hasSubtitleOptions {
                    Button(action: { openPanel(.subtitles) }) { Label("Subtitles", systemImage: isOffSelected ? "captions.bubble" : "captions.bubble.fill") }
                        .buttonStyle(GlassIconButtonStyle(isActive: !isOffSelected))
                        .focused($focus, equals: .subtitles)
                        .accessibilityIdentifier("player.subtitles")
                }
                if audioTracks.count > 1 {
                    Button(action: { openPanel(.audio) }) { Label("Audio", systemImage: "speaker.wave.2.fill") }
                        .focused($focus, equals: .audio)
                        .accessibilityIdentifier("player.audio")
                        .accessibilityValue(selectedAudioTitle)
                }
                Button(action: coordinator.toggleAutoPlay) {
                    Label("Autoplay next", systemImage: "forward.end.alt.fill")
                }
                .buttonStyle(GlassIconButtonStyle(isActive: coordinator.isAutoPlayEnabled))
                .overlay(alignment: .top) {
                    AutoplayFeedbackView(coordinator: coordinator)
                        .offset(y: -58)
                }
                .focused($focus, equals: .autoplay)
                .accessibilityIdentifier("player.autoplay-toggle")
                .accessibilityLabel("Autoplay next")
                .accessibilityValue(autoPlayAccessibilityValue)

                Button(action: { setDiagnosticsEnabled(diagnostics == nil) }) { Label("Diagnostics", systemImage: "waveform.path.ecg") }
                    .buttonStyle(GlassIconButtonStyle(isActive: diagnostics != nil))
                    .focused($focus, equals: .diagnostics)
                    .accessibilityIdentifier("player.diagnostics-toggle")
                    .accessibilityLabel("Stats for Nerds")
            }
            .buttonStyle(GlassIconButtonStyle())
            .focusSection()
        }
        .animation(.easeOut(duration: 0.25), value: coordinator.resumePrompt != nil)
    }

    private func resumePromptView(_ prompt: PlaybackResumePrompt) -> some View {
        HStack(spacing: 36) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(prompt.secondsRemaining) / 5)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: prompt.secondsRemaining)
                Text("\(prompt.secondsRemaining)")
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 78, height: 78)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Resume from \(PlaybackPresentation.resumeTimeText(prompt.position))")
                    .font(.system(size: 32, weight: .semibold))
                    .monospacedDigit()
                Text("Otherwise playback starts from the beginning.")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 24)

            HStack(spacing: 22) {
                Button("Continue") { coordinator.resumeFromSavedPosition() }
                    .buttonStyle(PillButtonStyle(prominence: .primary))
                    .focused($focus, equals: .resume)
                    .accessibilityIdentifier("player.resume")
                Button("Start from beginning") { coordinator.startFromBeginning() }
                    .buttonStyle(PillButtonStyle())
                    .focused($focus, equals: .startOver)
                    .accessibilityIdentifier("player.start-over")
            }
            .focusSection()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .glassPanel(cornerRadius: 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.resume-prompt")
        .accessibilityValue("\(prompt.secondsRemaining) seconds remaining")
    }

    private var timeline: some View {
        let isFocused = focus == .timeline
        return VStack(spacing: 14) {
            PlaybackTimeline(
                currentTime: displayTime,
                bufferedTime: bufferedTime,
                duration: duration,
                isBuffering: isBuffering,
                isScrubbing: scrubTarget != nil,
                isFocused: isFocused,
                scrubLabel: scrubTarget.map { timeText($0) }
            )
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("player.progress")

            HStack {
                Text(timeText(displayTime))
                    .accessibilityIdentifier("player.current-time")
                Spacer()
                Text("−\(timeText(max(0, duration - displayTime)))")
            }
            .font(.system(size: 24, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(isFocused ? 0.95 : 0.7))
        }
        .contentShape(Rectangle())
        .focusable(isSeekable)
        .focused($focus, equals: .timeline)
        .focusEffectDisabled()
        .onTapGesture { commitScrub() }
        .animation(Theme.focusSpring, value: isFocused)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("player.timeline")
        .accessibilityLabel("Playback timeline")
        .accessibilityValue("\(timeText(displayTime)) of \(timeText(duration))")
    }

    @ViewBuilder
    private func trackPanel(_ panel: PresentedPanel) -> some View {
        let isSubtitles = panel == .subtitles
        VStack(alignment: .leading, spacing: 24) {
            panelHeader(isSubtitles ? "Subtitles" : "Audio") {
                Button("Close") { dismissPanel() }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("player.track-panel-close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if isSubtitles {
                        Button {
                            presentedPanel = .subtitleAppearance
                            focus = .appearanceFont
                        } label: {
                            PanelRowLabel(
                                icon: "textformat",
                                title: "Subtitle Appearance",
                                detail: "\(subtitleAppearance.font.title) · \(subtitleAppearance.color.title) · \(subtitleAppearance.opacity.title)",
                                trailingIcon: "chevron.right"
                            )
                        }
                        .buttonStyle(RowButtonStyle())
                        .focused($focus, equals: .appearance)
                        .accessibilityIdentifier("player.subtitle-appearance")
                        .accessibilityValue("\(subtitleAppearance.font.title), \(subtitleAppearance.color.title), \(subtitleAppearance.opacity.title)")

                        sectionLabel("Track")

                        trackRow(title: "Off", detail: nil, selected: isOffSelected) {
                            Task { await coordinator.selectSubtitle(.off) }
                            dismissPanel()
                        }
                        ForEach(embeddedSubtitleTracks) { track in
                            trackRow(title: trackLabel(track), detail: "Embedded", selected: isEmbeddedSubtitleSelected(track.id)) {
                                Task { await coordinator.selectSubtitle(.embedded(trackID: track.id)) }
                                dismissPanel()
                            }
                        }
                        if coordinator.externalSubtitleDiscoveryState == .loading {
                            HStack(spacing: 16) {
                                ProgressView().controlSize(.small)
                                Text("Looking for subtitle files…")
                            }
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                        }
                        ForEach(coordinator.externalSubtitles) { option in
                            trackRow(title: option.title, detail: "External file", selected: isExternalSubtitleSelected(option.id)) {
                                Task { await coordinator.selectSubtitle(.external(fileID: option.id)) }
                                dismissPanel()
                            }
                        }
                        if case .failed = coordinator.externalSubtitleDiscoveryState {
                            Button("Retry external subtitles") { coordinator.retryExternalSubtitleDiscovery() }
                                .buttonStyle(PillButtonStyle())
                                .padding(.top, 12)
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
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
        }
        .padding(44)
        .frame(width: 780)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 44)
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isSubtitles ? "player.subtitle-panel" : "player.audio-panel")
    }

    private var subtitleAppearancePanel: some View {
        VStack(alignment: .leading, spacing: 30) {
            panelHeader("Subtitle Appearance") {
                HStack(spacing: 18) {
                    Button("Reset") { updateSubtitleAppearance(.default) }
                        .buttonStyle(PillButtonStyle())
                        .focused($focus, equals: .appearanceReset)
                        .accessibilityIdentifier("player.subtitle-appearance-reset")
                    Button("Back", action: dismissAppearance)
                        .buttonStyle(PillButtonStyle())
                        .focused($focus, equals: .appearanceBack)
                        .accessibilityIdentifier("player.subtitle-appearance-close")
                }
            }
            .focusSection()

            subtitlePreview

            appearanceSection("Font") {
                ForEach(SubtitleAppearance.FontChoice.allCases) { choice in
                    appearanceChoice(
                        title: choice.title,
                        selected: subtitleAppearance.font == choice,
                        identifier: "player.subtitle-font.\(choice.rawValue)",
                        focusTarget: subtitleAppearance.font == choice ? .appearanceFont : nil
                    ) {
                        updateSubtitleAppearance(SubtitleAppearance(font: choice, color: subtitleAppearance.color, opacity: subtitleAppearance.opacity))
                    }
                }
            }
            appearanceSection("Text Color") {
                ForEach(SubtitleAppearance.ColorChoice.allCases) { choice in
                    appearanceChoice(
                        title: choice.title,
                        selected: subtitleAppearance.color == choice,
                        identifier: "player.subtitle-color.\(choice.rawValue)",
                        swatch: choice.previewColor
                    ) {
                        updateSubtitleAppearance(SubtitleAppearance(font: subtitleAppearance.font, color: choice, opacity: subtitleAppearance.opacity))
                    }
                }
            }
            appearanceSection("Opacity") {
                ForEach(SubtitleAppearance.OpacityChoice.allCases) { choice in
                    appearanceChoice(
                        title: choice.title,
                        selected: subtitleAppearance.opacity == choice,
                        identifier: "player.subtitle-opacity.\(choice.rawValue)"
                    ) {
                        updateSubtitleAppearance(SubtitleAppearance(font: subtitleAppearance.font, color: subtitleAppearance.color, opacity: choice))
                    }
                }
            }
        }
        .padding(48)
        .frame(width: 1080, alignment: .topLeading)
        .glassPanel(cornerRadius: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.subtitle-appearance-panel")
    }

    private var subtitlePreview: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.24, blue: 0.40), Color(red: 0.36, green: 0.28, blue: 0.30), Color(red: 0.08, green: 0.08, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text("This is how subtitles will look.")
                .font(subtitleAppearance.font.previewFont.weight(.semibold))
                .foregroundStyle(subtitleAppearance.color.previewColor.opacity(subtitleAppearance.opacity.fraction))
                .shadow(color: .black.opacity(0.9), radius: 3, y: 2)
                .padding(.bottom, 28)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityLabel("Subtitle preview")
        .animation(.easeOut(duration: 0.2), value: subtitleAppearance)
    }

    private func panelHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 44, weight: .bold))
            Spacer(minLength: 24)
            trailing()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 21, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 6)
    }

    private func appearanceSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 21, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.tertiaryText)
            HStack(spacing: 16) { content() }
                .focusSection()
        }
    }

    private func appearanceChoice(title: String, selected: Bool, identifier: String, swatch: Color? = nil, focusTarget: FocusTarget? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let swatch {
                    Circle().fill(swatch).frame(width: 24, height: 24).overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                }
                Text(title)
            }
        }
        .buttonStyle(ChoiceChipButtonStyle(isSelected: selected))
        .focused($focus, equals: focusTarget ?? .panelItem)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(selected ? "selected" : "not selected")
    }

    private func trackRow(title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PanelRowLabel(icon: selected ? "checkmark" : nil, title: title, detail: detail, trailingIcon: nil, reservesIconSpace: true)
        }
        .buttonStyle(RowButtonStyle())
        // The selected row carries `.panel`, so opening a panel lands on it.
        .focused($focus, equals: selected ? .panel : .panelItem)
        .accessibilityLabel((selected ? "✓ " : "") + title)
        .accessibilityValue(selected ? "selected" : "")
    }

    private func failureCard(message: String) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.35))
            Text("Playback unavailable")
                .font(.system(size: 44, weight: .bold))
            Text(message)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 22) {
                Button("Try Again") { coordinator.retryPlayback() }
                    .buttonStyle(PillButtonStyle(prominence: .primary))
                    .accessibilityIdentifier("player.retry")
                Button("Done") { close() }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("player.failure-done")
            }
            .padding(.top, 14)
        }
        .padding(56)
        .frame(width: 820)
        .glassPanel(cornerRadius: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.failure")
    }

    private var displayTime: TimeInterval { scrubTarget ?? currentTime }
    private var nowPlayingDetail: String? {
        guard let path = coordinator.nowPlayingPath else { return nil }
        let parent = AListPath.parent(of: path)
        return parent == "/" ? "Home" : parent.split(separator: "/").joined(separator: "  ›  ")
    }
    private var selectedAudioTitle: String { audioTracks.first(where: \.isSelected)?.title ?? "Audio" }
    private var autoPlayAccessibilityValue: String {
        let state = coordinator.isAutoPlayEnabled ? "On" : "Off"
        guard let feedback = coordinator.autoPlayFeedback else { return state }
        return "\(state) · \(feedback)"
    }
    // SRT/ASS files render in the overlay, not the player, so the player alone
    // cannot tell whether subtitles are off; the coordinator's choice must agree.
    private var isOffSelected: Bool {
        coordinator.subtitleSelection == .off && selectedExternalSubtitleID == nil && !embeddedSubtitleTracks.contains(where: \.isSelected)
    }
    private func isEmbeddedSubtitleSelected(_ id: String) -> Bool { selectedExternalSubtitleID == nil && embeddedSubtitleTracks.first(where: { $0.id == id })?.isSelected == true }
    private func isExternalSubtitleSelected(_ id: String) -> Bool {
        selectedExternalSubtitleID == id || coordinator.subtitleSelection == .external(fileID: id)
    }

    private var shouldInterceptSelect: Bool {
        if focus == .timeline && scrubTarget != nil { return true }
        return !chromeVisible && presentedPanel == nil && diagnostics == nil && coordinator.resumePrompt == nil && !isCoverFlowVisible
    }

    private func togglePlayback() {
        guard coordinator.resumePrompt == nil else { return }
        isPlaying ? pause() : play()
        if isCoverFlowVisible {
            scheduleCoverFlowIdleClose()
        } else {
            revealChrome()
        }
    }

    // MARK: Cover Flow

    private var selectedCover: AListObject? {
        coordinator.siblingMedia.indices.contains(coverFlowIndex) ? coordinator.siblingMedia[coverFlowIndex] : nil
    }

    private var nowPlayingCoverIndex: Int? {
        guard let path = coordinator.nowPlayingPath.map(AListPath.normalize) else { return nil }
        return coordinator.siblingMedia.firstIndex { $0.virtualPath.map(AListPath.normalize) == path }
    }

    private var coverFlowFolderTitle: String {
        guard let path = coordinator.nowPlayingPath else { return "Folder" }
        let parent = AListPath.parent(of: path)
        return parent == "/" ? "Home" : (parent.split(separator: "/").last.map(String.init) ?? "Folder")
    }

    private var canOpenCoverFlow: Bool {
        presentedPanel == nil && coordinator.resumePrompt == nil && !coordinator.isTerminalFailure && coordinator.nowPlayingPath != nil
    }

    /// Down from the video or the bottom transport row opens the shelf; down
    /// from the header or timeline keeps its usual focus movement.
    private func opensCoverFlow(from target: FocusTarget?) -> Bool {
        switch target {
        case nil, .surface, .playPause, .rewind, .forward, .subtitles, .audio, .autoplay, .diagnostics: true
        default: false
        }
    }

    private func openCoverFlow() {
        guard canOpenCoverFlow, !isCoverFlowVisible else { return }
        coordinator.loadSiblingMedia()
        coverFlowIndex = nowPlayingCoverIndex ?? 0
        hideChromeTask?.cancel()
        scrubTarget = nil
        touchScrubOrigin = nil
        chromeVisible = false
        isCoverFlowVisible = true
        focus = .coverFlow
        scheduleCoverFlowIdleClose()
    }

    private func closeCoverFlow() {
        guard isCoverFlowVisible else { return }
        coverFlowIdleTask?.cancel()
        coverFlowPanOrigin = nil
        isCoverFlowVisible = false
        focus = .surface
    }

    private func moveCoverFlow(to index: Int) {
        let count = coordinator.siblingMedia.count
        guard count > 0 else { return }
        coverFlowIndex = min(max(0, index), count - 1)
        scheduleCoverFlowIdleClose()
    }

    private func handleCoverFlowMove(_ direction: MoveCommandDirection) {
        // A swipe already scrolled the shelf through the pan handler; ignore the
        // focus engine's echo of that same gesture.
        let isSwipeEcho = coverFlowPanOrigin != nil || coverFlowPanMovedAt.map { Date().timeIntervalSince($0) < 0.4 } == true
        switch direction {
        case .left: if !isSwipeEcho { moveCoverFlow(to: coverFlowIndex - 1) }
        case .right: if !isSwipeEcho { moveCoverFlow(to: coverFlowIndex + 1) }
        case .up: closeCoverFlow()
        default: scheduleCoverFlowIdleClose()
        }
    }

    /// Touch-surface swipes scroll the shelf continuously, one cover per stride.
    private func handleCoverFlowPan(_ translation: CGPoint) {
        if coverFlowPanOrigin == nil {
            // Ignore the incidental touch of a clickpad press.
            guard abs(translation.x) >= 24, abs(translation.x) >= abs(translation.y) else { return }
            coverFlowPanOrigin = coverFlowIndex
        }
        guard let origin = coverFlowPanOrigin else { return }
        let steps = Int((translation.x / 140).rounded(.towardZero))
        if origin + steps != coverFlowIndex {
            moveCoverFlow(to: origin + steps)
            coverFlowPanMovedAt = Date()
        }
    }

    private func handleCoverFlowPanEnded(_ translation: CGPoint) {
        defer { coverFlowPanOrigin = nil }
        if coverFlowPanOrigin == nil, translation.y < -80, abs(translation.y) > abs(translation.x) {
            closeCoverFlow()
        }
    }

    private func playSelectedCover() {
        switch coordinator.siblingMediaState {
        case .failed:
            coordinator.loadSiblingMedia()
            scheduleCoverFlowIdleClose()
            return
        default:
            break
        }
        guard let item = selectedCover else { return }
        closeCoverFlow()
        coordinator.playSibling(item)
        // Briefly surface the title so the switch is confirmed on screen.
        revealChrome(focus: .playPause)
    }

    private func scheduleCoverFlowIdleClose() {
        coverFlowIdleTask?.cancel()
        coverFlowIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            closeCoverFlow()
        }
    }

    private func handleInterceptedDirection(_ direction: MoveCommandDirection) {
        if direction == .down, canOpenCoverFlow {
            openCoverFlow()
        } else {
            revealChrome(focus: .playPause)
        }
    }

    private func performSeek(_ seconds: TimeInterval) {
        seek(PlaybackPresentation.clampedSeekTarget(seconds, duration: duration))
        scrubTarget = nil
        touchScrubOrigin = nil
        revealChrome()
    }

    private func commitScrub() {
        guard let scrubTarget else { return }
        let target = PlaybackPresentation.clampedSeekTarget(scrubTarget, duration: duration)
        self.scrubTarget = nil
        touchScrubOrigin = nil
        if isPlaying {
            seek(target)
        } else {
            seekAndPlay(target)
        }
        revealChrome()
    }

    private func handleTouchPanChanged(_ translation: CGPoint) {
        if isCoverFlowVisible {
            handleCoverFlowPan(translation)
            return
        }
        if panOriginFocus == nil { panOriginFocus = .some(focus) }
        guard presentedPanel == nil, coordinator.resumePrompt == nil else { return }
        guard max(abs(translation.x), abs(translation.y)) >= 24 else { return }
        guard abs(translation.x) > abs(translation.y), isSeekable else { return }
        guard !isPlaying else { return }
        if touchScrubOrigin == nil {
            touchScrubOrigin = scrubTarget ?? currentTime
        }
        guard let origin = touchScrubOrigin else { return }
        scrubTarget = PlaybackPresentation.scrubTarget(
            currentTime: origin,
            horizontalTranslation: Double(translation.x),
            duration: duration
        )
        focus = .timeline
        revealChrome()
    }

    private func handleTouchPanEnded(_ translation: CGPoint) {
        let originFocus = panOriginFocus ?? focus
        panOriginFocus = nil
        if isCoverFlowVisible {
            handleCoverFlowPanEnded(translation)
            return
        }
        defer { touchScrubOrigin = nil }
        guard presentedPanel == nil, coordinator.resumePrompt == nil else { return }
        guard max(abs(translation.x), abs(translation.y)) >= 24 else { return }
        if scrubTarget != nil {
            focus = .timeline
            revealChrome()
            return
        }
        let direction: MoveCommandDirection
        if abs(translation.x) > abs(translation.y) {
            direction = translation.x > 0 ? .right : .left
        } else {
            direction = translation.y > 0 ? .down : .up
        }
        if direction == .down, canOpenCoverFlow {
            // Judge by where the swipe began: the focus engine may already have
            // moved focus down into the transport row during the gesture.
            if opensCoverFlow(from: originFocus) { openCoverFlow() }
            return
        }
        handleMove(direction)
    }

    private func handleSelectCommand() {
        if focus == .timeline, scrubTarget != nil {
            commitScrub()
        } else if !chromeVisible && presentedPanel == nil && diagnostics == nil && coordinator.resumePrompt == nil {
            togglePlayback()
        }
    }

    private func openPanel(_ panel: PresentedPanel) { presentedPanel = panel; hideChromeTask?.cancel(); chromeVisible = true; focus = .panel }
    private func dismissAppearance() {
        presentedPanel = .subtitles
        focus = .appearance
    }

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

        if isCoverFlowVisible {
            closeCoverFlow()
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
        chromeVisible = false
        focus = .surface
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        guard !isCoverFlowVisible else { return }
        if direction == .down, canOpenCoverFlow, opensCoverFlow(from: focus) {
            openCoverFlow()
            return
        }
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
        // The shelf owns the screen while open; transport chrome stays tucked away.
        guard !isCoverFlowVisible else { return }
        hideChromeTask?.cancel()
        chromeVisible = true
        if let target { focus = target }
        scheduleChromeHideIfNeeded()
    }

    private func scheduleChromeHideIfNeeded() {
        hideChromeTask?.cancel()
        guard isPlaying, !isBuffering, presentedPanel == nil, diagnostics == nil, !coordinator.isTerminalFailure else { return }
        hideChromeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isPlaying, !isBuffering, presentedPanel == nil, diagnostics == nil, !coordinator.isTerminalFailure else { return }
            chromeVisible = false
            focus = .surface
        }
    }
}

private struct AutoplayFeedbackView: View {
    @ObservedObject var coordinator: PlayerCoordinator

    var body: some View {
        Group {
            if let feedback = coordinator.autoPlayFeedback {
                Text("Autoplay \(feedback)")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(0.8)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(feedback)
                    .accessibilityIdentifier("player.autoplay-feedback")
            }
        }
        .animation(.easeOut(duration: 0.2), value: coordinator.autoPlayFeedback)
        .allowsHitTesting(false)
    }
}

private struct PanelRowLabel: View {
    let icon: String?
    let title: String
    let detail: String?
    let trailingIcon: String?
    var reservesIconSpace = false
    @Environment(\.rowIsFocused) private var isFocused

    var body: some View {
        HStack(spacing: 20) {
            if icon != nil || reservesIconSpace {
                Image(systemName: icon ?? "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(isFocused ? Color.black : Theme.accent)
                    .opacity(icon == nil ? 0 : 1)
                    .frame(width: 32)
            }
            VStack(alignment: .leading, spacing: 4) {
                // Long names (e.g. subtitle files) scroll into view while focused.
                MarqueeText(text: title, font: .system(size: 29, weight: .semibold), isActive: isFocused)
                if let detail {
                    Text(detail)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isFocused ? Color.black.opacity(0.5) : Color.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.black.opacity(0.5) : Color.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
    }
}

private struct ChoiceChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isSelected: isSelected)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isFocused ? Color.black : .white)
                .padding(.horizontal, 28)
                .frame(height: 64)
                .background(Capsule().fill(isFocused ? Color.white : (isSelected ? Theme.accent.opacity(0.45) : Theme.surfaceRaised)))
                .overlay(Capsule().strokeBorder(isSelected && !isFocused ? Theme.accent : .clear, lineWidth: 2))
                .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 14, y: 8)
                .animation(Theme.focusSpring, value: isFocused)
                .animation(.easeOut(duration: 0.15), value: isSelected)
        }
    }
}

private struct SubtitleOverlayView: View {
    let text: String?
    let appearance: SubtitleAppearance

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(appearance.font.previewFont.weight(.semibold))
                    .foregroundStyle(appearance.color.previewColor.opacity(appearance.opacity.fraction))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.95), radius: 3, x: 0, y: 2)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 80)
                    .padding(.bottom, 96)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PlaybackTimeline: View {
    let currentTime: TimeInterval
    let bufferedTime: TimeInterval
    let duration: TimeInterval
    let isBuffering: Bool
    let isScrubbing: Bool
    let isFocused: Bool
    let scrubLabel: String?

    private var playedFraction: Double { PlaybackPresentation.clampedProgressFraction(currentTime, duration: duration) }
    private var bufferedFraction: Double { max(playedFraction, PlaybackPresentation.clampedProgressFraction(bufferedTime, duration: duration)) }
    private var trackHeight: CGFloat { isFocused ? 14 : 8 }
    private var knobSize: CGFloat { isScrubbing ? 30 : (isFocused ? 24 : 0) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let playhead = width * playedFraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.32)).frame(width: width * bufferedFraction)
                Capsule().fill(.white).frame(width: max(trackHeight, playhead))
            }
            .frame(height: trackHeight)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    .offset(x: min(max(0, playhead - knobSize / 2), width - knobSize))
            }
            .overlay(alignment: .topLeading) {
                if let scrubLabel {
                    Text(scrubLabel)
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.white, in: Capsule())
                        .fixedSize()
                        .alignmentGuide(.leading) { $0.width / 2 }
                        .offset(x: min(max(70, playhead), width - 70), y: -64)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(Theme.focusSpring, value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
        .accessibilityValue(isBuffering ? "Buffering" : "\(Int((playedFraction * 100).rounded())) percent played")
    }
}

private struct PlaybackDiagnosticsPanel: View {
    let snapshot: PlaybackDiagnosticsSnapshot
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Stats for Nerds").font(.system(size: 32, weight: .bold))
                Spacer()
                Button("Close", action: close).buttonStyle(PillButtonStyle())
            }
            group("Playback", [
                ("Time", time(snapshot.currentTime) + " / " + time(snapshot.duration)),
                ("Playing", snapshot.isPlaying ? "Yes" : "No"),
                ("Seekable", snapshot.isSeekable ? "Yes" : "No")
            ])
            group("Network", [
                ("Input", bytes(snapshot.inputBytesRead) + " · " + bitrate(snapshot.inputBitrate)),
                ("Demux", bytes(snapshot.demuxBytesRead) + " · " + bitrate(snapshot.demuxBitrate)),
                ("Errors", "\(snapshot.demuxCorrupted) corrupt · \(snapshot.demuxDiscontinuity) discontinuities")
            ])
            group("Video", [
                ("Track", "\(snapshot.videoResolution ?? "—") · \(frameRate(snapshot.videoFrameRate)) · \(snapshot.videoCodec ?? "—")"),
                ("Frames", "\(snapshot.decodedVideo) decoded · \(snapshot.displayedPictures) shown · \(snapshot.latePictures) late")
            ])
            group("Audio & Subtitles", [
                ("Audio", metadata(snapshot.audioTitle, snapshot.audioLanguageCode, snapshot.audioCodec)),
                ("Subtitle", metadata(snapshot.subtitleTitle, snapshot.subtitleLanguageCode, snapshot.subtitleCodec))
            ])
        }
        .font(.system(size: 22, weight: .medium).monospacedDigit())
        .frame(width: 720, alignment: .leading)
        .padding(36)
        .glassPanel(cornerRadius: 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.diagnostics")
    }

    private func group(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 18, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 2)
            ForEach(rows, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(key).foregroundStyle(.white.opacity(0.5)).frame(width: 130, alignment: .leading)
                    Text(value).foregroundStyle(.white.opacity(0.92)).lineLimit(1).minimumScaleFactor(0.8)
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
    let onDirectional: (MoveCommandDirection) -> Void
    let onSelect: () -> Void
    let onPlayPause: () -> Void
    let onPanChanged: (CGPoint) -> Void
    let onPanEnded: (CGPoint) -> Void
    let interceptsDirectional: Bool
    let interceptsSelect: Bool
    let interceptsPlayPause: Bool

    func makeUIViewController(context: Context) -> MenuKeyCommandController {
        MenuKeyCommandController(
            onMenu: onMenu,
            onDirectional: onDirectional,
            onSelect: onSelect,
            onPlayPause: onPlayPause,
            onPanChanged: onPanChanged,
            onPanEnded: onPanEnded,
            interceptsDirectional: interceptsDirectional,
            interceptsSelect: interceptsSelect,
            interceptsPlayPause: interceptsPlayPause
        )
    }

    func updateUIViewController(_ controller: MenuKeyCommandController, context: Context) {
        controller.onMenu = onMenu
        controller.onDirectional = onDirectional
        controller.onSelect = onSelect
        controller.onPlayPause = onPlayPause
        controller.onPanChanged = onPanChanged
        controller.onPanEnded = onPanEnded
        controller.interceptsDirectional = interceptsDirectional
        controller.interceptsSelect = interceptsSelect
        controller.interceptsPlayPause = interceptsPlayPause
        controller.installPanGestureRecognizer()
        controller.claimFirstResponder()
    }
}

private final class MenuKeyCommandController: UIViewController {
    var onMenu: () -> Void
    var onDirectional: (MoveCommandDirection) -> Void
    var onSelect: () -> Void
    var onPlayPause: () -> Void
    var onPanChanged: (CGPoint) -> Void
    var onPanEnded: (CGPoint) -> Void
    var interceptsDirectional: Bool
    var interceptsSelect: Bool
    var interceptsPlayPause: Bool
    private var panGestureRecognizer: UIPanGestureRecognizer?

    init(onMenu: @escaping () -> Void, onDirectional: @escaping (MoveCommandDirection) -> Void, onSelect: @escaping () -> Void, onPlayPause: @escaping () -> Void, onPanChanged: @escaping (CGPoint) -> Void, onPanEnded: @escaping (CGPoint) -> Void, interceptsDirectional: Bool, interceptsSelect: Bool, interceptsPlayPause: Bool) {
        self.onMenu = onMenu
        self.onDirectional = onDirectional
        self.onSelect = onSelect
        self.onPlayPause = onPlayPause
        self.onPanChanged = onPanChanged
        self.onPanEnded = onPanEnded
        self.interceptsDirectional = interceptsDirectional
        self.interceptsSelect = interceptsSelect
        self.interceptsPlayPause = interceptsPlayPause
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installPanGestureRecognizer()
        claimFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removePanGestureRecognizer()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            onPanChanged(translation)
        case .ended, .cancelled, .failed:
            onPanEnded(translation)
        default:
            break
        }
    }

    fileprivate func installPanGestureRecognizer() {
        guard panGestureRecognizer == nil, let window = view.window else { return }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.cancelsTouchesInView = false
        window.addGestureRecognizer(recognizer)
        panGestureRecognizer = recognizer
    }

    private func removePanGestureRecognizer() {
        guard let recognizer = panGestureRecognizer else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
        panGestureRecognizer = nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onMenu()
            return
        }
        if interceptsSelect, presses.contains(where: { $0.type == .select }) {
            onSelect()
            return
        }
        if interceptsPlayPause, presses.contains(where: { $0.type == .playPause }) {
            onPlayPause()
            return
        }
        if interceptsDirectional, let direction = presses.lazy.compactMap(Self.direction(of:)).first {
            onDirectional(direction)
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

    private static func direction(of press: UIPress) -> MoveCommandDirection? {
        switch press.type {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        default: nil
        }
    }
}


/// The Cover Flow shelf draws its own focus treatment, so its button wrapper
/// adds none of the system lift or highlight.
private struct CoverFlowSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
