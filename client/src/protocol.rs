//! Wire types for sadl protocol v0. See `docs/protocol.md`.
//!
//! Every message is one line of JSON-RPC 2.0-shaped JSON. Requests and
//! notifications are tagged by `method`; a response carries no method, so its
//! result type is chosen by the caller from the request it answers.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The protocol version this client speaks, sent in the `handshake` request.
pub const PROTOCOL_VERSION: u32 = 0;

/// The `"jsonrpc": "2.0"` marker every message carries. Any other value
/// fails to decode.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum JsonRpc {
    #[default]
    #[serde(rename = "2.0")]
    V2,
}

/// A client → server request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub jsonrpc: JsonRpc,
    pub id: u64,
    #[serde(flatten)]
    pub call: Call,
}

/// A request's `method` and its `params`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum Call {
    #[serde(rename = "handshake")]
    Handshake(HandshakeParams),
    #[serde(rename = "session.open")]
    SessionOpen(SessionOpenParams),
    #[serde(rename = "session.resume")]
    SessionResume(SessionIdParams),
    #[serde(rename = "session.send")]
    SessionSend(SessionSendParams),
    #[serde(rename = "session.cancel")]
    SessionCancel(SessionIdParams),
    #[serde(rename = "session.permit")]
    SessionPermit(SessionPermitParams),
    #[serde(rename = "session.list")]
    SessionList(SessionListParams),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandshakeParams {
    pub protocol_version: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionOpenParams {
    pub cwd: String,
    /// The server's default model is used when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

/// Params of `session.resume` and `session.cancel`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionIdParams {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSendParams {
    pub id: String,
    pub text: String,
}

/// Params of `session.permit`: the answer to the `permission.request` for
/// tool call `call_id`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPermitParams {
    pub id: String,
    pub call_id: String,
    pub decision: Decision,
}

/// Whether a tool call waiting on a `permission.request` may run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Allow,
    Deny,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionListParams {}

/// A server → client response to the request with the same `id`. `T` is the
/// result type of that request's method.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response<T> {
    pub jsonrpc: JsonRpc,
    /// `None` only when the server could not read the request's id.
    pub id: Option<u64>,
    #[serde(flatten)]
    pub outcome: Outcome<T>,
}

/// Either the `result` or the `error` member of a response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome<T> {
    Result(T),
    Error(ErrorObject),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorObject {
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandshakeResult {
    pub protocol_version: u32,
}

/// Result of `session.open` and `session.resume`, and an entry of
/// `session.list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub cwd: String,
    pub model: String,
    /// RFC 3339 UTC timestamp.
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSendResult {
    pub turn_id: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionCancelResult {}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPermitResult {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionListResult {
    pub sessions: Vec<SessionInfo>,
}

/// A server → client notification.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Notification {
    pub jsonrpc: JsonRpc,
    #[serde(flatten)]
    pub event: Event,
}

/// A notification's `method` and its `params`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum Event {
    #[serde(rename = "turn.delta")]
    TurnDelta(TurnDelta),
    #[serde(rename = "tool.call")]
    ToolCall(ToolCall),
    #[serde(rename = "permission.request")]
    PermissionRequest(PermissionRequest),
    #[serde(rename = "tool.result")]
    ToolResult(ToolResult),
    #[serde(rename = "turn.end")]
    TurnEnd(TurnEnd),
    #[serde(rename = "error")]
    Error(SessionError),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnDelta {
    pub session_id: String,
    pub turn_id: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub session_id: String,
    pub turn_id: String,
    pub call_id: String,
    pub name: String,
    /// The tool's arguments, passed through untouched.
    pub args: Map<String, Value>,
}

/// Tool call `call_id` is waiting for a client to answer with
/// `session.permit`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PermissionRequest {
    pub session_id: String,
    pub turn_id: String,
    pub call_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolResult {
    pub session_id: String,
    pub turn_id: String,
    pub call_id: String,
    pub output: String,
    pub is_error: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnEnd {
    pub session_id: String,
    pub turn_id: String,
    pub stop_reason: StopReason,
    pub usage: Usage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    Completed,
    Cancelled,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

/// Params of the `error` notification.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionError {
    pub session_id: String,
    pub code: i64,
    pub message: String,
}

impl Response<Value> {
    /// Decodes the raw `result` as `T`, the result type of the method this
    /// response answers. An `error` outcome converts unchanged.
    pub fn into_typed<T: DeserializeOwned>(self) -> serde_json::Result<Response<T>> {
        let outcome = match self.outcome {
            Outcome::Result(value) => Outcome::Result(serde_json::from_value(value)?),
            Outcome::Error(error) => Outcome::Error(error),
        };
        Ok(Response {
            jsonrpc: self.jsonrpc,
            id: self.id,
            outcome,
        })
    }
}

/// Any server → client message, as read off the socket. A response's result
/// stays raw until the caller, who knows which request it answers, calls
/// [`Response::into_typed`].
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum ServerMessage {
    Response(Response<Value>),
    Notification(Notification),
}

impl ServerMessage {
    /// Decodes one line. A message with a `method` is a notification;
    /// anything else must be a response.
    pub fn decode(line: &str) -> serde_json::Result<Self> {
        let value: Value = serde_json::from_str(line)?;
        if value.get("method").is_some() {
            serde_json::from_value(value).map(Self::Notification)
        } else {
            serde_json::from_value(value).map(Self::Response)
        }
    }
}
