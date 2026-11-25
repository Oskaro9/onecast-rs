use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::runtime::Runtime;
use tokio::sync::{mpsc, watch};

use crate::api::{ConsoleInfo, XHomeClient};
use crate::auth::{self, AuthBundle};
use crate::error::OneCastError;
use crate::input::ControllerState;
use crate::webrtc::{self, EngineCommand, StreamCallbacks};

/// Main thread-safe handle exposed to Swift via UniFFI.
#[derive(uniffi::Object)]
pub struct OneCastCore {
    runtime: Runtime,
    http: reqwest::Client,
    active_cmd_tx: Mutex<Option<mpsc::Sender<EngineCommand>>>,
    active_input_tx: Mutex<Option<watch::Sender<Option<ControllerState>>>>,
}

#[uniffi::export]
impl OneCastCore {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, OneCastError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("onecast-core")
            .build()
            .map_err(|e| OneCastError::Session {
                message: format!("Failed to create Tokio runtime: {e}"),
            })?;

        let http = reqwest::Client::builder()
            .user_agent("OneCastOSS/0.1")
            .timeout(Duration::from_secs(15))
            .build()?;

        Ok(Arc::new(Self {
            runtime,
            http,
            active_cmd_tx: Mutex::new(None),
            active_input_tx: Mutex::new(None),
        }))
    }

    pub fn oauth_authorize_url(&self) -> String {
        auth::build_oauth_authorize_url()
    }

    pub fn login_with_redirect_url(&self, redirect_url: String) -> Result<AuthBundle, OneCastError> {
        let code = auth::extract_oauth_code(&redirect_url)?;
        self.runtime
            .block_on(auth::login_with_oauth_code(&self.http, &code))
    }

    pub fn refresh_auth(&self, refresh_token: String) -> Result<AuthBundle, OneCastError> {
        self.runtime
            .block_on(auth::refresh_auth_bundle(&self.http, &refresh_token))
    }

    pub fn list_consoles(&self, gs_token: String) -> Result<Vec<ConsoleInfo>, OneCastError> {
        let client = XHomeClient::new(self.http.clone(), gs_token);
        self.runtime.block_on(client.list_consoles())
    }

    pub fn start_stream(
        &self,
        gs_token: String,
        server_id: String,
        callbacks: Box<dyn StreamCallbacks>,
    ) -> Result<(), OneCastError> {
        self.stop_stream();

        let (tx, rx) = mpsc::channel(32);
        let (input_tx, input_rx) = watch::channel(None);
        {
            let mut guard = self.active_cmd_tx.lock().unwrap();
            *guard = Some(tx);
            let mut in_guard = self.active_input_tx.lock().unwrap();
            *in_guard = Some(input_tx);
        }

        let client = XHomeClient::new(self.http.clone(), gs_token);
        self.runtime.spawn(async move {
            webrtc::run_stream_session(client, server_id, callbacks, rx, input_rx).await;
        });

        Ok(())
    }

    pub fn send_controller_state(&self, state: ControllerState) {
        if let Ok(guard) = self.active_input_tx.lock()
            && let Some(tx) = guard.as_ref()
        {
            let _ = tx.send(Some(state));
        }
    }

    pub fn request_keyframe(&self) {
        if let Ok(guard) = self.active_cmd_tx.lock()
            && let Some(tx) = guard.as_ref()
        {
            let _ = tx.try_send(EngineCommand::RequestKeyframe);
        }
    }

    pub fn stop_stream(&self) {
        if let Ok(mut in_guard) = self.active_input_tx.lock() {
            *in_guard = None;
        }
        if let Ok(mut guard) = self.active_cmd_tx.lock()
            && let Some(tx) = guard.take()
        {
            let _ = tx.try_send(EngineCommand::Stop);
        }
    }
}
