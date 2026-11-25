import OneCastCore
import SwiftUI

struct StreamView: View {
    @EnvironmentObject var appState: AppState
    @State private var showHUD = true
    @State private var showQuickSettings = false
    @AppStorage("showFpsPingCounter") private var showPerfCounter = true
    @AppStorage("audioEnabled") private var audioEnabled = true
    @AppStorage("videoAspectMode") private var aspectModeRaw = VideoAspectMode.fit.rawValue
    @AppStorage("videoUpscaleMode") private var upscaleModeRaw = VideoUpscaleMode.off.rawValue

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoDecoderView(
                coordinatorRef: appState.videoCoordinator,
                aspectMode: VideoAspectMode(rawValue: aspectModeRaw) ?? .fit,
                upscaleMode: VideoUpscaleMode(rawValue: upscaleModeRaw) ?? .off
            )
            .ignoresSafeArea()

            if appState.streamState != .connected {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(statusLabel)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let err = appState.streamError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            VStack {
                HStack(alignment: .top) {
                    if showHUD {
                        HStack(spacing: 10) {
                            Text(appState.activeConsole?.deviceName ?? "Xbox")
                                .font(.headline)
                            Text("• Pad: \(appState.controllerManager.connectedControllerName ?? "None") [\(appState.controllerManager.lastButtonsHex)]")
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if showPerfCounter {
                            HStack(spacing: 10) {
                                Label("\(appState.streamStats.fps) FPS", systemImage: "film")
                                    .foregroundStyle(appState.streamStats.fps >= 50 ? .green : .yellow)
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Label(pingText, systemImage: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(pingColor)
                            }
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        }

                        if showHUD {
                            Button {
                                showPerfCounter.toggle()
                            } label: {
                                Label(showPerfCounter ? "Hide FPS" : "Show FPS", systemImage: "speedometer")
                            }
                            .buttonStyle(.bordered)
                            .keyboardShortcut("i", modifiers: .command)

                            Button {
                                showQuickSettings.toggle()
                            } label: {
                                Image(systemName: "gearshape.fill")
                            }
                            .buttonStyle(.bordered)
                            .help("Stream Settings")
                            .popover(isPresented: $showQuickSettings, arrowEdge: .top) {
                                SettingsView(authManager: appState.authManager)
                            }

                            Button("Disconnect") {
                                appState.disconnect()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }
                .padding()
                Spacer()
            }
        }
        .onChange(of: upscaleModeRaw) { _, _ in
            appState.core.requestKeyframe()
        }
        .onChange(of: audioEnabled) { _, enabled in
            appState.setAudioEnabled(enabled)
        }
        .onTapGesture {
            showHUD.toggle()
        }
        .onChange(of: audioEnabled) { _, enabled in
            if enabled {
                if appState.streamState == .connected || appState.streamState == .connecting {
                    appState.audioPlayer.start()
                }
            } else {
                appState.audioPlayer.stop()
            }
        }
    }

    private var pingText: String {
        let rtt = appState.streamStats.rttMs
        return rtt > 0 ? String(format: "%.0f ms", rtt) : "-- ms"
    }

    private var pingColor: Color {
        let rtt = appState.streamStats.rttMs
        if rtt <= 0 { return .secondary }
        if rtt < 30 { return .green }
        if rtt < 70 { return .yellow }
        return .red
    }

    private var statusLabel: String {
        switch appState.streamState {
        case .connecting: return "Starting Remote Play session..."
        case .provisioning: return "Waking & provisioning console..."
        case .negotiating: return "Negotiating WebRTC..."
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}
