import SwiftUI

struct BrowserView: View {
    @ObservedObject var viewModel: BrowserViewModel
    let onLogout: () -> Void
    let logoutError: String?
    let dismissLogoutError: () -> Void


    @FocusState private var focusedPath: String?
    @AppStorage("com.alist.tv.browser-list-view") private var isListView = false
    @AppStorage("com.alist.tv.browser-sort-criterion") private var sortCriterionRaw = BrowserSortCriterion.name.rawValue
    @AppStorage("com.alist.tv.browser-sort-ascending") private var isSortAscending = true
    @State private var isSortDialogPresented = false

    private let gridSpacing: CGFloat = 48
    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 48)
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle, .loading:
                    focusableStatus(title: "Loading…", identifier: "browser.loading")
                case .empty:
                    focusableStatus(title: "Empty folder", identifier: "browser.empty")
                case .failed:
                    retryState(title: "Unable to load this folder")
                case .forbidden where viewModel.items.isEmpty:
                    retryState(title: "You do not have permission to open this folder")
                default:
                    if isListView {
                        list
                    } else {
                        grid
                    }
                }
            }
            .navigationTitle(viewModel.path)
            .toolbar {
                if viewModel.path != "/" {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { viewModel.moveToParent() }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isListView.toggle()
                    } label: {
                        Image(systemName: isListView ? "rectangle.grid.2x2" : "list.bullet")
                    }
                    .accessibilityLabel(isListView ? "Card view" : "List view")
                    .accessibilityIdentifier("browser.view-mode")


                    Button {
                        isSortDialogPresented = true
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort files")
                    .accessibilityIdentifier("browser.sort")
                    Button("Sign Out", action: onLogout)
                        .accessibilityIdentifier("browser.logout")
                }
            }
        }
        .confirmationDialog("Sort files", isPresented: $isSortDialogPresented, titleVisibility: .visible) {
            ForEach(BrowserSortCriterion.allCases, id: \.self) { criterion in
                Button(criterion.title) {
                    sortCriterionRaw = criterion.rawValue
                }
            }
            Button(isSortAscending ? "Descending" : "Ascending") {
                isSortAscending.toggle()
            }
        }
        .alert(
            "Unable to sign out",
            isPresented: Binding(
                get: { logoutError != nil },
                set: { if !$0 { dismissLogoutError() } }
            )
        ) {
            Button("OK", role: .cancel, action: dismissLogoutError)
        } message: {
            Text(logoutError ?? "")
        }
        .onAppear {
            applySort()
            if viewModel.state == .idle { viewModel.loadInitial() }
        }
        .onChange(of: sortCriterionRaw) { _, _ in
            applySort()
        }
        .onChange(of: isSortAscending) { _, _ in
            applySort()
        }
        .onChange(of: focusedPath) { _, value in
            viewModel.focusedVirtualPath = value
            guard let value,
                  let item = viewModel.items.first(where: { $0.virtualPath == value }) else { return }
            viewModel.loadNextPageIfNeeded(currentItem: item)
        }
        .onChange(of: viewModel.focusedVirtualPath) { _, value in
            if value != nil { focusedPath = value }
        }
        .onExitCommand { viewModel.moveToParent() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(viewModel.items) { item in
                    Button {
                        viewModel.open(item)
                    } label: {
                        BrowserCard(item: item)
                    }
                    .buttonStyle(.card)
                    .focused($focusedPath, equals: item.virtualPath)
                    .accessibilityIdentifier("browser.item.\(item.virtualPath ?? item.name)")
                    .accessibilityValue(focusedPath == item.virtualPath ? "focused" : "")
                }

                paginationStatus
            }
            .padding(60)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.items) { item in
                    Button {
                        viewModel.open(item)
                    } label: {
                        BrowserListRow(item: item)
                    }
                    .buttonStyle(.card)
                    .focused($focusedPath, equals: item.virtualPath)
                    .accessibilityIdentifier("browser.item.\(item.virtualPath ?? item.name)")
                    .accessibilityValue(focusedPath == item.virtualPath ? "focused" : "")
                }

                paginationStatus
            }
            .padding(60)
        }
    }

    @ViewBuilder
    private var paginationStatus: some View {
        switch viewModel.state {
        case .loadingMore:
            focusableStatus(title: "Loading more…", identifier: "browser.loading-more")
        case .loadMoreFailed:
            Button("Retry loading more") { viewModel.retry() }
                .accessibilityIdentifier("browser.retry-more")
        case .forbidden:
            Button("Permission denied — retry") { viewModel.retry() }
                .accessibilityIdentifier("browser.retry-forbidden")
        default:
            EmptyView()
        }
    }

    private func retryState(title: String) -> some View {
        VStack(spacing: 28) {
            Text(title).font(.title2)
            Button("Retry") { viewModel.retry() }
                .accessibilityIdentifier("browser.retry")
        }
    }

    private func focusableStatus(title: String, identifier: String) -> some View {
        Button(title) {}
            .accessibilityIdentifier(identifier)
    }

    private func applySort() {
        viewModel.setSort(criterion: BrowserSortCriterion(rawValue: sortCriterionRaw) ?? .name, ascending: isSortAscending)
    }
}

private struct BrowserCard: View {
    let item: AListObject

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrowserFileBadgeView(badge: BrowserFileBadge(item: item), size: .card)
                .frame(height: 170)
                .frame(maxWidth: .infinity)
            Text(item.name)
                .font(.headline)
                .lineLimit(2)
            Text(item.isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .accessibilityLabel(item.name)
        .accessibilityValue(BrowserFileBadge(item: item).accessibilityDescription)
    }
}

private struct BrowserListRow: View {
    let item: AListObject

    var body: some View {
        HStack(spacing: 24) {
            BrowserFileBadgeView(badge: BrowserFileBadge(item: item), size: .list)
                .frame(width: 160, height: 90)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(18)
        .accessibilityLabel(item.name)
        .accessibilityValue(BrowserFileBadge(item: item).accessibilityDescription)
    }
}
