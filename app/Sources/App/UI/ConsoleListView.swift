import OneCastCore
import SwiftUI

struct ConsoleListView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var authManager: AuthManager
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OneCastOSS")
                        .font(.title2.bold())
                    if let controller = appState.controllerManager.connectedControllerName {
                        Label(controller, systemImage: "gamecontroller.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("No controller connected", systemImage: "gamecontroller")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await appState.loadConsoles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh consoles")
                .disabled(appState.isLoadingConsoles)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            .sheet(isPresented: $showSettings) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Settings")
                            .font(.headline)
                        Spacer()
                        Button("Done") { showSettings = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding([.horizontal, .top])
                    SettingsView(authManager: authManager)
                }
            }

            if let error = appState.consoleError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Text("Your Consoles")
                .font(.headline)

            if appState.isLoadingConsoles {
                ProgressView("Discovering consoles...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.consoles.isEmpty {
                ContentUnavailableView(
                    "No Consoles Found",
                    systemImage: "xbox.logo",
                    description: Text("Enable Remote Play on your Xbox and click Refresh.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(appState.consoles, id: \.serverId) { console in
                            HStack {
                                Image(systemName: "xbox.logo")
                                    .font(.title2)
                                    .foregroundStyle(.green)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(console.deviceName)
                                        .font(.headline)
                                    Text("\(console.consoleType) • \(console.powerState)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Connect") {
                                    appState.connect(to: console)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(20)
        .task {
            if appState.consoles.isEmpty {
                await appState.loadConsoles()
            }
        }
    }
}
