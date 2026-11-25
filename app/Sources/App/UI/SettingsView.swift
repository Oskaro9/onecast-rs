import SwiftUI

struct SettingsView: View {
    @AppStorage("showFpsPingCounter") private var showPerfCounter = true
    @AppStorage("audioEnabled") private var audioEnabled = true
    @AppStorage("videoAspectMode") private var aspectMode = VideoAspectMode.fit.rawValue
    @AppStorage("videoUpscaleMode") private var upscaleMode = VideoUpscaleMode.off.rawValue
    @AppStorage("controllerPollHz") private var controllerPollHz = 1000
    @AppStorage("stickDeadzone") private var stickDeadzone = 0.06
    @ObservedObject var authManager: AuthManager

    var body: some View {
        Form {
            Section("Stream") {
                Picker("Aspect mode", selection: $aspectMode) {
                    ForEach(VideoAspectMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Local upscaling", selection: $upscaleMode) {
                    ForEach(VideoUpscaleMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show FPS & Ping counter", isOn: $showPerfCounter)
                Toggle("Enable stream audio", isOn: $audioEnabled)
            }

            Section("Controller") {
                Picker("Polling rate", selection: $controllerPollHz) {
                    Text("120 Hz").tag(120)
                    Text("250 Hz").tag(250)
                    Text("500 Hz").tag(500)
                    Text("1000 Hz").tag(1000)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Analog stick deadzone")
                        Spacer()
                        Text("\(Int(stickDeadzone * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $stickDeadzone, in: 0.0...0.20, step: 0.01)
                }
            }

            if authManager.bundle != nil {
                Section("Account") {
                    Button("Sign Out", role: .destructive) {
                        authManager.signOut()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 340)
    }
}
