use serde::{Deserialize, Serialize};

use crate::error::OneCastError;

const DEFAULT_CLIENT_ID: &str = "000000004c20a908";
const DEFAULT_REDIRECT_URI: &str = "https://login.live.com/oauth20_desktop.srf";
const OAUTH_SCOPE: &str = "service::user.auth.xboxlive.com::MBI_SSL";

/// Serializable OAuth + Xbox Game Streaming token bundle for Keychain persistence.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AuthBundle {
    pub oauth_access_token: String,
    pub oauth_refresh_token: String,
    pub xsts_token: String,
    pub user_hash: String,
    pub gs_token: String,
    pub expires_in_secs: u64,
}

#[derive(Debug, Deserialize)]
struct OAuthTokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
struct XblAuthRequest<'a> {
    properties: XblAuthProperties<'a>,
    relying_party: &'a str,
    token_type: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
struct XblAuthProperties<'a> {
    auth_method: &'a str,
    site_name: &'a str,
    rps_ticket: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
struct XstsRequest<'a> {
    properties: XstsProperties<'a>,
    relying_party: &'a str,
    token_type: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
struct XstsProperties<'a> {
    sandbox_id: &'a str,
    user_tokens: Vec<&'a str>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct XblTokenResponse {
    token: String,
    display_claims: DisplayClaims,
}

#[derive(Debug, Deserialize)]
struct DisplayClaims {
    xui: Vec<XuiClaim>,
}

#[derive(Debug, Deserialize)]
struct XuiClaim {
    uhs: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GssvLoginRequest<'a> {
    token: &'a str,
    offering_id: &'a str,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GssvLoginResponse {
    gs_token: String,
    duration_in_seconds: Option<u64>,
}

/// Builds the Microsoft OAuth2 authorization URL for `ASWebAuthenticationSession`.
pub fn build_oauth_authorize_url() -> String {
    format!(
        "https://login.live.com/oauth20_authorize.srf?client_id={}&response_type=code&approval_prompt=auto&scope={}&redirect_uri={}",
        DEFAULT_CLIENT_ID,
        url_encode(OAUTH_SCOPE),
        url_encode(DEFAULT_REDIRECT_URI),
    )
}

/// Extracts the `code` query parameter from a Microsoft OAuth redirect URL.
pub fn extract_oauth_code(redirect_url: &str) -> Result<String, OneCastError> {
    let query = redirect_url
        .split_once('?')
        .map(|(_, q)| q)
        .ok_or_else(|| OneCastError::Auth {
            message: "Redirect URL has no query parameters".to_string(),
        })?;

    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=')
            && k == "code"
        {
            return Ok(v.to_string());
        }
    }

    Err(OneCastError::Auth {
        message: "Authorization code not found in redirect URL".to_string(),
    })
}

/// Exchanges an OAuth authorization code for a full `AuthBundle` (OAuth -> XBL -> XSTS -> GSSV).
pub async fn login_with_oauth_code(
    http: &reqwest::Client,
    code: &str,
) -> Result<AuthBundle, OneCastError> {
    let oauth = exchange_oauth_code(http, code).await?;
    complete_xbl_chain(http, &oauth.access_token, oauth.refresh_token.unwrap_or_default(), oauth.expires_in).await
}

/// Refreshes an existing `AuthBundle` using its OAuth refresh token.
pub async fn refresh_auth_bundle(
    http: &reqwest::Client,
    refresh_token: &str,
) -> Result<AuthBundle, OneCastError> {
    let params = [
        ("client_id", DEFAULT_CLIENT_ID),
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
        ("scope", OAUTH_SCOPE),
    ];

    let resp = http
        .post("https://login.live.com/oauth20_token.srf")
        .form(&params)
        .send()
        .await?;

    if !resp.status().is_success() {
        let status = resp.status().as_u16();
        let body = resp.text().await.unwrap_or_default();
        return Err(OneCastError::Api {
            status,
            message: format!("OAuth refresh failed: {body}"),
        });
    }

    let oauth: OAuthTokenResponse = resp.json().await?;
    let next_refresh = oauth
        .refresh_token
        .unwrap_or_else(|| refresh_token.to_string());

    complete_xbl_chain(http, &oauth.access_token, next_refresh, oauth.expires_in).await
}

async fn exchange_oauth_code(
    http: &reqwest::Client,
    code: &str,
) -> Result<OAuthTokenResponse, OneCastError> {
    let params = [
        ("client_id", DEFAULT_CLIENT_ID),
        ("code", code),
        ("grant_type", "authorization_code"),
        ("redirect_uri", DEFAULT_REDIRECT_URI),
        ("scope", OAUTH_SCOPE),
    ];

    let resp = http
        .post("https://login.live.com/oauth20_token.srf")
        .form(&params)
        .send()
        .await?;

    if !resp.status().is_success() {
        let status = resp.status().as_u16();
        let body = resp.text().await.unwrap_or_default();
        return Err(OneCastError::Api {
            status,
            message: format!("OAuth code exchange failed: {body}"),
        });
    }

    Ok(resp.json().await?)
}

async fn complete_xbl_chain(
    http: &reqwest::Client,
    oauth_access_token: &str,
    oauth_refresh_token: String,
    oauth_expires_in: u64,
) -> Result<AuthBundle, OneCastError> {
    // 1. Xbox Live User Token
    let rps_ticket = format!("t={oauth_access_token}");
    let xbl_req = XblAuthRequest {
        properties: XblAuthProperties {
            auth_method: "RPS",
            site_name: "user.auth.xboxlive.com",
            rps_ticket: &rps_ticket,
        },
        relying_party: "http://auth.xboxlive.com",
        token_type: "JWT",
    };

    let xbl_resp = http
        .post("https://user.auth.xboxlive.com/user/authenticate")
        .header("x-xbl-contract-version", "1")
        .json(&xbl_req)
        .send()
        .await?;

    if !xbl_resp.status().is_success() {
        let status = xbl_resp.status().as_u16();
        let body = xbl_resp.text().await.unwrap_or_default();
        return Err(OneCastError::Api {
            status,
            message: format!("XBL user auth failed: {body}"),
        });
    }

    let xbl_token: XblTokenResponse = xbl_resp.json().await?;
    let user_hash = xbl_token
        .display_claims
        .xui
        .first()
        .map(|c| c.uhs.clone())
        .ok_or_else(|| OneCastError::Auth {
            message: "Missing user hash (uhs) in XBL response".to_string(),
        })?;

    // 2. XSTS Token for gssv.xboxlive.com
    let xsts_req = XstsRequest {
        properties: XstsProperties {
            sandbox_id: "RETAIL",
            user_tokens: vec![&xbl_token.token],
        },
        relying_party: "http://gssv.xboxlive.com/",
        token_type: "JWT",
    };

    let xsts_resp = http
        .post("https://xsts.auth.xboxlive.com/xsts/authorize")
        .header("x-xbl-contract-version", "1")
        .json(&xsts_req)
        .send()
        .await?;

    if !xsts_resp.status().is_success() {
        let status = xsts_resp.status().as_u16();
        let body = xsts_resp.text().await.unwrap_or_default();
        return Err(OneCastError::Api {
            status,
            message: format!("XSTS authorize failed: {body}"),
        });
    }

    let xsts_token: XblTokenResponse = xsts_resp.json().await?;

    // 3. xHome GSSV Streaming Token
    let gssv_req = GssvLoginRequest {
        token: &xsts_token.token,
        offering_id: "xhome",
    };

    let gssv_resp = http
        .post("https://xhome.gssv-play-prod.xboxlive.com/v2/login/user")
        .json(&gssv_req)
        .send()
        .await?;

    if !gssv_resp.status().is_success() {
        let status = gssv_resp.status().as_u16();
        let body = gssv_resp.text().await.unwrap_or_default();
        return Err(OneCastError::Api {
            status,
            message: format!("xHome GSSV login failed: {body}"),
        });
    }

    let gssv: GssvLoginResponse = gssv_resp.json().await?;

    Ok(AuthBundle {
        oauth_access_token: oauth_access_token.to_string(),
        oauth_refresh_token,
        xsts_token: xsts_token.token,
        user_hash,
        gs_token: gssv.gs_token,
        expires_in_secs: gssv.duration_in_seconds.unwrap_or(oauth_expires_in),
    })
}

fn url_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char);
            }
            _ => {
                out.push('%');
                out.push_str(&format!("{byte:02X}"));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oauth_url_contains_required_params() {
        let url = build_oauth_authorize_url();
        assert!(url.starts_with("https://login.live.com/oauth20_authorize.srf?"));
        assert!(url.contains("client_id=000000004c20a908"));
        assert!(url.contains("response_type=code"));
        assert!(url.contains("MBI_SSL"));
    }

    #[test]
    fn extract_code_from_redirect() {
        let url = "https://login.live.com/oauth20_desktop.srf?code=M.R3_BAY.12345&lc=1033";
        assert_eq!(extract_oauth_code(url).unwrap(), "M.R3_BAY.12345");
    }

    #[test]
    fn parse_gssv_login_response() {
        let json = r#"{"gsToken":"abc.def.ghi","durationInSeconds":14400}"#;
        let parsed: GssvLoginResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.gs_token, "abc.def.ghi");
        assert_eq!(parsed.duration_in_seconds, Some(14400));
    }
}
