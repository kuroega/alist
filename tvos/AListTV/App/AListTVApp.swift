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
               let player = container.playerCoordinator {
                BrowserHost(
                    browser: browser,
                    player: player,
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

private struct BrowserHost: View {
    @ObservedObject var browser: BrowserViewModel
    @ObservedObject var player: PlayerCoordinator
    let onLogout: () -> Void
    let logoutError: String?
    let dismissLogoutError: () -> Void

    var body: some View {
        BrowserView(
            viewModel: browser,
            onLogout: onLogout,
            logoutError: logoutError,
            dismissLogoutError: dismissLogoutError,
            isCovered: player.isPresented
        )
            .fullScreenCover(isPresented: $player.isPresented) {
                PlayerView(coordinator: player)
            }
    }
}
