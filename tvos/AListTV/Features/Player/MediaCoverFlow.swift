import SwiftUI

/// Floating Cover Flow shelf of the playable files that share the current
/// item's folder. It is purely presentational: the player stage owns focus,
/// remote input and the selected index, so playback is never interrupted.
struct MediaCoverFlowPanel: View {
    let items: [AListObject]
    let state: PlayerCoordinator.SiblingMediaState
    let selectedIndex: Int
    let nowPlayingPath: String?
    let isPlaying: Bool
    let folderTitle: String

    static let coverSide: CGFloat = 250
    private static let visibleRadius = 7

    private var selectedItem: AListObject? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.screenPadding + 8)
            ZStack {
                stageLight
                content
            }
            .frame(height: Self.coverSide * 1.24)
            .padding(.top, 26)
            caption
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 4)
        }
        .padding(.top, 54)
        .padding(.bottom, 46)
        .frame(maxWidth: .infinity)
        .background { backdrop }
    }

    // MARK: Layers

    private var backdrop: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.32)], startPoint: .top, endPoint: .bottom))
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.35),
                    .init(color: .black.opacity(0.88), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    /// Soft pool of light behind the centered cover, tinted by its artwork.
    private var stageLight: some View {
        let tint = selectedItem.map { CoverArtPalette(item: $0).glow } ?? Theme.accent
        return Ellipse()
            .fill(RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0)], center: .center, startRadius: 0, endRadius: Self.coverSide * 1.35))
            .frame(width: Self.coverSide * 3.2, height: Self.coverSide * 1.5)
            .offset(y: -Self.coverSide * 0.08)
            .blur(radius: 30)
            .animation(.easeInOut(duration: 0.45), value: selectedIndex)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: "square.stack.3d.down.forward.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(folderTitle.uppercased())
                .font(.system(size: 22, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            Spacer(minLength: 24)
            if !items.isEmpty {
                Text("\(min(selectedIndex + 1, items.count)) / \(items.count)")
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: selectedIndex)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .failed(let message):
            statusMessage(icon: "exclamationmark.triangle.fill", text: message, detail: "Press Select to try again.")
        case .loaded where items.isEmpty:
            statusMessage(icon: "tray", text: "No other media in this folder.", detail: nil)
        case .idle:
            placeholderShelf
        case .loading where items.isEmpty:
            placeholderShelf
        default:
            shelf
        }
    }

    private var shelf: some View {
        let lower = max(0, selectedIndex - Self.visibleRadius)
        let upper = min(items.count - 1, selectedIndex + Self.visibleRadius)
        return ZStack {
            if lower <= upper {
                ForEach(lower...upper, id: \.self) { index in
                    let item = items[index]
                    CoverFlowCard(item: item, isNowPlaying: isNowPlaying(item), isPlaying: isPlaying, isCentered: index == selectedIndex)
                        .modifier(CoverFlowPlacement(position: Double(index - selectedIndex), side: Self.coverSide))
                        .zIndex(-Double(abs(index - selectedIndex)))
                        .accessibilityIdentifier("player.cover-flow.item.\(item.id)")
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: selectedIndex)
        .frame(maxWidth: .infinity)
    }

    private var placeholderShelf: some View {
        ZStack {
            ForEach(-3...3, id: \.self) { offset in
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    .frame(width: Self.coverSide, height: Self.coverSide)
                    .frame(height: Self.coverSide * 1.24, alignment: .top)
                    .modifier(CoverFlowPlacement(position: Double(offset), side: Self.coverSide))
                    .zIndex(-Double(abs(offset)))
            }
            ProgressView()
                .offset(y: -Self.coverSide * 0.12)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusMessage(icon: String, text: String, detail: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.5))
            Text(text)
                .font(.system(size: 28, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var caption: some View {
        VStack(spacing: 8) {
            Text(selectedItem.map { CoverArtPalette.displayTitle(for: $0.name) } ?? " ")
                .font(.system(size: 32, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            HStack(spacing: 12) {
                if let item = selectedItem, isNowPlaying(item) {
                    Label(isPlaying ? "Now Playing" : "Paused", systemImage: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .foregroundStyle(Theme.accent)
                } else if selectedItem != nil {
                    Label("Select to play", systemImage: "play.fill")
                        .foregroundStyle(.white.opacity(0.62))
                }
                if let detail = selectedItem.map(detailText) {
                    Text("·").foregroundStyle(Theme.tertiaryText)
                    Text(detail).foregroundStyle(Theme.secondaryText)
                }
            }
            .font(.system(size: 22, weight: .semibold))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .opacity(selectedItem == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: selectedIndex)
    }

    private func detailText(_ item: AListObject) -> String {
        let badge = BrowserFileBadge(item: item)
        var parts = [badge.kind == .audio ? "Audio" : "Video"]
        if let ext = badge.displayExtension { parts.append(ext) }
        if item.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    private func isNowPlaying(_ item: AListObject) -> Bool {
        guard let nowPlayingPath, let path = item.virtualPath else { return false }
        return AListPath.normalize(path) == AListPath.normalize(nowPlayingPath)
    }
}

/// Places a card along the classic Cover Flow curve. `position` is the signed
/// distance from the center slot; it is animatable so cards travel the curve
/// (swinging through their rotation) instead of interpolating linearly.
private struct CoverFlowPlacement: ViewModifier, Animatable {
    var position: Double
    let side: CGFloat

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let distance = abs(position)
        let swing = max(-1, min(1, position))
        let x = swing * Double(side) * 0.80 + (position - swing) * Double(side) * 0.30
        let angle = -swing * 64
        let scale = 1 - 0.16 * abs(swing)
        let dimming = min(0.62, 0.30 * abs(swing) + max(0, distance - 1) * 0.07)
        let fade = distance <= 5 ? 1 : max(0, 1 - (distance - 5) / 1.6)

        return content
            .overlay(Color.black.opacity(dimming).allowsHitTesting(false))
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.45)
            // Shrink toward the cover's base so every card stands on the same floor.
            .scaleEffect(scale, anchor: UnitPoint(x: 0.5, y: 0.8))
            .offset(x: x)
            .opacity(fade)
    }
}

/// One cover plus its mirrored reflection on the glossy floor.
private struct CoverFlowCard: View {
    let item: AListObject
    let isNowPlaying: Bool
    let isPlaying: Bool
    let isCentered: Bool

    private var side: CGFloat { MediaCoverFlowPanel.coverSide }

    var body: some View {
        VStack(spacing: 3) {
            MediaCoverArt(item: item, isNowPlaying: isNowPlaying, isPlaying: isPlaying)
                .frame(width: side, height: side)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(isNowPlaying ? Theme.accent : .white.opacity(isCentered ? 0.32 : 0.12), lineWidth: isNowPlaying ? 3 : 1)
                }
                .shadow(color: .black.opacity(isCentered ? 0.6 : 0.4), radius: isCentered ? 26 : 12, y: isCentered ? 16 : 8)

            MediaCoverArt(item: item, isNowPlaying: false, isPlaying: false)
                .frame(width: side, height: side)
                .scaleEffect(x: 1, y: -1)
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.42), location: 0), .init(color: .clear, location: 0.24)], startPoint: .top, endPoint: .bottom))
                .frame(height: side * 0.24, alignment: .top)
                .clipped()
                .accessibilityHidden(true)
        }
        .frame(width: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
    }
}

// MARK: - Artwork

/// Deterministic, code-drawn artwork: each file gets its own palette from a
/// stable hash of its name, with an episode or track marker set large like a
/// record sleeve. Server thumbnails, when present, take over the cover.
struct MediaCoverArt: View {
    let item: AListObject
    let isNowPlaying: Bool
    let isPlaying: Bool

    var body: some View {
        let palette = CoverArtPalette(item: item)
        ZStack {
            if palette.isAudio {
                VinylArt(palette: palette, item: item)
            } else {
                PosterArt(palette: palette, item: item)
            }
            if let thumbnail = item.thumbnail, let url = URL(string: thumbnail), !thumbnail.isEmpty {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom))
                    }
                }
            }
            if isNowPlaying {
                NowPlayingBadge(isPlaying: isPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct PosterArt: View {
    let palette: CoverArtPalette
    let item: AListObject

    var body: some View {
        let marker = CoverArtPalette.marker(for: item.name)
        ZStack {
            LinearGradient(colors: [palette.light, palette.deep], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Diagonal light sweep that gives the flat gradient a glossy sleeve.
            LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.30), .init(color: .white.opacity(0.16), location: 0.46), .init(color: .white.opacity(0), location: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(palette.glow.opacity(0.55))
                .frame(width: 210, height: 210)
                .blur(radius: 46)
                .offset(x: 70, y: -80)
            filmStrip
                .frame(maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                if let season = marker?.season {
                    Text("SEASON \(season)")
                        .font(.system(size: 15, weight: .heavy))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(marker?.number ?? CoverArtPalette.monogram(for: item.name))
                    .font(.system(size: marker == nil ? 112 : 104, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                Text(CoverArtPalette.displayTitle(for: item.name))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            extensionChip
        }
    }

    private var filmStrip: some View {
        HStack(spacing: 9) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.28)).frame(width: 11, height: 8)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.22))
    }

    private var extensionChip: some View {
        Group {
            if let ext = BrowserFileBadge(item: item).displayExtension {
                Text(ext)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.28), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 34)
        .padding(.trailing, 16)
    }
}

/// Audio sleeve: a vinyl record half out of a colored jacket.
private struct VinylArt: View {
    let palette: CoverArtPalette
    let item: AListObject

    var body: some View {
        let marker = CoverArtPalette.marker(for: item.name)
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                LinearGradient(colors: [palette.deep, .black], startPoint: .top, endPoint: .bottom)
                ZStack {
                    Circle().fill(Color(white: 0.06))
                    ForEach(0..<9, id: \.self) { ring in
                        Circle()
                            .strokeBorder(.white.opacity(ring.isMultiple(of: 2) ? 0.07 : 0.035), lineWidth: 1)
                            .padding(side * (0.05 + CGFloat(ring) * 0.028))
                    }
                    Circle()
                        .fill(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.16), .white.opacity(0), .white.opacity(0.12), .white.opacity(0)], center: .center))
                    Circle()
                        .fill(LinearGradient(colors: [palette.light, palette.glow], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: side * 0.34, height: side * 0.34)
                        .overlay {
                            Text(marker?.number ?? CoverArtPalette.monogram(for: item.name))
                                .font(.system(size: side * 0.12, weight: .black, design: .rounded))
                                .minimumScaleFactor(0.5)
                                .foregroundStyle(.white)
                                .padding(8)
                        }
                    Circle().fill(.black).frame(width: side * 0.03, height: side * 0.03)
                }
                .frame(width: side * 0.86, height: side * 0.86)
                .offset(x: side * 0.16, y: -side * 0.04)
                .shadow(color: .black.opacity(0.6), radius: 12, x: -6)

                Text(CoverArtPalette.displayTitle(for: item.name))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(14)
            }
        }
    }
}

private struct NowPlayingBadge: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 7) {
            EqualizerBars(isAnimating: isPlaying)
                .frame(width: 18, height: 15)
            Text(isPlaying ? "PLAYING" : "PAUSED")
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Theme.accent, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

private struct EqualizerBars: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<3, id: \.self) { bar in
                    let level = isAnimating ? 0.35 + 0.65 * abs(sin(time * (5.2 + Double(bar) * 1.7) + Double(bar))) : 0.35
                    Capsule().frame(maxHeight: .infinity, alignment: .bottom)
                        .scaleEffect(x: 1, y: level, anchor: .bottom)
                }
            }
        }
    }
}

/// Stable per-file colors and the text markers drawn on generated covers.
struct CoverArtPalette {
    let light: Color
    let deep: Color
    let glow: Color
    let isAudio: Bool

    init(item: AListObject) {
        isAudio = BrowserFileBadge(item: item).kind == .audio
        // FNV-1a: `hashValue` is randomized per launch, which would recolor covers.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Self.displayTitle(for: item.name).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hue = Double(hash % 360) / 360
        light = Color(hue: hue, saturation: 0.62, brightness: 0.78)
        deep = Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.78, brightness: 0.24)
        glow = Color(hue: (hue + 0.95).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 1)
    }

    struct Marker: Equatable {
        let season: String?
        let number: String
    }

    static func displayTitle(for name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// Pulls an episode or track number out of common naming schemes:
    /// `S01E03`, `E03`/`EP03`, `第3集`, or a leading track number such as `03 Song`.
    static func marker(for name: String) -> Marker? {
        let stem = displayTitle(for: name)
        if let match = stem.firstMatch(of: /(?i)S(\d{1,2})[ ._-]*E(\d{1,3})/) {
            return Marker(season: String(Int(match.1) ?? 0), number: padded(match.2))
        }
        if let match = stem.firstMatch(of: /(?i)(?:^|[^A-Za-z])EP?[ ._-]?(\d{1,3})(?!\d)/) {
            return Marker(season: nil, number: padded(match.1))
        }
        if let match = stem.firstMatch(of: /第\s*(\d{1,4})\s*[集话話期]/) {
            return Marker(season: nil, number: padded(match.1))
        }
        if let match = stem.firstMatch(of: /^(\d{1,3})(?!\d)/) {
            return Marker(season: nil, number: padded(match.1))
        }
        return nil
    }

    static func monogram(for name: String) -> String {
        displayTitle(for: name).first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "♪"
    }

    private static func padded(_ digits: Substring) -> String {
        let value = Int(digits) ?? 0
        return value < 10 ? String(format: "%02d", value) : String(value)
    }
}
