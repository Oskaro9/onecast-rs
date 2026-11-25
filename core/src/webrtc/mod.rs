use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket as StdUdpSocket};
use std::time::{Duration, Instant};

use str0m::channel::{ChannelConfig, ChannelId};
use str0m::media::{Direction, MediaData, MediaKind};
use str0m::net::{Protocol, Receive};
use str0m::{Candidate, Event, Input, Output, Rtc};
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, watch};
use tracing::{debug, info, warn};

use crate::api::{IceCandidatePayload, XHomeClient};
use crate::input::{ControllerState, InputEncoder};

/// Callback interface implemented in Swift to receive decoded/depacketized media & state events.
#[uniffi::export(callback_interface)]
pub trait StreamCallbacks: Send + Sync {
    fn on_state_changed(&self, state: StreamState);
    fn on_video_frame(&self, annex_b_data: Vec<u8>, pts_us: u64, is_keyframe: bool);
    fn on_audio_frame(&self, opus_packet: Vec<u8>, pts_us: u64);
    fn on_stats(&self, stats: StreamStats);
    fn on_error(&self, message: String);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StreamState {
    Connecting,
    Provisioning,
    Negotiating,
    Connected,
    Disconnected,
}

#[derive(Debug, Clone, Copy, Default, uniffi::Record)]
pub struct StreamStats {
    pub rtt_ms: f64,
    pub fps: u32,
    pub video_packets_rx: u64,
    pub audio_packets_rx: u64,
}

pub enum EngineCommand {
    RequestKeyframe,
    Stop,
}

/// Discovers a non-loopback local IPv4 address for ICE host candidate generation.
fn local_ipv4() -> Option<IpAddr> {
    let sock = StdUdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect("8.8.8.8:80").ok()?;
    Some(sock.local_addr().ok()?.ip())
}

/// Starts and drives an Xbox Remote Play WebRTC session using `str0m`.
pub async fn run_stream_session(
    api: XHomeClient,
    server_id: String,
    callbacks: Box<dyn StreamCallbacks>,
    mut cmd_rx: mpsc::Receiver<EngineCommand>,
    mut input_rx: watch::Receiver<Option<ControllerState>>,
) {
    let api = Arc::new(api);
    callbacks.on_state_changed(StreamState::Connecting);

    let client_session_id = uuid::Uuid::new_v4().to_string();
    let started = match api.start_session(&server_id, &client_session_id).await {
        Ok(s) => s,
        Err(e) => {
            callbacks.on_error(e.to_string());
            callbacks.on_state_changed(StreamState::Disconnected);
            return;
        }
    };

    let session_path = started.session_path;
    callbacks.on_state_changed(StreamState::Provisioning);

    // Poll until Provisioned.
    let mut provisioned = false;
    for _ in 0..60 {
        match api.poll_session_state(&session_path).await {
            Ok(st) if st.state == "Provisioned" => {
                provisioned = true;
                break;
            }
            Ok(st) if st.state == "Failed" => {
                let msg = st
                    .error_details
                    .and_then(|d| d.message)
                    .unwrap_or_else(|| "Session provisioning failed".to_string());
                callbacks.on_error(msg);
                callbacks.on_state_changed(StreamState::Disconnected);
                return;
            }
            Ok(_) => {}
            Err(e) => {
                callbacks.on_error(e.to_string());
                callbacks.on_state_changed(StreamState::Disconnected);
                return;
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    if !provisioned {
        callbacks.on_error("Timed out waiting for console provisioning".to_string());
        callbacks.on_state_changed(StreamState::Disconnected);
        return;
    }

    callbacks.on_state_changed(StreamState::Negotiating);

    // Bind local UDP socket for str0m WebRTC.
    let bind_addr: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0);
    let socket = match UdpSocket::bind(bind_addr).await {
        Ok(s) => s,
        Err(e) => {
            callbacks.on_error(format!("UDP bind failed: {e}"));
            callbacks.on_state_changed(StreamState::Disconnected);
            return;
        }
    };

    let local_port = socket.local_addr().map(|a| a.port()).unwrap_or(0);
    let host_ip = local_ipv4().unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST));
    let local_addr = SocketAddr::new(host_ip, local_port);

    let mut rtc = Rtc::builder()
        .set_stats_interval(Some(Duration::from_secs(1)))
        .build(Instant::now());
    if let Ok(cand) = Candidate::host(local_addr, "udp") {
        rtc.add_local_candidate(cand);
    }

    // Create SDP offer with video (recvonly), audio (recvonly), and Xbox data channels.
    let mut change = rtc.sdp_api();
    let _video_mid = change.add_media(MediaKind::Video, Direction::RecvOnly, None, None, None);
    let _audio_mid = change.add_media(MediaKind::Audio, Direction::RecvOnly, None, None, None);
    let _control_ch = change.add_channel_with_config(ChannelConfig {
        label: "control".to_string(),
        ordered: true,
        protocol: "controlV1".to_string(),
        ..Default::default()
    });
    let _input_ch = change.add_channel_with_config(ChannelConfig {
        label: "input".to_string(),
        ordered: true,
        protocol: "1.0".to_string(),
        ..Default::default()
    });
    let _message_ch = change.add_channel_with_config(ChannelConfig {
        label: "message".to_string(),
        ordered: true,
        protocol: "messageV1".to_string(),
        ..Default::default()
    });
    let _chat_ch = change.add_channel_with_config(ChannelConfig {
        label: "chat".to_string(),
        ordered: true,
        protocol: "chatV1".to_string(),
        ..Default::default()
    });

    let (offer, pending) = match change.apply() {
        Some(pair) => pair,
        None => {
            callbacks.on_error("Failed to generate WebRTC SDP offer".to_string());
            callbacks.on_state_changed(StreamState::Disconnected);
            return;
        }
    };

    let offer_sdp = offer.to_sdp_string();
    let answer_sdp = match api.exchange_sdp(&session_path, &offer_sdp).await {
        Ok(sdp) => sdp,
        Err(e) => {
            callbacks.on_error(e.to_string());
            callbacks.on_state_changed(StreamState::Disconnected);
            return;
        }
    };

    let answer = match str0m::change::SdpAnswer::from_sdp_string(&answer_sdp) {
        Ok(a) => a,
        Err(e) => {
            callbacks.on_error(format!("Invalid remote SDP answer: {e}"));
            callbacks.on_state_changed(StreamState::Disconnected);
            return;
        }
    };

    if let Err(e) = rtc.sdp_api().accept_answer(pending, answer) {
        callbacks.on_error(format!("Failed to accept SDP answer: {e}"));
        callbacks.on_state_changed(StreamState::Disconnected);
        return;
    }

    // Exchange ICE candidates.
    let local_cand_payload = vec![IceCandidatePayload {
        candidate: format!(
            "candidate:1 1 UDP 2130706431 {} {} typ host",
            local_addr.ip(),
            local_addr.port()
        ),
        message_type: "iceCandidate".to_string(),
        sdp_mid: "0".to_string(),
        sdp_m_line_index: 0,
    }];

    if let Ok(remote_cands) = api.exchange_ice(&session_path, &local_cand_payload).await {
        for rc in remote_cands {
            if let Ok(cand) = Candidate::from_sdp_string(&rc.candidate) {
                rtc.add_remote_candidate(cand);
            }
        }
    }

    // Main Sans-I/O event loop.
    let mut recv_buf = vec![0u8; 65536];
    let mut input_encoder = InputEncoder::new();
    let mut input_channel_id: Option<ChannelId> = None;
    let mut control_channel_id: Option<ChannelId> = None;
    let mut message_channel_id: Option<ChannelId> = None;
    let mut input_ready = false;
    let mut video_packets_rx: u64 = 0;
    let mut audio_packets_rx: u64 = 0;
    let mut video_frames_window: u32 = 0;
    let mut last_rtt_ms: f64 = 0.0;
    let start_instant = Instant::now();
    let mut keepalive_interval = tokio::time::interval(Duration::from_secs(30));
    let mut stats_interval = tokio::time::interval(Duration::from_secs(1));

    loop {
        let timeout = match rtc.poll_output() {
            Ok(Output::Timeout(t)) => t,
            Ok(Output::Transmit(t)) => {
                if let Err(e) = socket.send_to(&t.contents, t.destination).await {
                    warn!("UDP send error: {e}");
                }
                continue;
            }
            Ok(Output::Event(ev)) => {
                match ev {
                    Event::Connected => {
                        info!("WebRTC connected");
                        callbacks.on_state_changed(StreamState::Connected);
                    }
                    Event::IceConnectionStateChange(state) => {
                        debug!("ICE state: {state:?}");
                    }
                    Event::ChannelOpen(id, name) => {
                        info!("DataChannel open: {name}");
                        if name == "input" {
                            input_channel_id = Some(id);
                        } else if name == "control" {
                            control_channel_id = Some(id);
                        } else if name == "message" {
                            message_channel_id = Some(id);
                            if let Some(mut ch) = rtc.channel(id) {
                                let handshake = format!(
                                    r#"{{"type":"Handshake","version":"messageV1","id":"{}","cv":"0"}}"#,
                                    uuid::Uuid::new_v4()
                                );
                                let _ = ch.write(false, handshake.as_bytes());
                            }
                        }
                    }
                    Event::ChannelData(data) => {
                        if Some(data.id) == message_channel_id && !data.binary {
                            if let Ok(text) = std::str::from_utf8(&data.data) {
                                if text.contains("HandshakeAck") {
                                    info!("MessageChannel HandshakeAck received");
                                    if let Some(ctrl_id) = control_channel_id
                                        && let Some(mut ch) = rtc.channel(ctrl_id)
                                    {
                                        let _ = ch.write(
                                            false,
                                            br#"{"message":"authorizationRequest","accessKey":"4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"}"#,
                                        );
                                        let _ = ch.write(
                                            false,
                                            br#"{"message":"gamepadChanged","gamepadIndex":0,"wasAdded":true}"#,
                                        );
                                        let _ = ch.write(
                                            false,
                                            br#"{"message":"videoKeyframeRequested","ifrRequested":true}"#,
                                        );
                                    }
                                    if let Some(in_id) = input_channel_id
                                        && let Some(mut ch) = rtc.channel(in_id)
                                    {
                                        let ts = start_instant.elapsed().as_secs_f64() * 1000.0;
                                        let meta = input_encoder.encode_client_metadata(ts);
                                        let _ = ch.write(true, &meta);
                                        input_ready = true;
                                    }
                                    if let Some(msg_id) = message_channel_id
                                        && let Some(mut ch) = rtc.channel(msg_id)
                                    {
                                        let sys_ui = format!(
                                            r#"{{"type":"Message","content":"{{\"version\":[0,2,0],\"systemUis\":[]}}","id":"{}","target":"/streaming/systemUi/configuration","cv":""}}"#,
                                            uuid::Uuid::new_v4()
                                        );
                                        let _ = ch.write(false, sys_ui.as_bytes());
                                        let orient = format!(
                                            r#"{{"type":"Message","content":"{{\"orientation\":0}}","id":"{}","target":"/streaming/characteristics/orientationchanged","cv":""}}"#,
                                            uuid::Uuid::new_v4()
                                        );
                                        let _ = ch.write(false, orient.as_bytes());
                                        let touch = format!(
                                            r#"{{"type":"Message","content":"{{\"touchInputEnabled\":false}}","id":"{}","target":"/streaming/characteristics/touchinputenabledchanged","cv":""}}"#,
                                            uuid::Uuid::new_v4()
                                        );
                                        let _ = ch.write(false, touch.as_bytes());
                                        let dims = format!(
                                            r#"{{"type":"Message","content":"{{\"horizontal\":1920,\"vertical\":1080,\"preferredWidth\":1920,\"preferredHeight\":1080,\"safeAreaLeft\":0,\"safeAreaTop\":0,\"safeAreaRight\":1920,\"safeAreaBottom\":1080,\"supportsCustomResolution\":true}}","id":"{}","target":"/streaming/characteristics/dimensionschanged","cv":""}}"#,
                                            uuid::Uuid::new_v4()
                                        );
                                        let _ = ch.write(false, dims.as_bytes());
                                    }
                                }
                            }
                        } else {
                            debug!("DataChannel msg ({} bytes)", data.data.len());
                        }
                    }
                    Event::MediaData(MediaData {
                        params,
                        data,
                        time,
                        contiguous,
                        ..
                    }) => {
                        let pts_us = (time.numer().max(0) as u64).saturating_mul(1_000_000)
                            / ((time.denom() as u64).max(1));
                        if params.spec().codec.is_video() {
                            if !contiguous
                                && let Some(ctrl_id) = control_channel_id
                                && let Some(mut ch) = rtc.channel(ctrl_id)
                            {
                                let _ = ch.write(
                                    false,
                                    br#"{"message":"videoKeyframeRequested","ifrRequested":true}"#,
                                );
                            }
                            video_packets_rx += 1;
                            video_frames_window += 1;
                            let is_keyframe = contains_h264_idr(&data);
                            callbacks.on_video_frame(data.to_vec(), pts_us, is_keyframe);
                        } else {
                            audio_packets_rx += 1;
                            callbacks.on_audio_frame(data.to_vec(), pts_us);
                        }
                    }
                    Event::PeerStats(stats) => {
                        if let Some(rtt) = stats.rtt {
                            last_rtt_ms = rtt.as_secs_f64() * 1000.0;
                        }
                    }
                    Event::MediaIngressStats(stats) => {
                        if let Some(rtt) = stats.rtt {
                            last_rtt_ms = rtt.as_secs_f64() * 1000.0;
                        }
                    }
                    _ => {}
                }
                continue;
            }
            Err(e) => {
                callbacks.on_error(format!("WebRTC error: {e}"));
                break;
            }
        };

        let now = Instant::now();
        let wait = timeout.saturating_duration_since(now);

        tokio::select! {
            _ = tokio::time::sleep(wait) => {
                let _ = rtc.handle_input(Input::Timeout(Instant::now()));
            }
            recv_res = socket.recv_from(&mut recv_buf) => {
                match recv_res {
                    Ok((n, source)) => {
                        if let Ok(contents) = Receive::new(Protocol::Udp, source, local_addr, &recv_buf[..n]) {
                            let _ = rtc.handle_input(Input::Receive(Instant::now(), contents));
                        }
                    }
                    Err(e) => {
                        warn!("UDP recv error: {e}");
                    }
                }
            }
            changed = input_rx.changed() => {
                if changed.is_ok() {
                    let state_opt = *input_rx.borrow_and_update();
                    if input_ready
                        && let Some(state) = state_opt
                        && let Some(id) = input_channel_id
                        && let Some(mut ch) = rtc.channel(id)
                    {
                        let ts = start_instant.elapsed().as_secs_f64() * 1000.0;
                        let pkt = input_encoder.encode_gamepad(&state, ts);
                        let _ = ch.write(true, &pkt);
                    }
                }
            }
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(EngineCommand::RequestKeyframe) => {
                        if let Some(id) = control_channel_id
                            && let Some(mut ch) = rtc.channel(id)
                        {
                            let _ = ch.write(
                                false,
                                br#"{"message":"videoKeyframeRequested","ifrRequested":true}"#,
                            );
                        }
                    }
                    Some(EngineCommand::Stop) | None => {
                        break;
                    }
                }
            }
            _ = keepalive_interval.tick() => {
                let api_ref = Arc::clone(&api);
                let path = session_path.clone();
                tokio::spawn(async move {
                    let _ = api_ref.keepalive(&path).await;
                });
            }
            _ = stats_interval.tick() => {
                callbacks.on_stats(StreamStats {
                    rtt_ms: last_rtt_ms,
                    fps: video_frames_window,
                    video_packets_rx,
                    audio_packets_rx,
                });
                video_frames_window = 0;
            }
        }
    }

    if let Some(ctrl_id) = control_channel_id
        && let Some(mut ch) = rtc.channel(ctrl_id)
    {
        let _ = ch.write(
            false,
            br#"{"message":"gamepadChanged","gamepadIndex":0,"wasAdded":false}"#,
        );
        let _ = rtc.poll_output();
    }

    let _ = api.stop_session(&session_path).await;
    callbacks.on_state_changed(StreamState::Disconnected);
}

/// Checks if an Annex-B H.264 buffer contains an IDR slice (NAL type 5).
pub fn contains_h264_idr(data: &[u8]) -> bool {
    let mut i = 0;
    while i + 4 < data.len() {
        if data[i] == 0 && data[i + 1] == 0 {
            let nal_start = if data[i + 2] == 1 {
                i + 3
            } else if i + 3 < data.len() && data[i + 2] == 0 && data[i + 3] == 1 {
                i + 4
            } else {
                i += 1;
                continue;
            };
            if nal_start < data.len() && (data[nal_start] & 0x1F) == 5 {
                return true;
            }
            i = nal_start;
        } else {
            i += 1;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_h264_idr_nal() {
        let idr_frame = [0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84];
        assert!(contains_h264_idr(&idr_frame));

        let p_frame = [0x00, 0x00, 0x00, 0x01, 0x41, 0x9A, 0x22];
        assert!(!contains_h264_idr(&p_frame));
    }

    #[test]
    fn str0m_creates_sdp_offer() {
        let mut rtc = Rtc::builder()
        .set_stats_interval(Some(Duration::from_secs(1)))
        .build(Instant::now());
        let mut change = rtc.sdp_api();
        change.add_media(MediaKind::Video, Direction::RecvOnly, None, None, None);
        change.add_media(MediaKind::Audio, Direction::RecvOnly, None, None, None);
        change.add_channel("input".to_string());
        let (offer, _pending) = change.apply().expect("SDP offer should be generated");
        let sdp = offer.to_sdp_string();
        assert!(sdp.contains("m=video"));
        assert!(sdp.contains("m=audio"));
        assert!(sdp.contains("m=application"));
    }
}
