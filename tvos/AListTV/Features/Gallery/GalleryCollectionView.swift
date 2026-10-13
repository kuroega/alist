import SwiftUI

/// "See All" wall for one collection (Movies, TV Shows, Unwatched or a genre).
struct GalleryCollectionView: View {
    @ObservedObject var viewModel: GalleryViewModel
    let collection: GalleryCollection

    private let columns = Array(repeating: GridItem(.fixed(206), spacing: 44, alignment: .top), count: 7)

    var body: some View {
        let titles = viewModel.titles(in: collection)
        ZStack(alignment: .topLeading) {
            GalleryBackdrop(spotlight: viewModel.spotlight)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(eyebrow)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(.white.opacity(0.55))
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text(viewModel.collectionTitle(collection))
                            .font(.system(size: 72, weight: .heavy))
                            .tracking(-1)
                        Text("\(titles.count)")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .monospacedDigit()
                    }
                    .accessibilityAddTraits(.isHeader)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                        ForEach(titles, id: \.self) { title in
                            if let info = viewModel.card(for: title) {
                                Button {
                                    viewModel.path.append(.title(title))
                                } label: {
                                    PosterCardLabel(info: info, width: 206) { viewModel.focus(title) }
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("gallery.collection.\(info.title)")
                            }
                        }
                    }
                    .padding(.top, 36)
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 70)
                .padding(.bottom, 90)
            }
            .scrollClipDisabled()
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var eyebrow: String {
        switch collection {
        case .genre: "GENRE"
        case .movies, .shows, .unwatched: "LIBRARY"
        }
    }
}

/// Library folders, metadata status and maintenance actions.
struct GallerySettingsView: View {
    @ObservedObject var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gallery Library")
                    .font(.system(size: 52, weight: .bold))
                Text(summary)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("LIBRARY FOLDERS")
                if viewModel.roots.isEmpty {
                    row(icon: "server.rack", title: "Entire server", detail: "Every folder is scanned for videos.")
                        .focusable()
                } else {
                    ForEach(viewModel.roots, id: \.self) { root in
                        Button {
                            viewModel.removeRoot(root)
                        } label: {
                            row(icon: "folder.fill", title: root, detail: "Select to remove from the Gallery", trailing: "minus.circle")
                        }
                        .buttonStyle(RowButtonStyle(cornerRadius: 22))
                    }
                }
                Text("To pick folders, press and hold a folder in Browse and choose Add to Gallery.")
                    .font(.system(size: 21))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 24)
            }

            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("METADATA")
                if viewModel.hasMetadata {
                    Button {
                        viewModel.setPrefersEnglishMetadata(!viewModel.prefersEnglishMetadata)
                    } label: {
                        row(
                            icon: "globe",
                            title: "Metadata Language: \(viewModel.prefersEnglishMetadata ? "English" : "System")",
                            detail: "Titles, overviews and posters in \(viewModel.tmdb?.language ?? "en-US"). Select to switch.",
                            trailing: "arrow.left.arrow.right"
                        )
                    }
                    .buttonStyle(RowButtonStyle(cornerRadius: 22))
                    .accessibilityIdentifier("gallery.settings.language")
                }
                row(
                    icon: viewModel.hasMetadata ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    title: viewModel.hasMetadata ? "The Movie Database" : "No TMDB API key",
                    detail: viewModel.hasMetadata
                        ? "Posters, artwork and details in \(viewModel.tmdb?.language ?? "en-US")."
                        : "Copy tvos/Config/TMDB.local.plist.example to AListTV/Resources/TMDB.local.plist."
                )
            }

            HStack(spacing: 24) {
                Button {
                    viewModel.rescan()
                    dismiss()
                } label: {
                    Label("Rescan Library", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(prominence: .primary))
                .disabled(viewModel.isScanning)

                Button {
                    viewModel.refreshMetadata()
                    dismiss()
                } label: {
                    Label("Refresh Metadata", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!viewModel.hasMetadata)
            }
            .padding(.top, 8)
        }
        .padding(60)
        .frame(width: 1100, alignment: .leading)
        .glassPanel(cornerRadius: 44)
    }

    private var summary: String {
        let movies = viewModel.catalog.movies.count
        let shows = viewModel.catalog.shows.count
        var parts = ["\(movies) movie\(movies == 1 ? "" : "s")", "\(shows) show\(shows == 1 ? "" : "s")"]
        if let date = viewModel.lastScan { parts.append("scanned \(GalleryFormat.relative(date).lowercased())") }
        return parts.joined(separator: " · ")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .tracking(2)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 24)
    }

    private func row(icon: String, title: String, detail: String, trailing: String? = nil) -> some View {
        HStack(spacing: 22) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 21))
                    .opacity(0.6)
                    .lineLimit(2)
            }
            Spacer(minLength: 16)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 26, weight: .semibold))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
