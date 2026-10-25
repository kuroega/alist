import SwiftUI

/// Media wall: the focused title takes over the screen behind a spotlight,
/// with Watching, Genres, Unwatched, TV Shows and Movies shelves below, and
/// an Un-indexed shelf last for videos without an exact TMDB match.
struct GalleryView: View {
    @ObservedObject var viewModel: GalleryViewModel
    let onReveal: (AListObject) -> Void

    @State private var isSettingsPresented = false
    /// Shelf holding focus; it snaps under the spotlight like Apple TV rows.
    @State private var focusedShelf: String?

    var body: some View {
        content
            .onAppear {
                viewModel.onAppear()
                viewModel.focusDefault()
            }
            .onChange(of: viewModel.shelves.playEntries.first?.id) { _, _ in viewModel.focusDefault() }
            .onChange(of: viewModel.catalog.videoCount) { _, _ in viewModel.focusDefault() }
            .sheet(isPresented: $isSettingsPresented) {
                GallerySettingsView(viewModel: viewModel)
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.catalog.isEmpty {
            switch viewModel.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("gallery.loading")
            case let .scanning(progress):
                GalleryScanningView(progress: progress)
            case let .failed(message):
                emptyState(icon: "wifi.exclamationmark", title: "Couldn’t read your library", message: message, action: "Try Again", perform: viewModel.updateLibrary)
            case .idle, .ready:
                emptyState(
                    icon: "film.stack",
                    title: "No videos yet",
                    message: viewModel.roots.isEmpty
                        ? "Videos anywhere on this server will appear here, matched with posters and details."
                        : "None of your library folders contain videos yet.",
                    action: "Library Settings",
                    perform: { isSettingsPresented = true }
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 40) {
                    GallerySpotlightView(spotlight: viewModel.spotlight)
                    Spacer(minLength: 0)
                    controls
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 12)
                .frame(height: 318, alignment: .top)

                shelves
                    // Rows glide under the spotlight instead of colliding with it.
                    .mask(
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.045), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                    )
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 18) {
            HStack(spacing: 18) {
                Button(action: viewModel.updateLibrary) {
                    Label("Update Library", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
                .accessibilityIdentifier("gallery.rescan")
                Button { isSettingsPresented = true } label: {
                    Label("Library Settings", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("gallery.settings")
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 64))

            GalleryStatusLine(viewModel: viewModel)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .liquidGlass(in: Capsule())
        }
        .focusSection()
    }

    // MARK: Shelves

    private var shelves: some View {
        ScrollViewReader { proxy in
            shelfList
                .onChange(of: focusedShelf) { _, shelf in
                    guard let shelf else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo(shelf, anchor: .top) }
                }
        }
    }

    private var shelfList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !viewModel.shelves.playEntries.isEmpty {
                    playShelf.id("play")
                }
                if !viewModel.shelves.genres.isEmpty {
                    GalleryShelf(title: "Movie Genres", count: viewModel.shelves.genres.count) {
                        ForEach(viewModel.shelves.genres) { tile in
                            Button {
                                viewModel.path.append(.collection(.genre(tile.id)))
                            } label: {
                                GenreTileLabel(tile: tile) {
                                    viewModel.focus(genre: tile)
                                    focusedShelf = "genres"
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("gallery.genre.\(tile.id)")
                        }
                    }
                    .id("genres")
                }
                if !viewModel.shelves.unwatched.isEmpty {
                    posterShelf(title: "Unwatched", titles: viewModel.shelves.unwatched, collection: .unwatched)
                }
                if !viewModel.shelves.shows.isEmpty {
                    posterShelf(title: "TV Shows", titles: viewModel.shelves.shows.map { .show($0.id) }, collection: .shows)
                }
                if !viewModel.shelves.movies.isEmpty {
                    posterShelf(title: "Movies", titles: viewModel.shelves.movies.map { .movie($0.id) }, collection: .movies)
                }
                if !viewModel.shelves.unindexed.isEmpty {
                    posterShelf(title: "Un-indexed", titles: viewModel.shelves.unindexed, collection: .unindexed)
                }
            }
            .scrollTargetLayout()
            .padding(.top, 22)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .scrollTargetBehavior(.viewAligned)
    }

    private var playShelf: some View {
        let entries = viewModel.shelves.playEntries
        return GalleryShelf(title: nil, count: nil) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let sectionStart = index == 0 || entries[index - 1].section != entry.section
                Button {
                    viewModel.path.append(.title(entry.title, focusPath: entry.path))
                } label: {
                    PlayCardLabel(
                        entry: entry,
                        info: viewModel.card(for: entry.title),
                        episode: viewModel.catalog.episode(forPath: entry.path)?.episode,
                        sectionLabel: sectionStart ? (entry.section == .watching ? "Watching" : "Recently Watched") : nil
                    ) {
                        viewModel.focus(entry.title, path: entry.path, section: entry.section)
                        focusedShelf = "play"
                    }
                }
                .buttonStyle(.borderless)
                .contextMenu { menu(for: entry.title, playing: entry.path, section: entry.section) }
                .accessibilityIdentifier("gallery.play.\(entry.path)")
            }
        }
    }

    private func posterShelf(title: String, titles: [GalleryTitle], collection: GalleryCollection) -> some View {
        let limit = 24
        return GalleryShelf(title: title, count: titles.count) {
            ForEach(titles.prefix(limit), id: \.self) { item in
                posterButton(item, shelf: title)
            }
            if titles.count > limit {
                Button {
                    viewModel.path.append(.collection(collection))
                } label: {
                    SeeAllCardLabel(count: titles.count)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("gallery.see-all.\(title)")
            }
        }
        .id(title)
    }

    @ViewBuilder
    private func posterButton(_ title: GalleryTitle, shelf: String) -> some View {
        if let info = viewModel.card(for: title) {
            Button {
                viewModel.path.append(.title(title))
            } label: {
                PosterCardLabel(info: info) {
                    viewModel.focus(title)
                    focusedShelf = shelf
                }
            }
            .buttonStyle(.borderless)
            .contextMenu { menu(for: title, playing: nil) }
            .accessibilityIdentifier("gallery.title.\(info.title)")
        }
    }

    private func menu(for title: GalleryTitle, playing path: String?, section: GalleryPlayEntry.Section? = nil) -> some View {
        GalleryTitleMenu(viewModel: viewModel, title: title, path: path, section: section, onReveal: onReveal)
    }

    // MARK: States

    private func emptyState(icon: String, title: String, message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 26) {
            Image(systemName: icon)
                .font(.system(size: 70, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 168, height: 168)
                .liquidGlass(in: Circle(), tint: Theme.accent.opacity(0.18))
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 40, weight: .semibold))
                .accessibilityIdentifier("gallery.empty")
            Text(message)
                .font(.system(size: 28))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(action: perform) { Text(action) }
                .buttonStyle(PillButtonStyle(prominence: .primary))
                .padding(.top, 12)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 120)
    }
}

// MARK: - Backdrop

/// Full-screen art of the focused title, graded so the top bar, spotlight
/// and shelves always read cleanly over it.
struct GalleryBackdrop: View {
    @ObservedObject var spotlight: GallerySpotlight

    var body: some View {
        ZStack {
            Theme.canvas
            if let url = spotlight.backdropURL {
                ArtworkImage(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .id(url)
                    .transition(.opacity)
            }
            LinearGradient(
                stops: [.init(color: Theme.canvas.opacity(0.92), location: 0), .init(color: Theme.canvas.opacity(0.55), location: 0.45), .init(color: .clear, location: 0.8)],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(
                stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.18), .init(color: .clear, location: 0.3), .init(color: Theme.canvas.opacity(0.88), location: 0.55), .init(color: Theme.canvas, location: 0.9)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.7), value: spotlight.backdropURL)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Spotlight

struct GallerySpotlightView: View {
    @ObservedObject var spotlight: GallerySpotlight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let content = spotlight.content {
                if let eyebrow = content.eyebrow {
                    Text(eyebrow)
                        .font(.system(size: 20, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(.white.opacity(0.6))
                }
                titleBlock(content)
                    .frame(height: 104, alignment: .bottomLeading)
                metaLine(content)
                if let detail = content.detail {
                    HStack(spacing: 16) {
                        if let progress = content.progress {
                            GalleryProgressBar(fraction: progress, height: 6).frame(width: 140)
                        }
                        Text(detail)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                }
                if let overview = content.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .lineSpacing(3)
                        .frame(maxWidth: 1040, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: 1140, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.25), value: spotlight.content?.id)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func titleBlock(_ content: GallerySpotlight.Content) -> some View {
        if let logo = content.logoURL {
            ArtworkImage(url: logo, contentMode: .fit) {
                titleText(content.title)
            }
            .frame(maxWidth: 520, maxHeight: 110, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
            .transition(.opacity)
        } else {
            titleText(content.title)
        }
    }

    private func titleText(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 62, weight: .bold))
            .tracking(-0.8)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func metaLine(_ content: GallerySpotlight.Content) -> some View {
        HStack(spacing: 14) {
            if let rating = content.rating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                    Text(rating)
                }
                .font(.system(size: 22, weight: .bold))
            }
            if !content.meta.isEmpty {
                Text(content.meta.joined(separator: "  ·  "))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            ForEach(content.badges.prefix(3), id: \.self) { badge in
                GlassBadge(text: badge)
            }
        }
        .frame(height: 38)
    }
}

/// "58 videos · Updated 5 minutes ago", or live scan/match progress.
private struct GalleryStatusLine: View {
    @ObservedObject var viewModel: GalleryViewModel

    var body: some View {
        HStack(spacing: 12) {
            if viewModel.isScanning || viewModel.matchProgress != nil || !viewModel.refreshingTitles.isEmpty {
                ProgressView().scaleEffect(0.7).frame(width: 30, height: 30)
            }
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityIdentifier("gallery.status")
    }

    private var text: String {
        // Asked for by hand, so it outranks a background update.
        if let notice = viewModel.refreshNotice { return notice }
        if case let .scanning(progress) = viewModel.phase {
            return "Updating · \(progress.videosFound) videos"
        }
        if let progress = viewModel.matchProgress {
            return "Matching \(progress.done) of \(progress.total)"
        }
        if let issue = viewModel.libraryIssue ?? viewModel.metadataIssue { return issue }
        if !viewModel.hasMetadata { return "Add a TMDB key for posters" }
        let count = viewModel.catalog.videoCount
        return "\(count) video\(count == 1 ? "" : "s")"
    }
}

// MARK: - Shelf

struct GalleryShelf<Content: View>: View {
    let title: String?
    let count: Int?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .accessibilityAddTraits(.isHeader)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) {
                    content()
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 22)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
        // Room above the header so a snapped shelf clears the top fade.
        .padding(.top, 30)
        .focusSection()
    }
}

// MARK: - Cards

/// 2:3 poster with the system's parallax highlight, a corner status mark
/// and a resume line.
struct PosterCardLabel: View {
    let info: GalleryCardInfo
    var width: CGFloat = 220
    let onFocus: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                ArtworkImage(url: info.posterURL) {
                    GeneratedPoster(title: info.title, subtitle: info.subtitle, compact: true)
                }
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottom) {
                    if let progress = info.progress {
                        GalleryProgressBar(fraction: progress, height: 6)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                            .shadow(color: .black.opacity(0.6), radius: 6)
                    }
                }
                .overlay(alignment: .topTrailing) { cornerMark }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hoverEffect(.highlight)

            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white.opacity(isFocused ? 1 : 0.8))
                    .lineLimit(1)
                if let subtitle = info.subtitle {
                    Text(subtitle)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            .offset(y: isFocused ? 12 : 0)
            .animation(Theme.focusSpring, value: isFocused)
        }
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.title)
        .accessibilityValue([info.subtitle, info.isWatched ? "Watched" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private var cornerMark: some View {
        if let count = info.unwatchedCount, count > 0 {
            Text("\(count)")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(minWidth: 36, minHeight: 34)
                .liquidGlass(in: Capsule(), tint: Theme.accent.opacity(0.55))
                .padding(10)
        } else if info.isWatched {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .liquidGlass(in: Circle())
                .padding(10)
        } else if info.progress == nil && info.unwatchedCount == nil {
            // Infuse's unwatched corner, drawn as a soft accent fold.
            UnwatchedFold()
                .fill(Theme.accent)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.35), radius: 4)
        }
    }
}

private struct UnwatchedFold: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// Wide card for Watching / Recently Watched, labelled with its section.
struct PlayCardLabel: View {
    let entry: GalleryPlayEntry
    let info: GalleryCardInfo?
    let episode: GalleryEpisode?
    let sectionLabel: String?
    let onFocus: () -> Void

    @Environment(\.isFocused) private var isFocused
    private let width: CGFloat = 430

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sectionLabel?.uppercased() ?? " ")
                .font(.system(size: 19, weight: .bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(sectionLabel == nil ? 0 : 0.55))
                .frame(height: 22)

            ZStack(alignment: .bottomLeading) {
                ArtworkImage(url: info?.backdropURL) {
                    GeneratedPoster(title: info?.title ?? "", compact: true)
                }
                .frame(width: width, height: width * 9 / 16)

                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 10) {
                    if let episode {
                        Text(episode.code)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    if let fraction = entry.status.fraction {
                        GalleryProgressBar(fraction: fraction, height: 6)
                    }
                }
                .padding(18)

                if entry.status == .watched {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .heavy))
                        .frame(width: 34, height: 34)
                        .liquidGlass(in: Circle())
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .hoverEffect(.highlight)

            VStack(alignment: .leading, spacing: 3) {
                Text(info?.title ?? "")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white.opacity(isFocused ? 1 : 0.82))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .offset(y: isFocused ? 12 : 0)
            .animation(Theme.focusSpring, value: isFocused)
        }
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([info?.title, episode?.code].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(detail)
    }

    private var detail: String {
        switch entry.status {
        case let .inProgress(_, remaining): GalleryFormat.remaining(remaining)
        case .watched: "Watched · \(GalleryFormat.relative(entry.date))"
        case .unwatched: "Opened · \(GalleryFormat.relative(entry.date))"
        }
    }
}

/// Genre tile: three recent posters fanned over a genre-tinted field.
struct GenreTileLabel: View {
    let tile: GalleryGenreTile
    let onFocus: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let tint = GalleryPalette.genreTint(tile.id)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.25), Color.black.opacity(0.9)], startPoint: .topTrailing, endPoint: .bottomLeading)
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 260)

            ZStack {
                ForEach(Array(tile.posters.enumerated().reversed()), id: \.offset) { index, poster in
                    ArtworkImage(url: TMDBImage.url(poster, size: .poster)) { Color.white.opacity(0.1) }
                        .frame(width: 104, height: 156)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                        .rotationEffect(.degrees(Double(index - 1) * 9 + (isFocused ? Double(index - 1) * 3 : 0)))
                        .offset(x: CGFloat(index - 1) * (isFocused ? 62 : 54), y: index == 1 ? -10 : 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 92)
            .offset(y: -18)

            VStack(alignment: .leading, spacing: 2) {
                Text(tile.genre.name)
                    .font(.system(size: 30, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(tile.count) Movie\(tile.count == 1 ? "" : "s")")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .shadow(color: .black.opacity(0.5), radius: 8)
            .padding(22)
        }
        .frame(width: 400, height: 225)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .hoverEffect(.highlight)
        .animation(Theme.focusSpring, value: isFocused)
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.genre.name)
        .accessibilityValue("\(tile.count) movies")
    }
}

struct SeeAllCardLabel: View {
    let count: Int
    var width: CGFloat = 220

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 40, weight: .light))
            Text("See All")
                .font(.system(size: 26, weight: .bold))
            Text("\(count)")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: width, height: width * 1.5)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .hoverEffect(.highlight)
    }
}

// MARK: - Scanning

private struct GalleryScanningView: View {
    let progress: LibraryScanProgress
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 30) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: 210, height: 210)
                    .scaleEffect(pulse ? 1.12 : 0.92)
                    .opacity(pulse ? 0.2 : 0.8)
                Image(systemName: "film.stack")
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: 170, height: 170)
                    .liquidGlass(in: Circle(), tint: Theme.accent.opacity(0.3))
            }
            .accessibilityHidden(true)
            Text("Building your Gallery")
                .font(.system(size: 44, weight: .bold))
            Text("\(progress.videosFound) videos in \(progress.foldersScanned) folders")
                .font(.system(size: 28, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .contentTransition(.numericText())
                .animation(.default, value: progress.videosFound)
            Text(progress.currentFolder)
                .font(.system(size: 22))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 900)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 100)
        .focusable()
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gallery.scanning")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Long-press actions for a title's card, on the shelves and the "See All" walls.
struct GalleryTitleMenu: View {
    let viewModel: GalleryViewModel
    let title: GalleryTitle
    /// The file the card stands for (a Watching card's episode), if any.
    var path: String?
    var section: GalleryPlayEntry.Section?
    let onReveal: (AListObject) -> Void

    var body: some View {
        let file = path.flatMap { path in viewModel.catalog.episode(forPath: path)?.episode.file }
            ?? viewModel.primaryFile(for: title)
        if let file {
            Button { viewModel.play(file) } label: { Label("Play", systemImage: "play.fill") }
        }
        let paths = viewModel.paths(for: title)
        if paths.allSatisfy({ viewModel.watch.isWatched($0) }) {
            Button { viewModel.setWatched(false, paths: paths) } label: { Label("Mark as Unwatched", systemImage: "circle") }
        } else {
            Button { viewModel.setWatched(true, paths: paths) } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        }
        if section == .watching {
            Button(role: .destructive) { viewModel.removeFromWatching(title) } label: { Label("Remove from Watching", systemImage: "minus.circle") }
        }
        if let file {
            Button { onReveal(file.object) } label: { Label("Show in Browse", systemImage: "folder") }
        }
        if viewModel.hasMetadata {
            Button { viewModel.refreshMetadata(for: title) } label: {
                Label("Refresh Metadata", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(viewModel.isRefreshing(title))
        }
        let excludable = paths.filter(viewModel.canExclude)
        if !excludable.isEmpty {
            Button(role: .destructive) { viewModel.exclude(excludable) } label: {
                Label(excludable.count == 1 ? "Exclude Video" : "Exclude \(excludable.count) Videos", systemImage: "eye.slash")
            }
        }
        if let folder = viewModel.excludableFolder(for: title) {
            Button(role: .destructive) { viewModel.exclude([folder]) } label: {
                Label("Exclude Folder “\(folder.split(separator: "/").last ?? "")”", systemImage: "folder.badge.minus")
            }
        }
    }
}
