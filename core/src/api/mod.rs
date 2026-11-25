use serde::{Deserialize, Serialize};

use crate::error::OneCastError;

const XHOME_BASE_URL: &str = "https://xhome.gssv-play-prod.xboxlive.com";

/// Target stream resolution preset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum StreamResolution {
    P720,
    P1080,
}

/// Registered Xbox console metadata returned by `/v6/servers/home`.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ConsoleInfo {
    pub server_id: String,
    pub device_name: String,
    pub console_type: String,
    pub power_state: String,
    pub out_of_home_warning: bool,
    pub wireless_warning: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServersResponse {
    results: Vec<ServerResult>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerResult {
    server_id: String,
    device_name: String,
    console_type: Option<String>,
    power_state: Option<String>,
    out_of_home_warning: Option<bool>,
    wireless_warning: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct StartSessionRequest<'a> {
    title_id: &'a str,
    system_update_group: &'a str,
    client_session_id: &'a str,
    settings: SessionSettings,
    server_id: &'a str,
    fallback_region_names: Vec<&'a str>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionSettings {
    nano_version: &'static str,
    enable_text_to_speech: bool,
    high_contrast: u8,
    locale: &'static str,
    use_ice_connection: bool,
    timezone_offset_minutes: i32,
    os_name: &'static str,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStartResponse {
    pub session_path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStateResponse {
    pub state: String,
    pub error_details: Option<SessionErrorDetails>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionErrorDetails {
    pub code: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SdpOfferRequest<'a> {
    message_type: &'static str,
    sdp: &'a str,
    configuration: SdpConfig,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SdpConfig {
    chat_configuration: ChatConfig,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatConfig {
    bytes_per_sample: u8,
    expected_clip_bytes: u16,
    format: &'static str,
    num_channels: u8,
    sample_rate: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SdpPollResponse {
    exchange_response: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SdpAnswerPayload {
    sdp: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IceCandidatePayload {
    pub candidate: String,
    pub message_type: String,
    pub sdp_mid: String,
    pub sdp_m_line_index: u16,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct IceExchangeRequest {
    message_type: &'static str,
    candidate: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IcePollResponse {
    exchange_response: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteIceCandidate {
    pub candidate: String,
    pub sdp_mid: Option<String>,
    pub sdp_m_line_index: Option<u16>,
}

/// REST client for Xbox `xHome` console discovery and WebRTC session signaling.
pub struct XHomeClient {
    http: reqwest::Client,
    gs_token: String,
}

impl XHomeClient {
    pub fn new(http: reqwest::Client, gs_token: String) -> Self {
        Self { http, gs_token }
    }

    pub async fn list_consoles(&self) -> Result<Vec<ConsoleInfo>, OneCastError> {
        let url = format!("{XHOME_BASE_URL}/v6/servers/home");
        let resp = self
            .http
            .get(&url)
            .bearer_auth(&self.gs_token)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            return Err(OneCastError::Api {
                status,
                message: format!("Failed to list consoles: {body}"),
            });
        }

        let parsed: ServersResponse = resp.json().await?;
        Ok(parsed
            .results
            .into_iter()
            .map(|r| ConsoleInfo {
                server_id: r.server_id,
                device_name: r.device_name,
                console_type: r.console_type.unwrap_or_else(|| "Xbox".to_string()),
                power_state: r.power_state.unwrap_or_else(|| "Unknown".to_string()),
                out_of_home_warning: r.out_of_home_warning.unwrap_or(false),
                wireless_warning: r.wireless_warning.unwrap_or(false),
            })
            .collect())
    }

    pub async fn start_session(
        &self,
        server_id: &str,
        client_session_id: &str,
    ) -> Result<SessionStartResponse, OneCastError> {
        let url = format!("{XHOME_BASE_URL}/v5/sessions/home/play");
        let body = StartSessionRequest {
            title_id: "",
            system_update_group: "",
            client_session_id,
            settings: SessionSettings {
                nano_version: "V3;WebrtcTransport.dll",
                enable_text_to_speech: false,
                high_contrast: 0,
                locale: "en-US",
                use_ice_connection: false,
                timezone_offset_minutes: 0,
                os_name: "windows",
            },
            server_id,
            fallback_region_names: vec![],
        };

        let resp = self
            .http
            .post(&url)
            .bearer_auth(&self.gs_token)
            .json(&body)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let text = resp.text().await.unwrap_or_default();
            return Err(OneCastError::Api {
                status,
                message: format!("Failed to start session: {text}"),
            });
        }

        Ok(resp.json().await?)
    }

    pub async fn poll_session_state(
        &self,
        session_path: &str,
    ) -> Result<SessionStateResponse, OneCastError> {
        let url = format!("{XHOME_BASE_URL}/{}/state", session_path.trim_start_matches('/'));
        let resp = self
            .http
            .get(&url)
            .bearer_auth(&self.gs_token)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let text = resp.text().await.unwrap_or_default();
            return Err(OneCastError::Api {
                status,
                message: format!("Failed to poll session state: {text}"),
            });
        }

        Ok(resp.json().await?)
    }

    pub async fn exchange_sdp(
        &self,
        session_path: &str,
        sdp_offer: &str,
    ) -> Result<String, OneCastError> {
        let url = format!("{XHOME_BASE_URL}/{}/sdp", session_path.trim_start_matches('/'));
        let req = SdpOfferRequest {
            message_type: "offer",
            sdp: sdp_offer,
            configuration: SdpConfig {
                chat_configuration: ChatConfig {
                    bytes_per_sample: 2,
                    expected_clip_bytes: 960,
                    format: "opus",
                    num_channels: 1,
                    sample_rate: 24000,
                },
            },
        };

        let resp = self
            .http
            .post(&url)
            .bearer_auth(&self.gs_token)
            .json(&req)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let text = resp.text().await.unwrap_or_default();
            return Err(OneCastError::Api {
                status,
                message: format!("SDP offer failed: {text}"),
            });
        }

        // Poll until the console returns an SDP answer.
        for _ in 0..30 {
            let poll = self
                .http
                .get(&url)
                .bearer_auth(&self.gs_token)
                .send()
                .await?;

            if poll.status().as_u16() == 200 {
                let data: SdpPollResponse = poll.json().await?;
                if let Some(exchange) = data.exchange_response {
                    let answer: SdpAnswerPayload = serde_json::from_str(&exchange)?;
                    return Ok(answer.sdp);
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }

        Err(OneCastError::Session {
            message: "Timed out waiting for remote SDP answer".to_string(),
        })
    }

    pub async fn exchange_ice(
        &self,
        session_path: &str,
        local_candidates: &[IceCandidatePayload],
    ) -> Result<Vec<RemoteIceCandidate>, OneCastError> {
        let url = format!("{XHOME_BASE_URL}/{}/ice", session_path.trim_start_matches('/'));
        for cand in local_candidates {
            let serialized = serde_json::to_string(cand)?;
            let req = IceExchangeRequest {
                message_type: "iceCandidate",
                candidate: serialized,
            };
            let _ = self
                .http
                .post(&url)
                .bearer_auth(&self.gs_token)
                .json(&req)
                .send()
                .await?;
        }

        for _ in 0..20 {
            let poll = self
                .http
                .get(&url)
                .bearer_auth(&self.gs_token)
                .send()
                .await?;

            if poll.status().as_u16() == 200 {
                let data: IcePollResponse = poll.json().await?;
                if let Some(exchange) = data.exchange_response {
                    let candidates: Vec<RemoteIceCandidate> = serde_json::from_str(&exchange)?;
                    return Ok(candidates);
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }

        Ok(Vec::new())
    }

    pub async fn keepalive(&self, session_path: &str) -> Result<(), OneCastError> {
        let url = format!(
            "{XHOME_BASE_URL}/{}/keepalive",
            session_path.trim_start_matches('/')
        );
        let resp = self
            .http
            .post(&url)
            .bearer_auth(&self.gs_token)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            return Err(OneCastError::Api {
                status,
                message: "Session keepalive failed".to_string(),
            });
        }
        Ok(())
    }

    pub async fn stop_session(&self, session_path: &str) -> Result<(), OneCastError> {
        let url = format!("{XHOME_BASE_URL}/{}", session_path.trim_start_matches('/'));
        let _ = self
            .http
            .delete(&url)
            .bearer_auth(&self.gs_token)
            .send()
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_servers_home_response() {
        let json = r#"{
            "results": [{
                "serverId": "F400000000000001",
                "deviceName": "Living Room Xbox",
                "consoleType": "XboxSeriesX",
                "powerState": "ConnectedStandby",
                "outOfHomeWarning": false,
                "wirelessWarning": true
            }]
        }"#;
        let parsed: ServersResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.results.len(), 1);
        assert_eq!(parsed.results[0].device_name, "Living Room Xbox");
        assert_eq!(parsed.results[0].wireless_warning, Some(true));
    }

    #[test]
    fn parse_session_state() {
        let json = r#"{"state":"Provisioned","errorDetails":null}"#;
        let parsed: SessionStateResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.state, "Provisioned");
    }
}
