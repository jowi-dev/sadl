//! `sadl -p`: one turn on a session with no TUI, ending in a [`RunOutcome`]
//! for scripts (and later `tm`) to read.
//!
//! [`Run`] is the state machine: server messages in, protocol calls out,
//! like the TUI's app. [`run`] drives it over a [`Link`].

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;

use crate::connection::ConnectError;
use crate::link::{Incoming, Link};
use crate::protocol::{
    Call, ErrorObject, Event, Outcome, Response, ServerMessage, SessionInfo, SessionSendParams,
    SessionSendResult, StopReason, Usage,
};
use crate::start::Start;

/// How a headless run ended. Printed as JSON by `--output-format json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RunOutcome {
    /// The session the turn ran on, once it was opened.
    pub session_id: Option<String>,
    /// The turn's assistant text.
    pub result: String,
    /// Whether the turn completed.
    pub success: bool,
    /// Why the turn stopped, if it ran to its `turn.end`.
    pub stop_reason: Option<StopReason>,
    pub usage: Usage,
    /// What went wrong, when the run did not succeed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pending {
    Start,
    Send,
}

/// One headless turn: opens or resumes the session, sends the prompt and
/// collects the turn's text until it ends.
#[derive(Debug)]
pub struct Run {
    start: Start,
    prompt: Option<String>,
    session_id: Option<String>,
    turn_id: Option<String>,
    text: String,
    errors: Vec<String>,
    pending: HashMap<u64, Pending>,
    outcome: Option<RunOutcome>,
}

impl Run {
    /// A run that sends `prompt` on the session `start` names.
    pub fn new(start: Start, prompt: String) -> Self {
        Self {
            start,
            prompt: Some(prompt),
            session_id: None,
            turn_id: None,
            text: String::new(),
            errors: Vec::new(),
            pending: HashMap::new(),
            outcome: None,
        }
    }

    /// The request that opens or resumes the session; send it first.
    pub fn start_call(&self) -> Call {
        self.start.call()
    }

    /// Records that `call` went out with request id `id`.
    pub fn sent(&mut self, id: u64, call: &Call) {
        let pending = match call {
            Call::SessionSend(_) => Pending::Send,
            _ => Pending::Start,
        };
        self.pending.insert(id, pending);
    }

    /// Handles a message from the server, returning the request it
    /// triggers, if any: the prompt, once the session is open.
    pub fn on_message(&mut self, message: ServerMessage) -> Option<Call> {
        if self.outcome.is_some() {
            return None;
        }
        match message {
            ServerMessage::Response(response) => self.on_response(response),
            ServerMessage::Notification(notification) => {
                self.on_event(notification.event);
                None
            }
        }
    }

    /// The connection was lost and replaced. The turn, if any, is given up:
    /// its remaining events went to the old connection.
    pub fn on_reconnected(&mut self) {
        self.fail("lost the connection to sadld".into());
    }

    /// How the run ended, once it has.
    pub fn outcome(&self) -> Option<&RunOutcome> {
        self.outcome.as_ref()
    }

    fn on_response(&mut self, response: Response<Value>) -> Option<Call> {
        let pending = response.id.and_then(|id| self.pending.remove(&id))?;
        match (pending, response.outcome) {
            (Pending::Start, Outcome::Result(result)) => {
                match serde_json::from_value::<SessionInfo>(result) {
                    Ok(session) => {
                        let id = session.id.clone();
                        self.session_id = Some(session.id);
                        let text = self.prompt.take()?;
                        return Some(Call::SessionSend(SessionSendParams { id, text }));
                    }
                    Err(error) => self.fail(format!("unreadable session from sadld: {error}")),
                }
            }
            (Pending::Start, Outcome::Error(error)) => {
                self.fail(describe("cannot open the session", &error));
            }
            (Pending::Send, Outcome::Result(result)) => {
                match serde_json::from_value::<SessionSendResult>(result) {
                    Ok(sent) => self.turn_id = Some(sent.turn_id),
                    Err(error) => self.fail(format!("unreadable turn from sadld: {error}")),
                }
            }
            (Pending::Send, Outcome::Error(error)) => {
                self.fail(describe("cannot send", &error));
            }
        }
        None
    }

    fn on_event(&mut self, event: Event) {
        let Some(turn_id) = &self.turn_id else {
            return;
        };
        match event {
            Event::TurnDelta(delta) if &delta.turn_id == turn_id => self.text.push_str(&delta.text),
            Event::Error(error) if Some(&error.session_id) == self.session_id.as_ref() => {
                self.errors
                    .push(format!("sadld error ({}): {}", error.code, error.message));
            }
            Event::TurnEnd(end) if &end.turn_id == turn_id => {
                let success = end.stop_reason == StopReason::Completed;
                let error = match (success, self.errors.is_empty()) {
                    (true, _) => None,
                    (false, true) => Some(format!("the turn ended {}", stop_name(end.stop_reason))),
                    (false, false) => Some(self.errors.join("; ")),
                };
                self.outcome = Some(RunOutcome {
                    session_id: self.session_id.clone(),
                    result: std::mem::take(&mut self.text),
                    success,
                    stop_reason: Some(end.stop_reason),
                    usage: end.usage,
                    error,
                });
            }
            _ => {}
        }
    }

    fn fail(&mut self, error: String) {
        self.outcome = Some(RunOutcome {
            session_id: self.session_id.clone(),
            result: std::mem::take(&mut self.text),
            success: false,
            stop_reason: None,
            usage: Usage {
                input_tokens: 0,
                output_tokens: 0,
            },
            error: Some(error),
        });
    }
}

/// Drives `state` over `link` until it ends, and returns how it ended. Fails
/// only if the server rejects the handshake on a reconnect.
pub async fn run(link: &mut Link, mut state: Run) -> Result<RunOutcome, ConnectError> {
    let mut next = Some(state.start_call());
    loop {
        if let Some(call) = next.take() {
            match link.send(call.clone()).await {
                Ok(id) => state.sent(id, &call),
                Err(error) => state.fail(format!("cannot reach sadld: {error}")),
            }
        }
        if let Some(outcome) = state.outcome() {
            return Ok(outcome.clone());
        }
        match link.recv().await? {
            Incoming::Message(message) => next = state.on_message(message),
            Incoming::Reconnected => state.on_reconnected(),
            Incoming::Malformed(_) => {}
        }
    }
}

fn describe(what: &str, error: &ErrorObject) -> String {
    format!("{what} ({}): {}", error.code, error.message)
}

fn stop_name(reason: StopReason) -> &'static str {
    match reason {
        StopReason::Completed => "completed",
        StopReason::Cancelled => "cancelled",
        StopReason::Error => "in an error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{JsonRpc, Notification, SessionError, TurnDelta, TurnEnd};
    use serde_json::json;

    fn respond(run: &mut Run, id: u64, result: Value) -> Option<Call> {
        run.on_message(ServerMessage::Response(Response {
            jsonrpc: JsonRpc::V2,
            id: Some(id),
            outcome: Outcome::Result(result),
        }))
    }

    fn respond_error(run: &mut Run, id: u64, code: i64, message: &str) {
        run.on_message(ServerMessage::Response(Response {
            jsonrpc: JsonRpc::V2,
            id: Some(id),
            outcome: Outcome::Error(ErrorObject {
                code,
                message: message.into(),
                data: None,
            }),
        }));
    }

    fn notify(run: &mut Run, event: Event) {
        run.on_message(ServerMessage::Notification(Notification {
            jsonrpc: JsonRpc::V2,
            event,
        }));
    }

    fn delta(turn_id: &str, text: &str) -> Event {
        Event::TurnDelta(TurnDelta {
            session_id: "s_1".into(),
            turn_id: turn_id.into(),
            text: text.into(),
        })
    }

    fn end(turn_id: &str, stop_reason: StopReason) -> Event {
        Event::TurnEnd(TurnEnd {
            session_id: "s_1".into(),
            turn_id: turn_id.into(),
            stop_reason,
            usage: Usage {
                input_tokens: 12,
                output_tokens: 5,
            },
        })
    }

    fn new_run() -> Run {
        Run::new(
            Start::Open {
                cwd: "/p".into(),
                model: None,
            },
            "hi".into(),
        )
    }

    /// A run whose session `s_1` is open and whose prompt was sent as id 2.
    fn sending() -> Run {
        let mut run = new_run();
        let start = run.start_call();
        run.sent(1, &start);
        let send = respond(
            &mut run,
            1,
            json!({"id": "s_1", "cwd": "/p", "model": "m", "updated_at": "2026-01-01T00:00:00Z"}),
        )
        .expect("the prompt");
        run.sent(2, &send);
        run
    }

    /// A run whose turn `t_1` has started.
    fn running() -> Run {
        let mut run = sending();
        respond(&mut run, 2, json!({"turn_id": "t_1"}));
        run
    }

    #[test]
    fn sends_the_prompt_once_the_session_opens() {
        let mut run = new_run();
        let start = run.start_call();
        run.sent(1, &start);

        let call = respond(
            &mut run,
            1,
            json!({"id": "s_1", "cwd": "/p", "model": "m", "updated_at": "2026-01-01T00:00:00Z"}),
        );

        assert_eq!(
            call,
            Some(Call::SessionSend(SessionSendParams {
                id: "s_1".into(),
                text: "hi".into(),
            }))
        );
        assert_eq!(run.outcome(), None);
    }

    #[test]
    fn a_completed_turn_succeeds_with_its_text_and_usage() {
        let mut run = running();
        notify(&mut run, delta("t_1", "Hel"));
        notify(&mut run, delta("t_1", "lo"));
        notify(&mut run, end("t_1", StopReason::Completed));

        assert_eq!(
            run.outcome(),
            Some(&RunOutcome {
                session_id: Some("s_1".into()),
                result: "Hello".into(),
                success: true,
                stop_reason: Some(StopReason::Completed),
                usage: Usage {
                    input_tokens: 12,
                    output_tokens: 5,
                },
                error: None,
            })
        );
    }

    #[test]
    fn events_of_other_turns_are_ignored() {
        let mut run = sending();
        notify(&mut run, delta("t_0", "before ours"));
        notify(&mut run, end("t_0", StopReason::Completed));
        respond(&mut run, 2, json!({"turn_id": "t_1"}));
        notify(&mut run, delta("t_1", "ours"));
        notify(&mut run, end("t_1", StopReason::Completed));

        assert_eq!(run.outcome().map(|o| o.result.as_str()), Some("ours"));
    }

    #[test]
    fn a_failed_turn_reports_the_server_error() {
        let mut run = running();
        notify(
            &mut run,
            Event::Error(SessionError {
                session_id: "s_1".into(),
                code: -32010,
                message: "provider down".into(),
            }),
        );
        notify(&mut run, end("t_1", StopReason::Error));

        let outcome = run.outcome().expect("ended");
        assert!(!outcome.success);
        assert_eq!(outcome.stop_reason, Some(StopReason::Error));
        assert_eq!(
            outcome.error.as_deref(),
            Some("sadld error (-32010): provider down")
        );
    }

    #[test]
    fn a_cancelled_turn_does_not_succeed() {
        let mut run = running();
        notify(&mut run, end("t_1", StopReason::Cancelled));

        let outcome = run.outcome().expect("ended");
        assert!(!outcome.success);
        assert_eq!(outcome.error.as_deref(), Some("the turn ended cancelled"));
    }

    #[test]
    fn a_rejected_open_fails_the_run() {
        let mut run = Run::new(Start::Resume { id: "s_9".into() }, "hi".into());
        let start = run.start_call();
        run.sent(1, &start);
        respond_error(&mut run, 1, -32002, "session not found");

        let outcome = run.outcome().expect("ended");
        assert!(!outcome.success);
        assert_eq!(outcome.session_id, None);
        assert_eq!(
            outcome.error.as_deref(),
            Some("cannot open the session (-32002): session not found")
        );
    }

    #[test]
    fn a_rejected_send_fails_the_run() {
        let mut run = sending();
        respond_error(&mut run, 2, -32003, "session busy");

        let outcome = run.outcome().expect("ended");
        assert_eq!(outcome.session_id.as_deref(), Some("s_1"));
        assert_eq!(
            outcome.error.as_deref(),
            Some("cannot send (-32003): session busy")
        );
    }

    #[test]
    fn a_lost_connection_fails_the_run_with_what_arrived() {
        let mut run = running();
        notify(&mut run, delta("t_1", "partial"));
        run.on_reconnected();

        let outcome = run.outcome().expect("ended");
        assert!(!outcome.success);
        assert_eq!(outcome.result, "partial");
        assert_eq!(
            outcome.error.as_deref(),
            Some("lost the connection to sadld")
        );
    }

    #[test]
    fn the_outcome_serializes_for_scripts() {
        let mut run = running();
        notify(&mut run, delta("t_1", "done"));
        notify(&mut run, end("t_1", StopReason::Completed));

        assert_eq!(
            serde_json::to_value(run.outcome().unwrap()).unwrap(),
            json!({
                "session_id": "s_1",
                "result": "done",
                "success": true,
                "stop_reason": "completed",
                "usage": {"input_tokens": 12, "output_tokens": 5},
            })
        );
    }
}
