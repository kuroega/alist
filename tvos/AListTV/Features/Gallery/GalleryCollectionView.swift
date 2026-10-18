import SwiftUI

/// "See All" wall for one collection (Movies, TV Shows, Unwatched, a genre or Un-indexed).
struct GalleryCollectionView: View {
    @ObservedObject var viewModel: GalleryViewModel
    let collection: GalleryCollection
    let onReveal: (AListObject) -> Void

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
                                .contextMenu { GalleryTitleMenu(viewModel: viewModel, title: title, onReveal: onReveal) }
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
        case .unindexed: "NO EXACT TMDB MATCH"
        case .movies, .shows, .unwatched: "LIBRARY"
        }
    }
}

/// Library folders, metadata status and maintenance actions.
struct GallerySettingsView: View {
    @ObservedObject var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isCleanUpConfirmationPresented = false

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
                Text("To pick folders, press and hold a folder in Browse and choose Add to Gallery. To leave a folder or video out, press and hold it and choose Exclude. Updates list only folders that changed; Rescan All lists every one.")
                    .font(.system(size: 21))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 24)
            }

            if !viewModel.excluded.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("EXCLUDED")
                    ForEach(viewModel.excluded, id: \.self) { path in
                        Button {
                            viewModel.include(path)
                        } label: {
                            row(icon: "eye.slash", title: path, detail: "Select to include in the Gallery again", trailing: "plus.circle")
                        }
                        .buttonStyle(RowButtonStyle(cornerRadius: 22))
                    }
                }
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
                    viewModel.updateLibrary()
                    dismiss()
                } label: {
                    Label("Update Library", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(prominence: .primary))
                .disabled(viewModel.isScanning)
                .accessibilityIdentifier("gallery.settings.update")

                Button {
                    viewModel.rescanAllFolders()
                    dismiss()
                } label: {
                    Label("Rescan All", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(viewModel.isScanning)
                .accessibilityIdentifier("gallery.settings.rescan")

                Button {
                    isCleanUpConfirmationPresented = true
                } label: {
                    Label("Clean Up & Refresh", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!viewModel.hasMetadata)
                .accessibilityIdentifier("gallery.settings.clean-up")
                .confirmationDialog(
                    "Clean up all metadata?",
                    isPresented: $isCleanUpConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Clean Up & Refresh", role: .destructive) {
                        viewModel.cleanUpAndRefreshMetadata()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every TMDB match, cached response and poster is deleted, then every title is looked up on TMDB again. Your videos and watch history are kept.")
                }
            }
            .padding(.top, 8)
        }
        .padding(60)
        .frame(width: 1280, alignment: .leading)
        .glassPanel(cornerRadius: 44)
    }

    private var summary: String {
        let movies = viewModel.shelves.movies.count
        let shows = viewModel.shelves.shows.count
        let unindexed = viewModel.shelves.unindexed.count
        var parts = ["\(movies) movie\(movies == 1 ? "" : "s")", "\(shows) show\(shows == 1 ? "" : "s")"]
        if unindexed > 0 { parts.append("\(unindexed) un-indexed") }
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
