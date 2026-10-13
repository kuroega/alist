import SwiftUI

/// Full-screen page for one movie or show: cinematic art, title treatment,
/// actions, seasons and episodes, cast, and the files behind it.
struct GalleryDetailView: View {
    @ObservedObject var viewModel: GalleryViewModel
    let title: GalleryTitle
    let focusPath: String?
    let onReveal: (AListObject) -> Void

    @State private var movieDetail: TMDBMovieDetail?
    @State private var showDetail: TMDBShowDetail?
    @State private var selectedSeason: Int?
    @State private var seasonInfo: [Int: [Int: TMDBSeasonDetail.Episode]] = [:]
    @State private var isVersionPickerPresented = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case play
        case season(Int)
        case episode(String)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        hero
                            .frame(minHeight: show == nil ? 900 : 760, alignment: .bottomLeading)
                            .padding(.bottom, 48)
                        lowerSections(proxy: proxy)
                    }
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focus, .play)
        .task(id: title) { await load() }
        .onChange(of: focus) { _, value in
            if case let .season(season) = value, season != selectedSeason {
                withAnimation(.easeInOut(duration: 0.25)) { selectedSeason = season }
            }
        }
        .onChange(of: selectedSeason) { _, season in
            if let season { Task { await loadSeason(season) } }
        }
    }

    // MARK: Model

    private var movie: GalleryMovie? {
        if case let .movie(id) = title { return viewModel.catalog.movie(id) }
        return nil
    }

    private var show: GalleryShow? {
        if case let .show(id) = title { return viewModel.catalog.show(id) }
        return nil
    }

    private var displayTitle: String { movie?.title ?? show?.title ?? "" }
    private var backdropPath: String? { movie?.backdropPath ?? show?.backdropPath ?? movieDetail?.backdropPath ?? showDetail?.backdropPath }

    private var currentSeason: Int? { selectedSeason ?? show?.seasons.first }

    /// What Play starts: the movie's best version, or the next episode.
    private var playTarget: LibraryFile? {
        if let movie { return movie.files.first { viewModel.status($0.path).fraction != nil } ?? movie.primaryFile }
        if let show, let focusPath, let match = show.episodes.first(where: { $0.path == focusPath }),
           viewModel.status(match.path) != .watched {
            return match.file
        }
        return show.flatMap { viewModel.nextEpisode(in: $0)?.file }
    }

    private func load() async {
        if let show {
            if selectedSeason == nil {
                let target = focusPath.flatMap { path in show.episodes.first { $0.path == path } } ?? viewModel.nextEpisode(in: show)
                selectedSeason = target?.season ?? show.seasons.first
            }
            if let id = show.tmdbID {
                showDetail = viewModel.cachedShowDetail(id)
                if showDetail == nil { showDetail = await viewModel.showDetail(id) }
            }
            if let season = currentSeason { await loadSeason(season) }
        } else if let movie, let id = movie.tmdbID {
            movieDetail = viewModel.cachedMovieDetail(id)
            if movieDetail == nil { movieDetail = await viewModel.movieDetail(id) }
        }
    }

    private func loadSeason(_ season: Int) async {
        guard seasonInfo[season] == nil, let id = show?.tmdbID,
              let detail = await viewModel.seasonDetail(showID: id, season: season) else { return }
        let episodes = Dictionary((detail.episodes ?? []).map { ($0.episodeNumber, $0) }, uniquingKeysWith: { first, _ in first })
        withAnimation(.easeOut(duration: 0.3)) { seasonInfo[season] = episodes }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            ArtworkImage(url: TMDBImage.url(backdropPath, size: .original)) {
                ArtworkImage(url: TMDBImage.url(backdropPath, size: .backdrop)) {
                    LinearGradient(colors: [GalleryPalette.colors(for: displayTitle).0, Theme.canvas], startPoint: .topTrailing, endPoint: .bottomLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            LinearGradient(
                stops: [.init(color: Theme.canvas.opacity(0.95), location: 0), .init(color: Theme.canvas.opacity(0.6), location: 0.42), .init(color: .clear, location: 0.75)],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(
                stops: [.init(color: .clear, location: 0.35), .init(color: Theme.canvas.opacity(0.7), location: 0.72), .init(color: Theme.canvas, location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            titleTreatment
            metaRow
            if !qualities.isEmpty {
                HStack(spacing: 12) {
                    ForEach(qualities, id: \.self) { GlassBadge(text: $0, systemImage: GalleryFormat.qualityIcon($0)) }
                }
            }
            if let tagline = movieDetail?.tagline ?? showDetail?.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.system(size: 26, weight: .medium).italic())
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(overview)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(4)
                .lineLimit(4)
                .frame(maxWidth: 1050, alignment: .leading)
            actions
                .padding(.top, 14)
        }
        .padding(.horizontal, Theme.screenPadding + 20)
        .padding(.top, 120)
    }

    @ViewBuilder
    private var titleTreatment: some View {
        let logo = movieDetail?.images?.preferredLogo(language: viewModel.tmdb?.language ?? "en")
            ?? showDetail?.images?.preferredLogo(language: viewModel.tmdb?.language ?? "en")
        if let logo {
            ArtworkImage(url: TMDBImage.url(logo, size: .original), contentMode: .fit) {
                titleText
            }
            .frame(maxWidth: 760, maxHeight: 230, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(displayTitle)
            .font(.system(size: 84, weight: .heavy))
            .tracking(-1.2)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
            .frame(maxWidth: 1200, alignment: .bottomLeading)
    }

    private var metaRow: some View {
        HStack(spacing: 18) {
            if let rating = GalleryFormat.rating(movie?.rating ?? show?.rating) {
                HStack(spacing: 7) {
                    Image(systemName: "star.fill").foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                    Text(rating)
                }
                .font(.system(size: 24, weight: .bold))
            }
            if let certification {
                Text(certification)
                    .font(.system(size: 19, weight: .heavy))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 2))
            }
            Text(metaText)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let movie {
            if let year = movieDetail?.releaseDate.flatMap({ $0.isEmpty ? nil : String($0.prefix(4)) }) ?? movie.year.map(String.init) { parts.append(year) }
            if let runtime = GalleryFormat.runtime(minutes: movieDetail?.runtime) { parts.append(runtime) }
            let genres = movieDetail?.genres?.map(\.name) ?? movie.genreIDs.compactMap(viewModel.genreName)
            parts += genres.prefix(3)
        } else if let show {
            if let year = show.year { parts.append(String(year)) }
            let seasons = show.seasons.filter { $0 != 0 }.count
            parts.append("\(seasons) Season\(seasons == 1 ? "" : "s")")
            let genres = showDetail?.genres?.map(\.name) ?? show.genreIDs.compactMap(viewModel.genreName)
            parts += genres.prefix(3)
            if let network = showDetail?.networks?.first?.name { parts.append(network) }
        }
        return parts.joined(separator: "  ·  ")
    }

    private var certification: String? {
        let region = Locale.current.region?.identifier ?? "US"
        if let releases = movieDetail?.releaseDates?.results {
            let pick = { (country: String) in
                releases.first { $0.iso31661 == country }?.releaseDates.compactMap(\.certification).first { !$0.isEmpty }
            }
            return pick(region) ?? pick("US")
        }
        if let ratings = showDetail?.contentRatings?.results {
            let pick = { (country: String) in ratings.first { $0.iso31661 == country }?.rating.flatMap { $0.isEmpty ? nil : $0 } }
            return pick(region) ?? pick("US")
        }
        return nil
    }

    private var qualities: [String] {
        if let movie { return movie.qualities }
        return show?.episodes.first?.file.parsed.qualities ?? []
    }

    private var overview: String {
        let text = movieDetail?.overview ?? showDetail?.overview ?? movie?.overview ?? show?.overview
        if let text, !text.isEmpty { return text }
        return viewModel.hasMetadata ? "No details were found on TMDB for this title." : "Add a TMDB API key to see posters and details."
    }

    // MARK: Actions

    private var actions: some View {
        HStack(alignment: .top, spacing: 24) {
            if let target = playTarget {
                VStack(alignment: .leading, spacing: 12) {
                    Button { viewModel.play(target) } label: {
                        Label(playLabel(for: target), systemImage: "play.fill")
                            .font(.system(size: 28, weight: .bold))
                    }
                    .galleryActionStyle(prominent: true)
                    .focused($focus, equals: .play)
                    .accessibilityIdentifier("gallery.detail.play")

                    if case let .inProgress(fraction, remaining) = viewModel.status(target.path) {
                        HStack(spacing: 12) {
                            GalleryProgressBar(fraction: fraction, height: 5).frame(width: 160)
                            Text(GalleryFormat.remaining(remaining))
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.leading, 12)
                    }
                }
            }

            if let target = playTarget, viewModel.status(target.path).fraction != nil {
                Button { restart(target) } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .galleryActionStyle(prominent: false)
            }

            let paths = movie?.paths ?? show?.paths ?? []
            let allWatched = !paths.isEmpty && paths.allSatisfy { viewModel.watch.isWatched($0) }
            Button {
                viewModel.setWatched(!allWatched, paths: paths)
            } label: {
                Label(allWatched ? "Watched" : "Mark Watched", systemImage: allWatched ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .galleryActionStyle(prominent: false)
            .accessibilityIdentifier("gallery.detail.watched")

            if let movie, movie.files.count > 1 {
                Button { isVersionPickerPresented = true } label: {
                    Label("\(movie.files.count) Versions", systemImage: "square.stack.3d.up")
                }
                .galleryActionStyle(prominent: false)
                .confirmationDialog("Choose a Version", isPresented: $isVersionPickerPresented, titleVisibility: .visible) {
                    ForEach(movie.files) { file in
                        Button(versionTitle(file)) { viewModel.play(file) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .focusSection()
    }

    private func playLabel(for target: LibraryFile) -> String {
        let resuming = viewModel.status(target.path).fraction != nil
        if show != nil, let episode = viewModel.catalog.episode(forPath: target.path)?.episode {
            return "\(resuming ? "Resume" : "Play") S\(episode.season) E\(episode.episode)"
        }
        return resuming ? "Resume" : "Play"
    }

    /// Clears the resume point so the player starts at the beginning.
    private func restart(_ target: LibraryFile) {
        viewModel.clearProgress(path: target.path)
        viewModel.play(target)
    }

    private func versionTitle(_ file: LibraryFile) -> String {
        let quality = file.parsed.qualities.isEmpty ? "Original" : file.parsed.qualities.joined(separator: " · ")
        return "\(quality) — \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))"
    }

    // MARK: Lower sections

    private func lowerSections(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 64) {
            if let show {
                seasons(show, proxy: proxy)
            }
            cast
            fileInfo
        }
        .padding(.top, 20)
        .padding(.bottom, 100)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Theme.canvas.opacity(0.92), location: 0.12), .init(color: Theme.canvas, location: 0.3)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -120)
        }
    }

    private func seasons(_ show: GalleryShow, proxy: ScrollViewProxy) -> some View {
        let season = currentSeason ?? show.seasons.first ?? 1
        let episodes = show.episodes(inSeason: season)
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(show.seasons, id: \.self) { number in
                        Button {
                            selectedSeason = number
                        } label: {
                            Text(number == 0 ? "Specials" : "Season \(number)")
                        }
                        .buttonStyle(SeasonTabStyle(isSelected: number == season))
                        .focused($focus, equals: .season(number))
                        .accessibilityIdentifier("gallery.detail.season.\(number)")
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .focusSection()

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) {
                    ForEach(episodes) { episode in
                        Button {
                            viewModel.play(episode.file)
                        } label: {
                            EpisodeCardLabel(
                                episode: episode,
                                info: seasonInfo[season]?[episode.episode],
                                fallbackStill: show.backdropPath,
                                status: viewModel.status(episode.path)
                            )
                        }
                        .buttonStyle(.borderless)
                        .focused($focus, equals: .episode(episode.path))
                        .contextMenu {
                            let watched = viewModel.watch.isWatched(episode.path)
                            Button { viewModel.setWatched(!watched, paths: [episode.path]) } label: {
                                Label(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "circle" : "checkmark.circle")
                            }
                            Button { onReveal(episode.file.object) } label: { Label("Show in Browse", systemImage: "folder") }
                        }
                        .id(episode.path)
                        .accessibilityIdentifier("gallery.detail.episode.\(episode.season).\(episode.episode)")
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .focusSection()
            .id(season)
            .transition(.opacity)
            .onAppear {
                if let focusPath, episodes.contains(where: { $0.path == focusPath }) {
                    proxy.scrollTo(focusPath, anchor: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var cast: some View {
        let members = (movieDetail?.credits?.cast ?? showDetail?.credits?.cast ?? []).prefix(20)
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Cast & Crew")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        if let director {
                            CastMemberLabel(name: director.name, role: "Director", profilePath: director.profilePath)
                        }
                        ForEach(Array(members)) { member in
                            CastMemberLabel(name: member.name, role: member.character, profilePath: member.profilePath)
                        }
                    }
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    private var director: TMDBCredits.Crew? {
        movieDetail?.credits?.crew?.first { $0.job == "Director" }
    }

    private var fileInfo: some View {
        let file = playTarget ?? movie?.primaryFile ?? show?.episodes.first?.file
        return VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Information")
            HStack(alignment: .top, spacing: 30) {
                if let file {
                    Button { onReveal(file.object) } label: {
                        InfoPanel(rows: [
                            ("File", file.name),
                            ("Size", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)),
                            ("Folder", AListPath.parent(of: file.path))
                        ], footer: "Show in Browse")
                    }
                    .buttonStyle(.borderless)
                }
                InfoPanel(rows: infoRows, footer: nil)
                    .focusable()
            }
            .padding(.horizontal, Theme.screenPadding)
        }
        .focusSection()
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let movieDetail {
            if let date = GalleryFormat.airDate(movieDetail.releaseDate) { rows.append(("Released", date)) }
            if let runtime = GalleryFormat.runtime(minutes: movieDetail.runtime) { rows.append(("Runtime", runtime)) }
            if let director { rows.append(("Director", director.name)) }
        } else if let showDetail {
            if let date = GalleryFormat.airDate(showDetail.firstAirDate) { rows.append(("First Aired", date)) }
            if let status = showDetail.status { rows.append(("Status", status)) }
            if let network = showDetail.networks?.first?.name { rows.append(("Network", network)) }
        }
        if let show { rows.append(("In Library", "\(show.episodes.count) episodes")) }
        if rows.isEmpty { rows.append(("Source", "Matched from file name")) }
        return rows
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 32, weight: .bold))
            .padding(.horizontal, Theme.screenPadding)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Components

/// Season switcher capsule: glass at rest, solid white when focused, with a
/// tinted fill marking the season on screen.
private struct SeasonTabStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, isSelected: isSelected)
    }

    private struct TabBody: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : .white.opacity(isSelected ? 1 : 0.7))
                .padding(.horizontal, 32)
                .frame(height: 64)
                .background {
                    if isFocused {
                        Capsule().fill(.white)
                    }
                }
                .liquidGlass(in: Capsule(), tint: isSelected && !isFocused ? Color.white.opacity(0.22) : nil)
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                .animation(Theme.focusSpring, value: isFocused)
        }
    }
}

private struct EpisodeCardLabel: View {
    let episode: GalleryEpisode
    let info: TMDBSeasonDetail.Episode?
    let fallbackStill: String?
    let status: WatchStatus

    @Environment(\.isFocused) private var isFocused
    private let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(url: TMDBImage.url(info?.stillPath, size: .still)) {
                    ArtworkImage(url: TMDBImage.url(fallbackStill, size: .backdrop)) {
                        GeneratedPoster(title: name, compact: true)
                    }
                    .overlay(Color.black.opacity(0.35))
                }
                .frame(width: width, height: width * 9 / 16)

                if let fraction = status.fraction {
                    GalleryProgressBar(fraction: fraction, height: 6)
                        .padding(16)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                }
                if status == .watched {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .heavy))
                        .frame(width: 34, height: 34)
                        .liquidGlass(in: Circle())
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if isFocused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .frame(width: 72, height: 72)
                        .liquidGlass(in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .hoverEffect(.highlight)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(episode.episode). \(name)")
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                if let overview = info?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(3)
                        .lineSpacing(2)
                        .frame(height: 84, alignment: .top)
                }
            }
            .frame(width: width, alignment: .leading)
            .offset(y: isFocused ? 12 : 0)
        }
        .animation(Theme.focusSpring, value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Episode \(episode.episode), \(name)")
        .accessibilityValue(meta)
    }

    private var name: String {
        info?.name ?? episode.file.parsed.episodeTitle ?? "Episode \(episode.episode)"
    }

    private var meta: String {
        var parts: [String] = []
        if let runtime = GalleryFormat.runtime(minutes: info?.runtime) { parts.append(runtime) }
        if let date = GalleryFormat.airDate(info?.airDate) { parts.append(date) }
        switch status {
        case let .inProgress(_, remaining): parts.append(GalleryFormat.remaining(remaining))
        case .watched: parts.append("Watched")
        case .unwatched: break
        }
        if parts.isEmpty { parts.append(episode.file.name) }
        return parts.joined(separator: " · ")
    }
}

private struct CastMemberLabel: View {
    let name: String
    let role: String?
    let profilePath: String?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            ArtworkImage(url: TMDBImage.url(profilePath, size: .profile)) {
                Text(initials)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .liquidGlass(in: Circle())
            }
            .frame(width: 150, height: 150)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(isFocused ? 0.9 : 0.12), lineWidth: isFocused ? 3 : 1))
            .scaleEffect(isFocused ? 1.1 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(1)
                if let role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: 180)
            .offset(y: isFocused ? 8 : 0)
        }
        .focusable()
        .focused($isFocused)
        .animation(Theme.focusSpring, value: isFocused)
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

private struct InfoPanel: View {
    let rows: [(String, String)]
    let footer: String?

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0.uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.45))
                    Text(row.1)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            if let footer {
                Label(footer, systemImage: "folder")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isFocused ? .white : Theme.accent)
                    .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(width: 620, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: isFocused ? Color.white.opacity(0.18) : nil)
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(Theme.focusSpring, value: isFocused)
    }
}

/// Detail-page action: Liquid Glass at rest (the primary action as a bright
/// pill), solid white with dark text when focused, as tvOS expects.
struct GalleryActionButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, prominent: prominent)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let filled = isFocused || prominent
            let label = configuration.label
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(filled ? Color.black : .white)
                .padding(.horizontal, 38)
                .frame(height: 78)
            Group {
                if filled {
                    label.background(Capsule().fill(Color.white.opacity(isFocused ? 1 : 0.88)))
                } else {
                    // Glass applied to the label itself keeps the text above the material.
                    label.liquidGlass(in: Capsule())
                }
            }
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 20, y: 10)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Theme.focusSpring, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension View {
    func galleryActionStyle(prominent: Bool) -> some View {
        buttonStyle(GalleryActionButtonStyle(prominent: prominent))
    }
}
