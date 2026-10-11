import SwiftUI

/// The files this account opened most recently, newest first, one click from
/// playback.
struct RecentsView: View {
    @ObservedObject var viewModel: RecentsViewModel
    let onBrowse: () -> Void
    let onReveal: (AListObject) -> Void

    @AppStorage("com.alist.tv.recents-list-view") private var isListView = false
    @State private var isClearDialogPresented = false

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
        .onAppear(perform: viewModel.reload)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Most recently opened first")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(height: 34, alignment: .leading)
                Text("Recents")
                    .font(.system(size: 64, weight: .bold))
                    .tracking(-0.5)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 24)

            if !viewModel.entries.isEmpty {
                Text(itemSummary)
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
                .accessibilityIdentifier("recents.view-mode")

                if !viewModel.entries.isEmpty {
                    clearButton
                }
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 72))
            .padding(.bottom, 8)
        }
    }

    private var clearButton: some View {
        Button {
            isClearDialogPresented = true
        } label: {
            Label("Clear Recents", systemImage: "trash")
        }
        .accessibilityLabel("Clear Recents")
        .accessibilityIdentifier("recents.clear")
        .confirmationDialog("Clear Recents?", isPresented: $isClearDialogPresented, titleVisibility: .visible) {
            Button("Clear Recents", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.3)) { viewModel.removeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your files stay on the server. Only this list is cleared.")
        }
    }

    private var itemSummary: String {
        let count = viewModel.entries.count
        return "\(count) \(count == 1 ? "file" : "files")"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.entries.isEmpty {
            emptyState
                .transition(.opacity)
        } else {
            // Re-render once a minute so "5 minutes ago" stays truthful.
            TimelineView(.everyMinute) { context in
                Group {
                    if isListView { list(now: context.date) } else { grid(now: context.date) }
                }
            }
            .transition(.opacity)
        }
    }

    private func grid(now: Date) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(viewModel.entries) { entry in
                    Button {
                        viewModel.open(entry)
                    } label: {
                        RecentCard(entry: entry, now: now)
                    }
                    .buttonStyle(TileButtonStyle())
                    .contextMenu { actions(for: entry) }
                    .accessibilityIdentifier("recents.item.\(entry.id)")
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 24)
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
    }

    private func list(now: Date) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(viewModel.entries) { entry in
                    Button {
                        viewModel.open(entry)
                    } label: {
                        RecentListRow(entry: entry, now: now)
                    }
                    .buttonStyle(RowButtonStyle(cornerRadius: 22))
                    .contextMenu { actions(for: entry) }
                    .accessibilityIdentifier("recents.item.\(entry.id)")
                }
            }
            .padding(.horizontal, Theme.screenPadding - 24)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func actions(for entry: RecentsViewModel.Entry) -> some View {
        Button {
            onReveal(entry.object)
        } label: {
            Label("Show in Folder", systemImage: "folder")
        }
        Button(role: .destructive) {
            withAnimation(.easeInOut(duration: 0.3)) { viewModel.remove(entry) }
        } label: {
            Label("Remove from Recents", systemImage: "minus.circle")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 168, height: 168)
                Circle()
                    .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
                    .frame(width: 168, height: 168)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 68, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, 8)
            .accessibilityHidden(true)

            Text("Nothing here yet")
                .font(.system(size: 40, weight: .semibold))
                .accessibilityIdentifier("recents.empty")
            Text("Videos, music, and other files you open will appear here, most recent first.")
                .font(.system(size: 28))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Button(action: onBrowse) {
                Label("Browse Files", systemImage: "folder")
            }
            .buttonStyle(PillButtonStyle(prominence: .primary))
            .accessibilityIdentifier("recents.browse")
            .padding(.top, 12)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 120)
    }
}

// MARK: - Cells

private struct RecentCard: View {
    let entry: RecentsViewModel.Entry
    let now: Date
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let item = entry.object
        let badge = BrowserFileBadge(item: item)
        VStack(alignment: .leading, spacing: 18) {
            // The resume bar owns the bottom edge, so the extension moves up.
            BrowserArtwork(
                item: item,
                badge: badge,
                isFocused: isFocused,
                extensionAlignment: entry.progress == nil ? .bottomTrailing : .topTrailing
            )
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if let progress = entry.progress {
                        ResumeProgressBar(progress: progress, isFocused: isFocused)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
                }
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
                Text(RecentsFormatting.detail(for: entry, now: now))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(entry.progress == nil ? Theme.tertiaryText : Theme.secondaryText)
                    .lineLimit(1)
                Label(RecentsFormatting.location(for: item), systemImage: "folder")
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 4)
            .offset(y: isFocused ? 12 : 0)
        }
        .animation(Theme.focusSpring, value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(RecentsFormatting.accessibilityValue(for: entry, badge: badge, now: now))
    }
}

private struct RecentListRow: View {
    let entry: RecentsViewModel.Entry
    let now: Date
    @Environment(\.rowIsFocused) private var isFocused

    var body: some View {
        let item = entry.object
        let badge = BrowserFileBadge(item: item)
        HStack(spacing: 28) {
            BrowserArtwork(item: item, badge: badge, isFocused: false, size: .list)
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                Label(RecentsFormatting.location(for: item), systemImage: "folder")
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? Color.black.opacity(0.5) : Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 24)

            HStack(spacing: 40) {
                if let progress = entry.progress {
                    HStack(spacing: 16) {
                        ResumeProgressBar(progress: progress, isFocused: false, onLight: isFocused)
                            .frame(width: 120)
                        if let remaining = entry.remaining {
                            Text(RecentsFormatting.remaining(remaining))
                        }
                    }
                }
                Text(RecentsFormatting.openedAt(entry.openedAt, now: now))
                    .frame(minWidth: 220, alignment: .trailing)
            }
            .font(.system(size: 24, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(isFocused ? Color.black.opacity(0.55) : Theme.secondaryText)
            .lineLimit(1)

            Image(systemName: badge.isPlayable ? "play.fill" : "chevron.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Theme.tertiaryText)
                .frame(width: 30)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(RecentsFormatting.accessibilityValue(for: entry, badge: badge, now: now))
    }
}

/// Thin resume bar in the style of the TV app's "Up Next" row.
private struct ResumeProgressBar: View {
    let progress: Double
    let isFocused: Bool
    var onLight = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(onLight ? Color.black.opacity(0.15) : Color.black.opacity(0.45))
                Capsule()
                    .fill(onLight ? Color.black.opacity(0.7) : (isFocused ? Color.white : Theme.accent))
                    .frame(width: max(proxy.size.height, proxy.size.width * min(max(progress, 0), 1)))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(onLight ? 0 : 0.12), lineWidth: 1))
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 18, weight: .semibold))
            configuration.title
        }
    }
}

enum RecentsFormatting {
    static func openedAt(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func remaining(_ interval: TimeInterval) -> String {
        guard interval >= 60, let text = remainingFormatter.string(from: interval) else {
            return "Under a minute left"
        }
        return "\(text) left"
    }

    /// "2 hours ago · 34 min left", leaving out the remainder when there is
    /// no resume point.
    static func detail(for entry: RecentsViewModel.Entry, now: Date) -> String {
        var parts = [openedAt(entry.openedAt, now: now)]
        if let interval = entry.remaining { parts.append(remaining(interval)) }
        return parts.joined(separator: " · ")
    }

    /// Containing folder, e.g. "Shows / Season 1", or "Home" at the root.
    static func location(for object: AListObject) -> String {
        guard let path = object.virtualPath else { return "Home" }
        let components = AListPath.parent(of: path).split(separator: "/").map(String.init)
        return components.isEmpty ? "Home" : components.joined(separator: " / ")
    }

    static func accessibilityValue(for entry: RecentsViewModel.Entry, badge: BrowserFileBadge, now: Date) -> String {
        [badge.accessibilityDescription, "Opened \(openedAt(entry.openedAt, now: now).lowercased())", entry.remaining.map(remaining), "in \(location(for: entry.object))"]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let remainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter
    }()
}
