import SwiftUI
import UIKit

struct PlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let adapter = coordinator.controller as? VLCPlayerControllerAdapter {
                VLCPlayerContainerView(adapter: adapter)
            } else {
                VStack(spacing: 32) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 96))
                    Text("Fixture Player")
                        .font(.largeTitle)
                    Button("Done") {
                        coordinator.playerDidDisappear()
                        dismiss()
                    }
                    .accessibilityIdentifier("player.done")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if case let .failed(message) = coordinator.state {
                Text(message)
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(50)
            }
        }
        .onExitCommand {
            coordinator.playerDidDisappear()
            dismiss()
        }
        .onDisappear { coordinator.playerDidDisappear() }
    }
}

struct VLCPlayerRepresentable: UIViewRepresentable {
    let adapter: VLCPlayerControllerAdapter

    func makeUIView(context: Context) -> UIView {
        adapter.videoView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct VLCPlayerContainerView: View {
    @ObservedObject var adapter: VLCPlayerControllerAdapter
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            VLCPlayerRepresentable(adapter: adapter)

            if controlsVisible || !adapter.isPlaying {
                controls
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .focusable()
        .onAppear { revealControls() }
        .onChange(of: adapter.isPlaying) { _, isPlaying in
            if isPlaying {
                revealControls()
            } else {
                hideControlsTask?.cancel()
                controlsVisible = true
            }
        }
        .onDisappear { hideControlsTask?.cancel() }
        .onTapGesture { togglePlayback() }
        .onPlayPauseCommand { togglePlayback() }
        .onMoveCommand { direction in
            revealControls()
            guard adapter.isSeekable else { return }

            switch direction {
            case .left:
                seek(by: -10)
            case .right:
                seek(by: 10)
            default:
                break
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Image(systemName: adapter.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .frame(width: 44)
            Text(timeText(adapter.currentTime))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .leading)
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
            Text(adapter.duration > 0 ? timeText(adapter.duration) : "--:--")
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 28)
        .background(.black.opacity(0.72))
    }

    private var progressFraction: Double {
        guard adapter.duration > 0 else { return 0 }
        return min(max(adapter.currentTime / adapter.duration, 0), 1)
    }

    private func togglePlayback() {
        if adapter.isPlaying {
            adapter.pause()
        } else {
            adapter.play()
        }
        revealControls()
    }

    private func seek(by seconds: TimeInterval) {
        Task {
            await adapter.seek(to: adapter.currentTime + seconds)
        }
    }

    private func revealControls() {
        hideControlsTask?.cancel()
        controlsVisible = true
        guard adapter.isPlaying else { return }

        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, adapter.isPlaying else { return }
            controlsVisible = false
        }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
