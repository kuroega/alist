import Combine
import SwiftUI

/// What the focused card puts on stage: the full-screen backdrop and the
/// title block above the shelves. Kept apart from the view model so a focus
/// move only redraws the spotlight, never the shelves.
@MainActor
final class GallerySpotlight: ObservableObject {
    struct Content: Equatable {
        var id: String
        var eyebrow: String?
        var title: String
        var logoURL: URL?
        var meta: [String] = []
        var rating: String?
        var detail: String?
        var overview: String?
        var badges: [String] = []
        var progress: Double?
    }

    @Published private(set) var content: Content?
    @Published private(set) var backdropURL: URL?

    private var backdropTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?

    /// Shows `content` now, swaps the backdrop once focus settles, then lets
    /// `enrich` add slower details such as the title logo and runtime.
    func show(_ content: Content, backdrop: URL?, enrich: (@MainActor () async -> Content?)? = nil) {
        guard content != self.content || backdrop != backdropURL else { return }
        self.content = content

        backdropTask?.cancel()
        if backdrop != backdropURL {
            backdropTask = Task { [weak self] in
                // Skimming along a shelf should not strobe the whole screen.
                try? await Task.sleep(for: .milliseconds(self?.backdropURL == nil ? 0 : 220))
                guard !Task.isCancelled, let self else { return }
                if let backdrop { _ = await ArtworkPipeline.shared.image(for: backdrop) }
                guard !Task.isCancelled else { return }
                self.backdropURL = backdrop
            }
        }

        enrichTask?.cancel()
        guard let enrich else { return }
        let id = content.id
        enrichTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let enriched = await enrich(), !Task.isCancelled,
                  let self, self.content?.id == id else { return }
            if let logo = enriched.logoURL { _ = await ArtworkPipeline.shared.image(for: logo) }
            guard self.content?.id == id else { return }
            withAnimation(.easeInOut(duration: 0.3)) { self.content = enriched }
        }
    }
}

/// Everything a poster or landscape card shows for one title.
struct GalleryCardInfo {
    let title: String
    let subtitle: String?
    let posterURL: URL?
    let backdropURL: URL?
    let progress: Double?
    let isWatched: Bool
    /// Shows only: episodes not yet finished, for the corner count.
    let unwatchedCount: Int?
}

extension GalleryViewModel {
    // MARK: Cards

    func card(for title: GalleryTitle) -> GalleryCardInfo? {
        switch title {
        case let .movie(id):
            guard let movie = catalog.movie(id) else { return nil }
            let statuses = movie.paths.map(status)
            return GalleryCardInfo(
                title: movie.title,
                subtitle: movie.year.map(String.init),
                posterURL: TMDBImage.url(movie.posterPath, size: .poster),
                backdropURL: TMDBImage.url(movie.backdropPath, size: .backdrop),
                progress: statuses.compactMap(\.fraction).first,
                isWatched: statuses.contains(.watched),
                unwatchedCount: nil
            )
        case let .show(id):
            guard let show = catalog.show(id) else { return nil }
            let unwatched = show.episodes.filter { !watch.isWatched($0.path) }.count
            let seasons = show.seasons.filter { $0 != 0 }.count
            let subtitle = seasons > 1 ? "\(seasons) Seasons" : "\(show.episodes.count) Episode\(show.episodes.count == 1 ? "" : "s")"
            return GalleryCardInfo(
                title: show.title,
                subtitle: subtitle,
                posterURL: TMDBImage.url(show.posterPath, size: .poster),
                backdropURL: TMDBImage.url(show.backdropPath, size: .backdrop),
                progress: nil,
                isWatched: unwatched == 0,
                unwatchedCount: unwatched
            )
        }
    }

    func paths(for title: GalleryTitle) -> [String] {
        switch title {
        case let .movie(id): catalog.movie(id)?.paths ?? []
        case let .show(id): catalog.show(id)?.paths ?? []
        }
    }

    func primaryFile(for title: GalleryTitle) -> LibraryFile? {
        switch title {
        case let .movie(id):
            return catalog.movie(id)?.primaryFile
        case let .show(id):
            guard let show = catalog.show(id) else { return nil }
            return nextEpisode(in: show)?.file
        }
    }

    // MARK: Spotlight

    func focus(_ title: GalleryTitle, path: String? = nil, section: GalleryPlayEntry.Section? = nil) {
        spotlightSubject = (title, path, section)
        switch title {
        case let .movie(id):
            guard let movie = catalog.movie(id) else { return }
            var content = movieContent(movie)
            if let section { content.eyebrow = section == .watching ? "CONTINUE WATCHING" : "RECENTLY WATCHED" }
            if let path, case let .inProgress(fraction, remaining) = status(path) {
                content.detail = GalleryFormat.remaining(remaining)
                content.progress = fraction
            }
            let tmdbID = movie.tmdbID
            spotlight.show(content, backdrop: TMDBImage.url(movie.backdropPath, size: .backdrop)) { [weak self] in
                guard let self, let tmdbID, let detail = await self.movieDetail(tmdbID) else { return nil }
                return self.enrich(content, movie: detail)
            }
        case let .show(id):
            guard let show = catalog.show(id) else { return }
            var content = showContent(show)
            let episode = path.flatMap { path in show.episodes.first { $0.path == path } }
            if let section { content.eyebrow = section == .watching ? "CONTINUE WATCHING" : "RECENTLY WATCHED" }
            if let episode {
                var parts = [episode.code]
                if let name = episode.file.parsed.episodeTitle { parts.append(name) }
                if case let .inProgress(fraction, remaining) = status(episode.path) {
                    parts.append(GalleryFormat.remaining(remaining))
                    content.progress = fraction
                }
                content.detail = parts.joined(separator: "  ·  ")
            }
            let tmdbID = show.tmdbID
            spotlight.show(content, backdrop: TMDBImage.url(show.backdropPath, size: .backdrop)) { [weak self] in
                guard let self, let tmdbID, let detail = await self.showDetail(tmdbID) else { return nil }
                return self.enrich(content, show: detail)
            }
        }
    }

    func focus(genre tile: GalleryGenreTile) {
        spotlightSubject = nil
        let content = GallerySpotlight.Content(
            id: "genre:\(tile.id)",
            eyebrow: "GENRE",
            title: tile.genre.name,
            meta: ["\(tile.count) Movie\(tile.count == 1 ? "" : "s")"]
        )
        spotlight.show(content, backdrop: TMDBImage.url(tile.backdrop, size: .backdrop))
    }

    /// Re-stages the current title after the catalog changes, e.g. when its
    /// TMDB match arrives or a local entry merges into a matched one.
    func refreshSpotlight() {
        guard let subject = spotlightSubject else { return }
        let path = subject.path ?? paths(for: subject.title).first
        if catalog.movie(id(of: subject.title)) == nil && catalog.show(id(of: subject.title)) == nil {
            // The local entry was replaced by its matched one; follow the file.
            guard let path, let title = catalog.title(forPath: path) else { return }
            focus(title, path: subject.path, section: subject.section)
        } else {
            focus(subject.title, path: subject.path, section: subject.section)
        }
    }

    private func id(of title: GalleryTitle) -> String {
        switch title {
        case let .movie(id), let .show(id): id
        }
    }

    /// Puts the most relevant title on stage before anything is focused.
    func focusDefault() {
        guard spotlight.content == nil else { return }
        if let entry = shelves.playEntries.first {
            focus(entry.title, path: entry.path, section: entry.section)
        } else if let first = shelves.unwatched.first ?? shelves.movies.first.map({ .movie($0.id) }) ?? shelves.shows.first.map({ .show($0.id) }) {
            focus(first)
        }
    }

    private func movieContent(_ movie: GalleryMovie) -> GallerySpotlight.Content {
        let cached = cachedMovieDetail(movie.tmdbID)
        var content = GallerySpotlight.Content(id: movie.id, eyebrow: "MOVIE", title: movie.title)
        content.meta = [movie.year.map(String.init)].compactMap { $0 } + movie.genreIDs.prefix(2).compactMap(genreName)
        content.rating = GalleryFormat.rating(movie.rating)
        content.overview = movie.overview
        content.badges = movie.qualities
        if let cached { content = enrich(content, movie: cached) }
        return content
    }

    private func showContent(_ show: GalleryShow) -> GallerySpotlight.Content {
        let cached = cachedShowDetail(show.tmdbID)
        var content = GallerySpotlight.Content(id: show.id, eyebrow: "TV SHOW", title: show.title)
        let seasons = show.seasons.filter { $0 != 0 }.count
        content.meta = [show.year.map(String.init), seasons > 0 ? "\(seasons) Season\(seasons == 1 ? "" : "s")" : nil].compactMap { $0 }
            + show.genreIDs.prefix(2).compactMap(genreName)
        content.rating = GalleryFormat.rating(show.rating)
        content.overview = show.overview
        content.badges = show.episodes.first?.file.parsed.qualities ?? []
        if let cached { content = enrich(content, show: cached) }
        return content
    }

    private func enrich(_ base: GallerySpotlight.Content, movie detail: TMDBMovieDetail) -> GallerySpotlight.Content {
        var content = base
        content.logoURL = TMDBImage.url(detail.images?.preferredLogo(language: tmdb?.language ?? "en"), size: .logo)
        let genres = (detail.genres ?? []).prefix(2).map(\.name)
        content.meta = [detail.releaseDate.flatMap { $0.isEmpty ? nil : String($0.prefix(4)) }, GalleryFormat.runtime(minutes: detail.runtime)].compactMap { $0 } + genres
        if let overview = detail.overview, !overview.isEmpty { content.overview = overview }
        return content
    }

    private func enrich(_ base: GallerySpotlight.Content, show detail: TMDBShowDetail) -> GallerySpotlight.Content {
        var content = base
        content.logoURL = TMDBImage.url(detail.images?.preferredLogo(language: tmdb?.language ?? "en"), size: .logo)
        let genres = (detail.genres ?? []).prefix(2).map(\.name)
        content.meta = Array(base.meta.prefix { !genres.contains($0) && !(genreNames.values.contains($0)) }) + genres
        if let network = detail.networks?.first?.name { content.meta.append(network) }
        if let overview = detail.overview, !overview.isEmpty { content.overview = overview }
        return content
    }
}
