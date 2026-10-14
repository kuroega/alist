import SwiftUI

/// Shared visual language: near-black surfaces, one restrained accent, and
/// white focus states that read clearly from across the room.
enum Theme {
    static let accent = Color(red: 0.42, green: 0.66, blue: 1.0)
    static let canvas = Color(red: 0.035, green: 0.039, blue: 0.051)
    static let surface = Color.white.opacity(0.07)
    static let surfaceRaised = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)

    static let screenPadding: CGFloat = 80
    static let focusSpring = Animation.spring(response: 0.32, dampingFraction: 0.78)
}

/// Quiet ambient backdrop: a dark canvas with two soft light pools so large
/// empty areas never look flat.
struct AmbientBackground: View {
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 1_100)
            RadialGradient(colors: [Color.purple.opacity(0.07), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 900)
        }
        .ignoresSafeArea()
    }
}

/// Circular glass icon button. Unfocused it recedes; focused it turns solid
/// white with a dark glyph, matching system transport controls.
struct GlassIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 76
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        GlassIconButtonBody(configuration: configuration, diameter: diameter, isActive: isActive)
    }

    private struct GlassIconButtonBody: View {
        let configuration: Configuration
        let diameter: CGFloat
        let isActive: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: diameter * 0.36, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white.opacity(isActive ? 1 : 0.86))
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(isFocused ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                    if !isFocused {
                        Circle().fill(Color.white.opacity(0.08))
                    }
                    if !isFocused && isActive {
                        Circle().fill(Theme.accent.opacity(0.35))
                    }
                }
                .overlay(Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.12), lineWidth: 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
                .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.12 : 1))
                .opacity(isEnabled ? 1 : 0.35)
                .animation(Theme.focusSpring, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Capsule text button used for primary and secondary actions.
struct PillButtonStyle: ButtonStyle {
    enum Prominence { case primary, secondary }
    var prominence: Prominence = .secondary

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominence: prominence)
    }

    private struct PillButtonBody: View {
        let configuration: Configuration
        let prominence: Prominence
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isFocused ? Color.black : .white)
                .padding(.horizontal, 44)
                .frame(minHeight: 76)
                .background {
                    Capsule().fill(fill)
                }
                .overlay(Capsule().strokeBorder(.white.opacity(isFocused ? 0 : 0.10), lineWidth: 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 12)
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1))
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Theme.focusSpring, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var fill: AnyShapeStyle {
            if isFocused { return AnyShapeStyle(Color.white) }
            switch prominence {
            case .primary: return AnyShapeStyle(Theme.accent.opacity(0.55))
            case .secondary: return AnyShapeStyle(Theme.surfaceRaised)
            }
        }
    }
}

/// Full-width row for lists and option panels: transparent at rest, solid
/// white when focused so the selection is unmistakable.
struct RowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RowButtonBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : .white)
                .environment(\.rowIsFocused, isFocused)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.0001))
                )
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 10)
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.02 : 1))
                .animation(Theme.focusSpring, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

private struct RowIsFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Lets row content pick secondary colors that stay legible on the white
    /// focused background.
    var rowIsFocused: Bool {
        get { self[RowIsFocusedKey.self] }
        set { self[RowIsFocusedKey.self] = newValue }
    }
}

/// One line of text that, while `isActive` (typically focused) and too wide for
/// its space, scrolls to reveal the rest the way tvOS titles do: a pause to
/// read the start, a steady scroll to the end, a pause, then back. Otherwise it
/// truncates like a plain one-line `Text`.
struct MarqueeText: View {
    let text: String
    let font: Font
    let isActive: Bool

    @State private var availableWidth: CGFloat = 0
    @State private var fullWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private static let pointsPerSecond: CGFloat = 70
    private static let edgeFade: CGFloat = 28

    private var overflow: CGFloat { max(0, fullWidth - availableWidth) }
    private var isScrolling: Bool { isActive && overflow > 1 }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(isScrolling ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .background(alignment: .leading) {
                // Measures the untruncated width without affecting layout.
                Text(text).font(font).lineLimit(1).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .leading) {
                if isScrolling {
                    Text(text).font(font).lineLimit(1).fixedSize()
                        .offset(x: offset)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .mask {
                // Soften the edges the text scrolls across.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: isScrolling && offset < 0 ? Self.edgeFade : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: isScrolling ? Self.edgeFade : 0)
                }
            }
            .task(id: isScrolling ? overflow : 0) { await scroll() }
    }

    private func scroll() async {
        withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
        guard isScrolling else { return }
        let distance = overflow + Self.edgeFade
        let duration = Double(distance / Self.pointsPerSecond)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration + 1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { offset = 0 }
            try? await Task.sleep(for: .seconds(0.45))
        }
    }
}

/// Glass panel container used by player sheets and dialogs.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 36

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 36) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

/// App mark drawn in code so it stays crisp at any size.
struct BrandMark: View {
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent, Color(red: 0.30, green: 0.36, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.35), radius: size * 0.3, y: size * 0.1)
        .accessibilityHidden(true)
    }
}
