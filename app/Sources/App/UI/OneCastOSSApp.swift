import SwiftUI

@main
struct OneCastOSSApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(authManager: appState.authManager)
                .environmentObject(appState)
        }
        .defaultSize(width: 500, height: 360)
        .windowResizability(.contentSize)
        .windowStyle(.automatic)

        Settings {
            SettingsView(authManager: appState.authManager)
        }
    }
}
