import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var authManager: AuthManager

    var body: some View {
        Group {
            if appState.activeConsole != nil {
                StreamView()
                    .frame(minWidth: 960, minHeight: 540)
            } else if authManager.bundle != nil {
                ConsoleListView(authManager: authManager)
                    .frame(width: 500, height: 360)
            } else {
                SignInView(authManager: authManager)
                    .frame(width: 500, height: 360)
            }
        }
    }
}

struct SignInView: View {
    @ObservedObject var authManager: AuthManager
    @State private var manualRedirectURL = ""
    @State private var showManualEntry = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("OneCastOSS")
                .font(.largeTitle.bold())

            Text("Lightweight Rust + VideoToolbox Xbox Remote Play client for macOS")
                .foregroundStyle(.secondary)

            if let err = authManager.errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button {
                authManager.signIn()
            } label: {
                if authManager.isAuthenticating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign in with Microsoft")
                        .frame(minWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authManager.isAuthenticating)

            Button("Paste Redirect URL Manually") {
                showManualEntry.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)

            if showManualEntry {
                HStack {
                    TextField("https://login.live.com/oauth20_desktop.srf?code=...", text: $manualRedirectURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                    Button("Submit") {
                        Task { await authManager.completeLogin(redirectURL: manualRedirectURL) }
                    }
                    .disabled(manualRedirectURL.isEmpty)
                }
            }
        }
        .padding(40)
    }
}
