import Foundation
import OneCastCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let core: OneCastCore
    let authManager: AuthManager
    let controllerManager = ControllerManager()
    let videoCoordinator = VideoRenderCoordinator()
    let audioPlayer = AudioPlayer()

    @Published var consoles: [ConsoleInfo] = []
    @Published var isLoadingConsoles = false
    @Published var consoleError: String?

    @Published var activeConsole: ConsoleInfo?
    @Published var streamState: StreamState = .disconnected
    @Published var streamStats = StreamStats(rttMs: 0, fps: 0, videoPacketsRx: 0, audioPacketsRx: 0)
    @Published var streamError: String?

    private var callbackBridge: CallbackBridge?

    init() {
        do {
            self.core = try OneCastCore()
        } catch {
            fatalError("Failed to initialize OneCastCore: \(error)")
        }
        self.authManager = AuthManager(core: core)
    }

    func loadConsoles() async {
        guard let gsToken = authManager.bundle?.gsToken else { return }
        isLoadingConsoles = true
        consoleError = nil
        do {
            let coreRef = core
            let list = try await Task.detached(priority: .userInitiated) {
                try coreRef.listConsoles(gsToken: gsToken)
            }.value
            consoles = list
        } catch {
            consoleError = error.localizedDescription
        }
        isLoadingConsoles = false
    }

    func connect(to console: ConsoleInfo) {
        guard let gsToken = authManager.bundle?.gsToken else { return }
        activeConsole = console
        streamError = nil
        streamState = .connecting

        let audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
        if audioEnabled {
            audioPlayer.start()
        }
        let coreRef = core
        controllerManager.startPolling { state in
            coreRef.sendControllerState(state: state)
        }

        let bridge = CallbackBridge(appState: self, video: videoCoordinator, audio: audioPlayer)
        self.callbackBridge = bridge

        do {
            try core.startStream(
                gsToken: gsToken,
                serverId: console.serverId,
                callbacks: bridge
            )
        } catch {
            streamError = error.localizedDescription
            disconnect()
        }
    }

    func disconnect() {
        core.stopStream()
        controllerManager.stopPolling()
        audioPlayer.stop()
        videoCoordinator.reset()
        activeConsole = nil
        streamState = .disconnected
        callbackBridge = nil
    }

    func setAudioEnabled(_ enabled: Bool) {
        if enabled {
            audioPlayer.start()
        } else {
            audioPlayer.stop()
        }
    }
}

/// Thread-safe bridge receiving callbacks from Rust's Tokio runtime.
private final class CallbackBridge: StreamCallbacks, @unchecked Sendable {
    private weak var appState: AppState?
    private let video: VideoRenderCoordinator
    private let audio: AudioPlayer

    init(appState: AppState, video: VideoRenderCoordinator, audio: AudioPlayer) {
        self.appState = appState
        self.video = video
        self.audio = audio
    }

    func onStateChanged(state: StreamState) {
        Task { @MainActor [weak appState] in
            appState?.streamState = state
        }
    }

    func onVideoFrame(annexBData: Data, ptsUs: UInt64, isKeyframe: Bool) {
        video.enqueueAnnexBFrame(annexBData, ptsUs: ptsUs)
    }

    func onAudioFrame(opusPacket: Data, ptsUs: UInt64) {
        audio.enqueueOpusPacket(opusPacket)
    }

    func onStats(stats: StreamStats) {
        Task { @MainActor [weak appState] in
            appState?.streamStats = stats
        }
    }

    func onError(message: String) {
        Task { @MainActor [weak appState] in
            appState?.streamError = message
        }
    }
}
