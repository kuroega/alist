import SwiftUI

@main
struct AListTVApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            AppRootView(container: container)
        }
    }
}

private struct AppRootView: View {
    @ObservedObject var container: AppContainer

    var body: some View {
        ZStack {
            if container.isRestoringSession {
                LaunchView()
                    .transition(.opacity)
            } else {
                routeContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: container.isRestoringSession)
        .animation(.easeInOut(duration: 0.35), value: container.route)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .defaultAppStorage(container.appStorage)
        .task { await container.restoreSession() }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch container.route {
        case .connection:
            ConnectionView(
                viewModel: container.connectionViewModel,
                submit: { serverURL, username, password in
                    await container.submit(serverURL: serverURL, username: username, password: password)
                },
                submitOTP: { code in await container.submitOTP(code) },
                retryRecovery: { await container.retrySessionRecovery() }
            )
        case .browser:
            if let browser = container.browserViewModel,
               let recents = container.recentsViewModel,
               let gallery = container.galleryViewModel,
               let player = container.playerCoordinator {
                HomeView(
                    browser: browser,
                    recents: recents,
                    player: player,
                    gallery: gallery,
                    galleryNavigator: gallery.navigator,
                    connection: container.connectionViewModel.activeConnection,
                    onLogout: container.logout,
                    logoutError: container.logoutError,
                    dismissLogoutError: container.dismissLogoutError
                )
            } else {
                LaunchView()
            }
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 40) {
            BrandMark(size: 150)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground())
    }
}
