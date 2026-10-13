import SwiftUI

enum HomeMode: String, CaseIterable, Identifiable {
    case recents
    case browse
    case gallery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recents: "Recents"
        case .browse: "Browse"
        case .gallery: "Gallery"
        }
    }

    var systemImage: String {
        switch self {
        case .recents: "clock.arrow.circlepath"
        case .browse: "folder"
        case .gallery: "film.stack"
        }
    }

    /// Position in the switcher, so content slides in from the side it sits on.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Signed-in shell: a top bar that switches between recently opened files,
/// the folder browser and the media Gallery, with the player presented over all.
struct HomeView: View {
    @ObservedObject var browser: BrowserViewModel
    @ObservedObject var recents: RecentsViewModel
    @ObservedObject var player: PlayerCoordinator
    let gallery: GalleryViewModel
    @ObservedObject var galleryNavigator: GalleryNavigator
    let connection: StoredConnection?
    let onLogout: () -> Void
    let logoutError: String?
    let dismissLogoutError: () -> Void

    @AppStorage("com.alist.tv.home-mode") private var modeRaw = HomeMode.recents.rawValue
    @FocusState private var focusedMode: HomeMode?
    @FocusState private var isSignOutFocused: Bool
    @State private var previousModeOrder = 0

    var body: some View {
        NavigationStack(path: $galleryNavigator.path) {
            home
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: GalleryRoute.self, destination: galleryDestination)
        }
        .onChange(of: player.isPresented) { _, isPresented in
            // The player saves its resume point on dismissal; refresh the bars.
            if !isPresented {
                recents.reload()
                gallery.reloadWatchState()
            }
        }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerView(coordinator: player)
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 18)

            ZStack {
                switch mode {
                case .recents:
                    RecentsView(
                        viewModel: recents,
                        onBrowse: { select(.browse) },
                        onReveal: reveal
                    )
                    .transition(modeTransition)
                case .browse:
                    BrowserView(viewModel: browser, gallery: gallery)
                        .transition(modeTransition)
                case .gallery:
                    GalleryView(viewModel: gallery, onReveal: reveal)
                        .transition(modeTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            ZStack {
                AmbientBackground()
                if mode == .gallery {
                    GalleryBackdrop(spotlight: gallery.spotlight)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: mode)
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
        .onExitCommand(perform: exitAction)
    }

    @ViewBuilder
    private func galleryDestination(_ route: GalleryRoute) -> some View {
        switch route {
        case let .title(title, focusPath):
            GalleryDetailView(viewModel: gallery, title: title, focusPath: focusPath, onReveal: reveal)
        case let .collection(collection):
            GalleryCollectionView(viewModel: gallery, collection: collection)
        }
    }

    /// Content slides in from the side its tab sits on.
    private var modeTransition: AnyTransition {
        let forward = mode.order >= previousModeOrder
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
            removal: .opacity.combined(with: .offset(x: forward ? -40 : 40))
        )
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            HStack(spacing: 24) {
                if let connection {
                    AccountBadge(connection: connection)
                }
                Spacer(minLength: 24)
                Button(action: onLogout) {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(GlassIconButtonStyle(diameter: 64))
                .focused($isSignOutFocused)
                .accessibilityLabel("Sign Out")
                .accessibilityIdentifier("browser.logout")
            }

            HomeModePicker(selection: mode, focusedMode: $focusedMode, onSelect: select)
        }
        .frame(height: 80)
        .focusSection()
    }

    // MARK: Behavior

    private var mode: HomeMode {
        HomeMode(rawValue: modeRaw) ?? .recents
    }

    private func select(_ newMode: HomeMode) {
        guard newMode != mode else { return }
        previousModeOrder = mode.order
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            modeRaw = newMode.rawValue
        }
    }

    private func reveal(_ object: AListObject) {
        browser.reveal(object)
        galleryNavigator.path.removeAll()
        select(.browse)
    }

    /// Menu walks back out the way a tvOS tab app does: up a folder first,
    /// then from content to the top bar, and only then out of the app.
    private var exitAction: (() -> Void)? {
        // While the player covers this screen, Menu must never fall through
        // to the system, or it would dismiss the player instead of its controls.
        if player.isPresented { return {} }
        if mode == .browse && browser.path != "/" { return { browser.moveToParent() } }
        if focusedMode == nil && !isSignOutFocused { return { focusedMode = mode } }
        return nil
    }
}

/// Capsule switcher modeled on the tvOS tab bar. The selected segment keeps a
/// soft fill that glides between options; the focused one turns solid white.
private struct HomeModePicker: View {
    let selection: HomeMode
    var focusedMode: FocusState<HomeMode?>.Binding
    let onSelect: (HomeMode) -> Void

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HomeMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                }
                .buttonStyle(HomeModeSegmentStyle(isSelected: selection == mode, indicator: indicator))
                .focused(focusedMode, equals: mode)
                .accessibilityIdentifier("home.mode.\(mode.rawValue)")
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.25), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .focusSection()
        .defaultFocus(focusedMode, selection, priority: .userInitiated)
    }
}

private struct HomeModeSegmentStyle: ButtonStyle {
    let isSelected: Bool
    let indicator: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, isSelected: isSelected, indicator: indicator)
    }

    private struct SegmentBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let indicator: Namespace.ID
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .labelStyle(SegmentLabelStyle())
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 34)
                .frame(height: 60)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                .background {
                    Capsule()
                        .fill(Color.white)
                        .opacity(isFocused ? 1 : 0)
                }
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1))
                .animation(Theme.focusSpring, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var foreground: Color {
            if isFocused { return .black }
            return isSelected ? .white : Theme.secondaryText
        }
    }

    private struct SegmentLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 12) {
                configuration.icon
                    .font(.system(size: 24, weight: .semibold))
                configuration.title
            }
        }
    }
}

/// Who is signed in to which server, shown quietly in the corner.
private struct AccountBadge: View {
    let connection: StoredConnection

    var body: some View {
        HStack(spacing: 18) {
            Text(initial)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Color(red: 0.30, green: 0.36, blue: 0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.username)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                Text(serverName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signed in as \(connection.username) on \(serverName)")
    }

    private var initial: String {
        connection.username.first.map { String($0).uppercased() } ?? "?"
    }

    private var serverName: String {
        let host = connection.baseURL.host ?? connection.baseURL.absoluteString
        return connection.baseURL.port.map { "\(host):\($0)" } ?? host
    }
}
