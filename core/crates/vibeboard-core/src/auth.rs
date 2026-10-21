//! Device registration and token exchange.
//!
//! ```text
//! message   = deviceID + "|" + timestamp + "|" + nonce
//! signature = lowercase hex(HMAC-SHA256(key = secret, message))
//! ```
//!
//! Endpoints:
//! - `POST {relay}/v1/device/register`  `{mac, hardware, registration_token?}`
//! - `POST {relay}/v1/device/token`     `{device_id, timestamp, nonce, signature}`

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;

pub type Result<T> = std::result::Result<T, AuthError>;

#[derive(Debug)]
pub enum AuthError {
    Transport(String),
    Server { status: u16, body: String },
    InvalidResponse(String),
}

impl std::fmt::Display for AuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AuthError::Transport(e) => write!(f, "network error: {e}"),
            AuthError::Server { status, body } => write!(f, "auth server error {status}: {body}"),
            AuthError::InvalidResponse(e) => write!(f, "invalid auth response: {e}"),
        }
    }
}

impl std::error::Error for AuthError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegisterResult {
    pub device_id: String,
    pub secret: Option<String>,
    pub provisioned: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenResult {
    pub token: String,
    pub expires_at: Option<SystemTime>,
}

pub fn compute_signature(secret: &str, device_id: &str, timestamp: i64, nonce: &str) -> String {
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(format!("{device_id}|{timestamp}|{nonce}").as_bytes());
    hex::encode(mac.finalize().into_bytes())
}

pub struct DeviceAuthClient {
    base_url: String,
    agent: ureq::Agent,
    cached: std::sync::Mutex<Option<(String, Option<SystemTime>)>>,
}

pub const DEFAULT_BASE_URL: &str = "https://torchfun.com";

impl DeviceAuthClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout(Duration::from_secs(25))
            .build();
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            agent,
            cached: std::sync::Mutex::new(None),
        }
    }

    pub fn with_defaults() -> Self {
        Self::new(DEFAULT_BASE_URL)
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub fn register(
        &self,
        mac: &str,
        hardware: &str,
        registration_token: Option<&str>,
    ) -> Result<RegisterResult> {
        let mut body = json!({ "mac": mac, "hardware": hardware });
        if let Some(token) = registration_token {
            body["registration_token"] = json!(token);
        }
        let value = self.post("/v1/device/register", &body)?;

        let device_id = value
            .get("device_id")
            .and_then(Value::as_str)
            .ok_or_else(|| AuthError::InvalidResponse("missing device_id".into()))?
            .to_string();
        let secret = value
            .get("device_secret")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);
        let provisioned = value
            .get("registered")
            .and_then(Value::as_bool)
            .unwrap_or(secret.is_some());

        Ok(RegisterResult {
            device_id,
            secret,
            provisioned,
        })
    }

    /// Returns a cached token while it is more than 60 s away from expiry.
    pub fn valid_token(&self, device_id: &str, secret: &str) -> Result<String> {
        if let Ok(cache) = self.cached.lock() {
            if let Some((token, expires_at)) = cache.as_ref() {
                let fresh = match expires_at {
                    None => true,
                    Some(deadline) => deadline
                        .duration_since(SystemTime::now())
                        .map(|left| left > Duration::from_secs(60))
                        .unwrap_or(false),
                };
                if fresh {
                    return Ok(token.clone());
                }
            }
        }

        let result = self.exchange_token(device_id, secret)?;
        if let Ok(mut cache) = self.cached.lock() {
            *cache = Some((result.token.clone(), result.expires_at));
        }
        Ok(result.token)
    }

    pub fn clear_cached_token(&self) {
        if let Ok(mut cache) = self.cached.lock() {
            *cache = None;
        }
    }

    pub fn exchange_token(&self, device_id: &str, secret: &str) -> Result<TokenResult> {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        let nonce = uuid_v4();
        let signature = compute_signature(secret, device_id, timestamp, &nonce);

        let value = self.post(
            "/v1/device/token",
            &json!({
                "device_id": device_id,
                "timestamp": timestamp,
                "nonce": nonce,
                "signature": signature,
            }),
        )?;

        let token = value
            .get("token")
            .and_then(Value::as_str)
            .ok_or_else(|| AuthError::InvalidResponse("missing token".into()))?
            .to_string();

        let expires_at = ["expiresAt", "expires_at"]
            .iter()
            .find_map(|key| value.get(*key).and_then(Value::as_f64))
            .map(|seconds| UNIX_EPOCH + Duration::from_secs_f64(seconds))
            .or_else(|| {
                value
                    .get("expires_in")
                    .and_then(Value::as_f64)
                    .map(|ttl| SystemTime::now() + Duration::from_secs_f64(ttl))
            });

        Ok(TokenResult { token, expires_at })
    }

    fn post(&self, path: &str, body: &Value) -> Result<Value> {
        let url = format!("{}{}", self.base_url, path);
        let response = self
            .agent
            .post(&url)
            .set("Content-Type", "application/json")
            .send_string(&body.to_string());

        let text = match response {
            Ok(response) => response
                .into_string()
                .map_err(|e| AuthError::Transport(e.to_string()))?,
            Err(ureq::Error::Status(status, response)) => {
                let body = response.into_string().unwrap_or_default();
                let body: String = body.chars().take(300).collect();
                return Err(AuthError::Server { status, body });
            }
            Err(e) => return Err(AuthError::Transport(e.to_string())),
        };

        serde_json::from_str(&text).map_err(|e| {
            AuthError::InvalidResponse(format!(
                "{e}: {}",
                text.chars().take(200).collect::<String>()
            ))
        })
    }
}

/// RFC 4122 v4 UUID, avoiding an extra crate for a single call site.
fn uuid_v4() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let counter = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut seed = [0u8; 32];
    seed[..16].copy_from_slice(&now.as_nanos().to_le_bytes());
    seed[16..24].copy_from_slice(&(std::process::id() as u64).to_le_bytes());
    seed[24..].copy_from_slice(&counter.to_le_bytes());
    // Mix the seed so sequential calls never share a prefix.
    let digest = {
        use sha2::Digest;
        let mut hasher = Sha256::new();
        hasher.update(seed);
        hasher.finalize()
    };
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    let hex = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
    .to_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn signature_matches_reference_client() {
        // Vector produced by the macOS client (and logged by its startup self-test).
        assert_eq!(
            compute_signature("test-secret", "test-device", 1_700_000_000, "nonce-1"),
            "ed66f6280270e54cb0862f534e6c86510ea5344de53eaf941731a036c5d730f2"
        );
    }

    #[test]
    fn uuid_is_unique_and_shaped() {
        let a = uuid_v4();
        let b = uuid_v4();
        assert_ne!(a, b);
        assert_eq!(a.len(), 36);
        assert_eq!(a.as_bytes()[14], b'4');
    }

    /// Serves one HTTP response and returns the request body.
    fn serve_once(status: &str, body: &str) -> (String, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let status = status.to_string();
        let body = body.to_string();
        let handle = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut buffer = [0u8; 8192];
            let mut received = Vec::new();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            loop {
                match socket.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        received.extend_from_slice(&buffer[..n]);
                        if let Some(header_end) = received.windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            let header_end = header_end + 4;
                            let headers =
                                String::from_utf8_lossy(&received[..header_end]).to_lowercase();
                            let content_length = headers
                                .lines()
                                .find_map(|line| line.strip_prefix("content-length:"))
                                .and_then(|value| value.trim().parse::<usize>().ok())
                                .unwrap_or(0);
                            if received.len() >= header_end + content_length {
                                break;
                            }
                        }
                    }
                    Err(_) => break,
                }
            }
            let split = received
                .windows(4)
                .position(|w| w == b"\r\n\r\n")
                .map(|i| i + 4)
                .unwrap_or(0);
            let request_body = String::from_utf8_lossy(&received[split..]).to_string();
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(response.as_bytes());
            request_body
        });
        (format!("http://{addr}"), handle)
    }

    #[test]
    fn register_parses_response() {
        let (url, handle) = serve_once(
            "200 OK",
            r#"{"device_id":"VS-ABC","device_secret":"s3cret","registered":true}"#,
        );
        let client = DeviceAuthClient::new(url);
        let result = client
            .register("DC:A6:32:00:00:01", "vibe_keyboard", None)
            .unwrap();
        assert_eq!(result.device_id, "VS-ABC");
        assert_eq!(result.secret.as_deref(), Some("s3cret"));
        assert!(result.provisioned);

        let body: Value = serde_json::from_str(&handle.join().unwrap()).unwrap();
        assert_eq!(body["mac"], "DC:A6:32:00:00:01");
        assert_eq!(body["hardware"], "vibe_keyboard");
    }

    #[test]
    fn token_sends_signature_and_caches() {
        let (url, handle) = serve_once("200 OK", r#"{"token":"tok-1","expiresAt":4102444800}"#);
        let client = DeviceAuthClient::new(url);
        assert_eq!(client.valid_token("VS-ABC", "s3cret").unwrap(), "tok-1");
        // Second call must be served from cache: the listener only accepts one connection.
        assert_eq!(client.valid_token("VS-ABC", "s3cret").unwrap(), "tok-1");

        let body: Value = serde_json::from_str(&handle.join().unwrap()).unwrap();
        assert_eq!(body["device_id"], "VS-ABC");
        assert_eq!(body["signature"].as_str().unwrap().len(), 64);
        let timestamp = body["timestamp"].as_i64().unwrap();
        let nonce = body["nonce"].as_str().unwrap();
        assert_eq!(
            body["signature"].as_str().unwrap(),
            compute_signature("s3cret", "VS-ABC", timestamp, nonce)
        );
    }

    #[test]
    fn server_error_is_reported() {
        let (url, handle) = serve_once("403 Forbidden", r#"{"error":"denied"}"#);
        let client = DeviceAuthClient::new(url);
        match client.register("mac", "hw", None) {
            Err(AuthError::Server { status, .. }) => assert_eq!(status, 403),
            other => panic!("unexpected {other:?}"),
        }
        let _ = handle.join();
    }
}
