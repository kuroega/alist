import Foundation
import SwiftUI

struct ConnectionView: View {
    @ObservedObject var viewModel: ConnectionViewModel
    let submit: @MainActor (String, String, String) async -> Void
    let submitOTP: @MainActor (String) async -> Void
    let retryRecovery: @MainActor () async -> Void

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var otpCode = ""

    init(
        viewModel: ConnectionViewModel,
        submit: @escaping @MainActor (String, String, String) async -> Void,
        submitOTP: @escaping @MainActor (String) async -> Void,
        retryRecovery: @escaping @MainActor () async -> Void
    ) {
        self.viewModel = viewModel
        self.submit = submit
        self.submitOTP = submitOTP
        self.retryRecovery = retryRecovery
        let savedConnection = viewModel.rememberedConnection
        _serverURL = State(initialValue: savedConnection?.baseURL.absoluteString ?? "")
        _username = State(initialValue: savedConnection?.username ?? "")
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("ui-testing"), savedConnection == nil {
            func value(for key: String) -> String {
                let prefix = "\(key)="
                guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return "" }
                return String(argument.dropFirst(prefix.count))
            }
            _serverURL = State(initialValue: value(for: "ui-server"))
            _username = State(initialValue: value(for: "ui-username"))
            _password = State(initialValue: value(for: "ui-password"))
            _otpCode = State(initialValue: value(for: "ui-otp"))
        }
#endif
    }

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case server, username, password, otp }

    var body: some View {
        HStack(alignment: .center, spacing: 120) {
            hero
                .frame(maxWidth: .infinity, alignment: .leading)
            form
                .frame(width: 820)
        }
        .padding(.horizontal, 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground())
        .animation(.easeInOut(duration: 0.25), value: viewModel.state)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 36) {
            BrandMark(size: 132)
            VStack(alignment: .leading, spacing: 14) {
                Text("AList")
                    .font(.system(size: 96, weight: .bold))
                    .tracking(-1)
                Text("Your files and media,\non the big screen.")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(6)
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 34) {
            if viewModel.state == .otpRequired {
                otpForm
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                signInForm
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if case let .failed(message) = viewModel.state {
                errorBanner(message)
                    .transition(.opacity)
            }
        }
        .padding(56)
        .glassPanel(cornerRadius: 44)
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to your server")
                    .font(.system(size: 44, weight: .bold))
                Text("Sign in with your AList account.")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.bottom, 6)

            labeledField("Server") {
                TextField("https://alist.example.com", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .server)
                    .accessibilityIdentifier("connection.server")
            }
            labeledField("Username") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .username)
                    .accessibilityIdentifier("connection.username")
            }
            labeledField("Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .accessibilityIdentifier("connection.password")
            }

            Button {
                Task {
                    await submit(serverURL, username, password)
                    if viewModel.state == .connected { password = "" }
                }
            } label: {
                HStack(spacing: 16) {
                    if viewModel.state == .submitting {
                        ProgressView().controlSize(.small)
                    }
                    Text(viewModel.state == .submitting ? "Connecting…" : "Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(prominence: .primary))
            .disabled(viewModel.state == .submitting)
            .accessibilityIdentifier("connection.connect")
            .padding(.top, 10)
        }
    }

    private var otpForm: some View {
        VStack(alignment: .leading, spacing: 30) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Two-factor authentication")
                    .font(.system(size: 44, weight: .bold))
                Text("Enter the 6-digit code from your authenticator app.")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.secondaryText)
            }

            TextField("One-time code", text: $otpCode)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .otp)
                .onSubmit(verifyOTP)
                .accessibilityIdentifier("connection.otp")

            HStack(spacing: 24) {
                Button("Cancel") {
                    password = ""
                    otpCode = ""
                    viewModel.cancelOTP()
                }
                .buttonStyle(PillButtonStyle())
                Button(action: verifyOTP) {
                    Text(viewModel.state == .submitting ? "Verifying…" : "Verify")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominence: .primary))
                .disabled(viewModel.state == .submitting)
                .accessibilityIdentifier("connection.verify")
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42))
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection.error")
            }
            .font(.system(size: 27, weight: .medium))

            if viewModel.canRetryRecovery {
                Button("Retry session") {
                    Task { await retryRecovery() }
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityIdentifier("connection.retry-session")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1, green: 0.3, blue: 0.3).opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 21, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.leading, 6)
                .accessibilityHidden(true)
            content()
        }
    }

    private func verifyOTP() {
        Task {
            await submitOTP(otpCode)
            otpCode = ""
        }
    }
}
