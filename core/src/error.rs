use thiserror::Error;

/// Errors returned by the `onecast-core` engine across the FFI boundary.
#[derive(Debug, Error, uniffi::Error)]
pub enum OneCastError {
    #[error("Authentication error: {message}")]
    Auth { message: String },

    #[error("Network / HTTP error: {message}")]
    Network { message: String },

    #[error("API error (status {status}): {message}")]
    Api { status: u16, message: String },

    #[error("WebRTC error: {message}")]
    WebRtc { message: String },

    #[error("Session error: {message}")]
    Session { message: String },

    #[error("Serialization error: {message}")]
    Serialization { message: String },
}

impl From<reqwest::Error> for OneCastError {
    fn from(err: reqwest::Error) -> Self {
        Self::Network {
            message: err.to_string(),
        }
    }
}

impl From<serde_json::Error> for OneCastError {
    fn from(err: serde_json::Error) -> Self {
        Self::Serialization {
            message: err.to_string(),
        }
    }
}
