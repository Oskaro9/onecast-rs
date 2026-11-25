# OneCast OSS (`onecast-rs`)

A high-performance, open-source macOS alternative to OneCast for Xbox Remote Play, built from scratch using a **Rust** WebRTC engine and a native **SwiftUI + VideoToolbox + MetalFX** macOS frontend.

## Features

- **Ultra-low latency streaming**: Real-time H.264 video hardware decoding via `VideoToolbox` (`AVSampleBufferDisplayLayer`).
- **Apple Silicon MetalFX Spatial Upscaling**: Native `MTLFXSpatialScaler` pipeline to upscale 1080p stream to high-DPI Retina resolution with sharp detail and zero artifacts.
- **Opus Audio Decoding**: Low-latency PCM streaming powered by `AVAudioEngine` and `AVAudioConverter`.
- **1000Hz Gamepad Polling**: Sub-millisecond controller input reporting using direct `IOHIDManager` and `GameController` frameworks, specifically optimized for high-polling gamepads like the **8BitDo Ultimate 2 Wireless** and standard Xbox/PlayStation controllers.
- **Multiple Aspect Ratio Modes**:
  - `Fit (16:9)`: Classic letterboxed aspect ratio.
  - `Fill (16:10)`: Stretches cleanly to modern MacBook 16:10 displays without cropping the HUD or game canvas.
  - `Zoom`: Aspect-fill mode.
- **Live Stream HUD**: Toggleable overlay showing real-time FPS and round-trip ping (RTT).
- **Streamlined Compact UI**: Opens in a compact `500x360` window on launch, seamlessly expanding when entering a stream.

## Architecture

- **`core/` (Rust)**:
  - `webrtc`: `str0m 0.26` Sans-I/O WebRTC state machine handling UDP transport, SCTP DataChannels (`controlV1`, `1.0`, `messageV1`), RTP jitter buffering, and IDR keyframe detection.
  - `input`: Binary Xbox input encoder constructing 38-byte frames (14-byte report header + 23-byte gamepad payload) fed by a non-blocking `tokio::sync::watch` channel.
  - `auth`: Microsoft OAuth2 device authorization, Xbox Live (user & device token), XSTS token exchange, and GSSV streaming token negotiation.
  - `api`: `xHome` session signaling, server discovery, ICE candidate exchange, and background keepalive.
  - `ffi`: Clean UniFFI 0.32 exports to Swift.
- **`app/` (Swift / SwiftUI)**:
  - `Sources/App/Media/`: Video decoding, MetalFX spatial upscaler, and audio playback.
  - `Sources/App/Input/`: Dual `IOHIDManager` + `GCController` input polling pipeline.
  - `Sources/App/UI/`: SwiftUI navigation, console selection, stream HUD, and preferences.

## Building from Source

### Prerequisites

- macOS 14.0+ (Sonoma or Sequoia) on Apple Silicon (arm64)
- Xcode 15+ / Swift 5.9+
- Rust 1.80+ with `aarch64-apple-darwin` target

### Build Steps

```bash
# 1. Compile the Rust core and generate UniFFI Swift bindings
./scripts/build-rust.sh

# 2. Build the Swift application
cd app
swift build -c release

# 3. Run unit tests
swift test
cd ../core && cargo test
```

## License

MIT OR Apache-2.0
