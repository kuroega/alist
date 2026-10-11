import SwiftUI

struct BrowserView: View {
    @ObservedObject var viewModel: BrowserViewModel

    @FocusState private var focusedPath: String?
    @AppStorage("com.alist.tv.browser-list-view") private var isListView = false
    @AppStorage("com.alist.tv.browser-sort-criterion") private var sortCriterionRaw = BrowserSortCriterion.name.rawValue
    @AppStorage("com.alist.tv.browser-sort-ascending") private var isSortAscending = true
    @State private var isSortDialogPresented = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .focusSection()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
        }
        .onAppear {
            applySort()
            if viewModel.state == .idle { viewModel.loadInitial() }
            // A file revealed from Recents may finish loading before this
            // view mounts, so pick up the pending focus here too.
            if let target = viewModel.focusedVirtualPath { focusedPath = target }
        }
        .onChange(of: sortCriterionRaw) { _, _ in applySort() }
        .onChange(of: isSortAscending) { _, _ in applySort() }
        .onChange(of: focusedPath) { _, value in
            viewModel.focusedVirtualPath = value
            guard let value,
                  let item = viewModel.items.first(where: { $0.virtualPath == value }) else { return }
            viewModel.loadNextPageIfNeeded(currentItem: item)
        }
        .onChange(of: viewModel.focusedVirtualPath) { _, value in
            if value != nil { focusedPath = value }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                breadcrumb
                Text(folderTitle)
                    .font(.system(size: 64, weight: .bold))
                    .tracking(-0.5)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .id(viewModel.path)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.path)

            Spacer(minLength: 24)

            if let summary = itemSummary {
                Text(summary)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
                    .padding(.bottom, 22)
            }

            HStack(spacing: 22) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { isListView.toggle() }
                } label: {
                    Label(isListView ? "Card view" : "List view", systemImage: isListView ? "square.grid.2x2" : "list.bullet")
                }
                .accessibilityLabel(isListView ? "Card view" : "List view")
                .accessibilityIdentifier("browser.view-mode")

                sortButton
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 72))
            .padding(.bottom, 8)
        }
    }

    private var sortButton: some View {
        Button {
            isSortDialogPresented = true
        } label: {
            Label("Sort files", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort files")
        .accessibilityIdentifier("browser.sort")
        .confirmationDialog("Sort files", isPresented: $isSortDialogPresented, titleVisibility: .visible) {
            ForEach(BrowserSortCriterion.allCases, id: \.self) { criterion in
                Button(criterion.title) { sortCriterionRaw = criterion.rawValue }
            }
            Button("Ascending") { isSortAscending = true }
            Button("Descending") { isSortAscending = false }
        } message: {
            Text("Currently sorted by \(currentSortCriterion.title.lowercased()), \(isSortAscending ? "ascending" : "descending").")
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 10) {
            ForEach(Array(breadcrumbComponents.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Text(component)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .opacity(breadcrumbComponents.isEmpty ? 0 : 1)
        .frame(height: 34, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            statusView(icon: nil, title: "Loading", message: nil, identifier: "browser.loading")
        case .empty:
            statusView(icon: "folder", title: "This folder is empty", message: "Press Menu to go back.", identifier: "browser.empty")
        case .failed(let message):
            retryState(icon: "wifi.exclamationmark", title: "Unable to load this folder", message: message)
        case .forbidden where viewModel.items.isEmpty:
            retryState(icon: "lock", title: "No permission", message: "You do not have permission to open this folder.")
        default:
            Group {
                if isListView { list } else { grid }
            }
            .transition(.opacity)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(viewModel.items) { item in
                    Button {
                        viewModel.open(item)
                    } label: {
                        BrowserCard(item: item)
                    }
                    .buttonStyle(TileButtonStyle())
                    .focused($focusedPath, equals: item.virtualPath)
                    .accessibilityIdentifier("browser.item.\(item.virtualPath ?? item.name)")
                    .accessibilityValue(focusedPath == item.virtualPath ? "focused" : "")
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 24)

            paginationStatus
                .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(viewModel.items) { item in
                    Button {
                        viewModel.open(item)
                    } label: {
                        BrowserListRow(item: item)
                    }
                    .buttonStyle(RowButtonStyle(cornerRadius: 22))
                    .focused($focusedPath, equals: item.virtualPath)
                    .accessibilityIdentifier("browser.item.\(item.virtualPath ?? item.name)")
                    .accessibilityValue(focusedPath == item.virtualPath ? "focused" : "")
                }
            }
            .padding(.horizontal, Theme.screenPadding - 24)
            .padding(.top, 12)

            paginationStatus
                .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var paginationStatus: some View {
        switch viewModel.state {
        case .loadingMore:
            HStack(spacing: 16) {
                ProgressView()
                Text("Loading more")
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("browser.loading-more")
        case .loadMoreFailed:
            Button("Retry loading more") { viewModel.retry() }
                .buttonStyle(PillButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("browser.retry-more")
        case .forbidden:
            Button("Permission denied — retry") { viewModel.retry() }
                .buttonStyle(PillButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("browser.retry-forbidden")
        default:
            EmptyView()
        }
    }

    private func retryState(icon: String, title: String, message: String?) -> some View {
        VStack(spacing: 26) {
            statusHeading(icon: icon, title: title, message: message)
            Button("Try Again") { viewModel.retry() }
                .buttonStyle(PillButtonStyle(prominence: .primary))
                .accessibilityIdentifier("browser.retry")
                .padding(.top, 12)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 120)
    }

    /// Non-interactive states stay focusable so the Menu button keeps
    /// reaching this screen's exit handler.
    private func statusView(icon: String?, title: String, message: String?, identifier: String) -> some View {
        statusHeading(icon: icon, title: title, message: message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 120)
            .focusable()
            .focusEffectDisabled()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
    }

    private func statusHeading(icon: String?, title: String, message: String?) -> some View {
        VStack(spacing: 22) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ProgressView()
                    .scaleEffect(1.3)
                    .padding(.bottom, 8)
            }
            Text(title)
                .font(.system(size: 40, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }

    // MARK: Derived

    private var pathComponents: [String] {
        viewModel.path.split(separator: "/").map(String.init)
    }

    private var folderTitle: String { pathComponents.last ?? "Home" }

    private var breadcrumbComponents: [String] {
        guard !pathComponents.isEmpty else { return [] }
        return ["Home"] + pathComponents.dropLast()
    }

    private var itemSummary: String? {
        guard !viewModel.items.isEmpty else { return nil }
        let count = viewModel.items.count
        let suffix = viewModel.hasMore ? "+" : ""
        return "\(count)\(suffix) \(count == 1 ? "item" : "items")"
    }

    private var currentSortCriterion: BrowserSortCriterion {
        BrowserSortCriterion(rawValue: sortCriterionRaw) ?? .name
    }

    private func applySort() {
        viewModel.setSort(criterion: currentSortCriterion, ascending: isSortAscending)
    }
}

/// Removes the system focus treatment so tiles can lift only their artwork,
/// keeping titles steady and legible beneath.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct BrowserCard: View {
    let item: AListObject
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let badge = BrowserFileBadge(item: item)
        VStack(alignment: .leading, spacing: 18) {
            BrowserArtwork(item: item, badge: badge, isFocused: isFocused)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .center) {
                    if badge.isPlayable && isFocused {
                        Image(systemName: "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 72, height: 72)
                            .background(.white, in: Circle())
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.55 : 0.2), radius: isFocused ? 30 : 10, y: isFocused ? 22 : 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.82))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(BrowserItemFormatting.detail(for: item))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .offset(y: isFocused ? 12 : 0)
        }
        .animation(Theme.focusSpring, value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(badge.accessibilityDescription)
    }
}

private struct BrowserListRow: View {
    let item: AListObject
    @Environment(\.rowIsFocused) private var isFocused

    var body: some View {
        let badge = BrowserFileBadge(item: item)
        HStack(spacing: 28) {
            BrowserArtwork(item: item, badge: badge, isFocused: false, size: .list)
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                Text(badge.displayExtension.map { "\(badge.title) · \($0)" } ?? badge.title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? Color.black.opacity(0.5) : Theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 24)

            HStack(spacing: 40) {
                if let date = BrowserItemFormatting.modifiedDate(for: item) {
                    Text(date)
                        .frame(minWidth: 200, alignment: .trailing)
                }
                if !item.isDirectory {
                    Text(BrowserItemFormatting.size(for: item))
                        .frame(minWidth: 140, alignment: .trailing)
                }
            }
            .font(.system(size: 24, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(isFocused ? Color.black.opacity(0.55) : Theme.secondaryText)

            Image(systemName: item.isDirectory ? "chevron.right" : (badge.isPlayable ? "play.fill" : "chevron.right"))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Theme.tertiaryText)
                .frame(width: 30)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(badge.accessibilityDescription)
    }
}

/// Server thumbnail when AList provides one, falling back to the file badge.
struct BrowserArtwork: View {
    let item: AListObject
    let badge: BrowserFileBadge
    let isFocused: Bool
    var size: BrowserFileBadgeView.Size = .card
    var extensionAlignment: Alignment = .bottomTrailing

    var body: some View {
        let fallback = BrowserFileBadgeView(badge: badge, size: size, isFocused: isFocused, extensionAlignment: extensionAlignment)
        if let thumbnail = item.thumbnail, let url = URL(string: thumbnail), !thumbnail.isEmpty {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                                .strokeBorder(.white.opacity(isFocused ? 0.22 : 0.08), lineWidth: 1)
                        )
                        .accessibilityHidden(true)
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }
}

enum BrowserItemFormatting {
    static func detail(for item: AListObject) -> String {
        var parts: [String] = []
        parts.append(item.isDirectory ? "Folder" : size(for: item))
        if let date = modifiedDate(for: item) { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    static func size(for item: AListObject) -> String {
        ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }

    static func modifiedDate(for item: AListObject) -> String? {
        guard let raw = item.modified, let date = parse(raw), date.timeIntervalSince1970 > 86_400 else { return nil }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private static func parse(_ raw: String) -> Date? {
        if let date = fractionalFormatter.date(from: raw) { return date }
        return plainFormatter.date(from: raw)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
