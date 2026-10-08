//! The TUI's state machine: keys and server messages in, protocol calls out.
//! It knows nothing about the terminal or the socket, so it can be driven
//! directly in tests.

use std::collections::HashMap;

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::protocol::{
    Call, ErrorObject, Event, Outcome, Response, ServerMessage, SessionIdParams, SessionInfo,
    SessionOpenParams, SessionSendParams, Usage,
};
use crate::tui::input::Input;
use crate::tui::transcript::Transcript;
use serde_json::Value;

/// Text kept in the scrollback before the oldest blocks are dropped. Sized
/// to keep an idle client well under its 50 MB RSS budget.
pub const MAX_TRANSCRIPT_BYTES: usize = 8 * 1024 * 1024;

/// Lines scrolled per PageUp/PageDown when the view height is unknown.
const DEFAULT_PAGE: usize = 10;

/// What a request this client sent was for, so its response can be handled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pending {
    Open,
    Resume,
    Send,
    Cancel,
    Other,
}

/// Everything the TUI draws, plus the requests it is waiting on.
#[derive(Debug)]
pub struct App {
    pub transcript: Transcript,
    pub input: Input,
    /// The session being shown, once the server has opened it.
    pub session: Option<SessionInfo>,
    /// Token totals over every turn this client has seen end.
    pub usage: Usage,
    /// Whether a turn is in progress.
    pub running: bool,
    /// Whether tool blocks show their arguments and output.
    pub expand_tools: bool,
    /// How many lines the transcript is scrolled up from the bottom.
    pub scroll: usize,
    /// Height of the transcript view at the last draw, for paging.
    pub page: usize,
    cwd: String,
    model: Option<String>,
    pending: HashMap<u64, Pending>,
    quit: bool,
}

impl App {
    /// An app that will open a new session in `cwd`, with the server's
    /// default model unless `model` is given.
    pub fn new(cwd: String, model: Option<String>) -> Self {
        Self {
            transcript: Transcript::new(MAX_TRANSCRIPT_BYTES),
            input: Input::default(),
            session: None,
            usage: Usage {
                input_tokens: 0,
                output_tokens: 0,
            },
            running: false,
            expand_tools: false,
            scroll: 0,
            page: DEFAULT_PAGE,
            cwd,
            model,
            pending: HashMap::new(),
            quit: false,
        }
    }

    /// The request that opens this app's session; send it first.
    pub fn open_call(&self) -> Call {
        Call::SessionOpen(SessionOpenParams {
            cwd: self.cwd.clone(),
            model: self.model.clone(),
        })
    }

    /// Records that `call` went out with request id `id`.
    pub fn sent(&mut self, id: u64, call: &Call) {
        let pending = match call {
            Call::SessionOpen(_) => Pending::Open,
            Call::SessionResume(_) => Pending::Resume,
            Call::SessionSend(_) => Pending::Send,
            Call::SessionCancel(_) => Pending::Cancel,
            Call::Handshake(_) | Call::SessionList(_) | Call::SessionPermit(_) => Pending::Other,
        };
        self.pending.insert(id, pending);
    }

    /// Handles a key press, returning the request it triggers, if any.
    ///
    /// Enter sends the prompt; Alt+Enter, Shift+Enter or Ctrl+J insert a
    /// newline. Esc cancels the running turn. Ctrl+O expands or collapses
    /// tool blocks. PageUp/PageDown scroll the transcript. Ctrl+C clears the
    /// input, or quits when it is already empty.
    pub fn on_key(&mut self, key: KeyEvent) -> Option<Call> {
        if key.kind == KeyEventKind::Release {
            return None;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let newline = KeyModifiers::ALT | KeyModifiers::SHIFT;
        match key.code {
            KeyCode::Enter if key.modifiers.intersects(newline) => self.input.insert('\n'),
            KeyCode::Char('j') if ctrl => self.input.insert('\n'),
            KeyCode::Enter => return self.submit(),
            KeyCode::Esc => return self.cancel(),
            KeyCode::Char('c') if ctrl => {
                if self.input.text().is_empty() {
                    self.quit = true;
                } else {
                    self.input.take();
                }
            }
            KeyCode::Char('o') if ctrl => self.expand_tools = !self.expand_tools,
            KeyCode::Char(c) if !ctrl => self.input.insert(c),
            KeyCode::Backspace => self.input.backspace(),
            KeyCode::Delete => self.input.delete(),
            KeyCode::Left => self.input.left(),
            KeyCode::Right => self.input.right(),
            KeyCode::Home => self.input.home(),
            KeyCode::End => self.input.end(),
            KeyCode::Up => self.input.up(),
            KeyCode::Down => self.input.down(),
            KeyCode::PageUp => self.scroll += self.page.max(1),
            KeyCode::PageDown => self.scroll = self.scroll.saturating_sub(self.page.max(1)),
            _ => {}
        }
        None
    }

    /// Inserts pasted text at the cursor, normalising line endings and tabs
    /// and dropping other control characters.
    pub fn on_paste(&mut self, text: &str) {
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        for c in text.chars() {
            match c {
                '\t' => (0..4).for_each(|_| self.input.insert(' ')),
                '\n' => self.input.insert('\n'),
                c if c.is_control() => {}
                c => self.input.insert(c),
            }
        }
    }

    /// Handles a message from the server.
    pub fn on_message(&mut self, message: ServerMessage) {
        match message {
            ServerMessage::Response(response) => self.on_response(response),
            ServerMessage::Notification(notification) => self.on_event(&notification.event),
        }
    }

    /// Handles a fresh connection after the server went away, returning the
    /// request that resubscribes to the session (or opens it, if the first
    /// open was never answered). Requests sent on the old connection are
    /// forgotten, and a running turn is given up as lost.
    pub fn on_reconnected(&mut self) -> Call {
        self.pending.clear();
        if self.running {
            self.running = false;
            self.transcript
                .push_notice("reconnected to sadld; the running turn was lost");
        } else {
            self.transcript.push_notice("reconnected to sadld");
        }
        match &self.session {
            Some(session) => Call::SessionResume(SessionIdParams {
                id: session.id.clone(),
            }),
            None => self.open_call(),
        }
    }

    /// Notes a line from the server that could not be decoded.
    pub fn on_malformed(&mut self, detail: &str) {
        self.transcript
            .push_notice(&format!("unreadable message from sadld: {detail}"));
    }

    pub fn should_quit(&self) -> bool {
        self.quit
    }

    fn submit(&mut self) -> Option<Call> {
        let session = self.session.as_ref()?;
        if self.running || self.input.is_blank() {
            return None;
        }
        let id = session.id.clone();
        let text = self.input.take();
        self.transcript.push_user(&text);
        self.running = true;
        self.scroll = 0;
        Some(Call::SessionSend(SessionSendParams { id, text }))
    }

    fn cancel(&mut self) -> Option<Call> {
        match &self.session {
            Some(session) if self.running => Some(Call::SessionCancel(SessionIdParams {
                id: session.id.clone(),
            })),
            _ => None,
        }
    }

    fn on_response(&mut self, response: Response<Value>) {
        let Some(pending) = response.id.and_then(|id| self.pending.remove(&id)) else {
            return;
        };
        match (pending, response.outcome) {
            (Pending::Open | Pending::Resume, Outcome::Result(result)) => {
                match serde_json::from_value::<SessionInfo>(result) {
                    Ok(session) => self.session = Some(session),
                    Err(error) => self
                        .transcript
                        .push_notice(&format!("unreadable session from sadld: {error}")),
                }
            }
            (Pending::Open | Pending::Resume, Outcome::Error(error)) => {
                self.notice_error("cannot open the session", &error);
            }
            (Pending::Send, Outcome::Error(error)) => {
                self.running = false;
                self.notice_error("cannot send", &error);
            }
            (Pending::Cancel, Outcome::Error(error)) => {
                self.notice_error("cannot cancel", &error);
            }
            _ => {}
        }
    }

    fn on_event(&mut self, event: &Event) {
        let Some(session) = &self.session else {
            return;
        };
        if event_session(event) != session.id {
            return;
        }
        if let Event::TurnEnd(end) = event {
            self.running = false;
            self.usage.input_tokens += end.usage.input_tokens;
            self.usage.output_tokens += end.usage.output_tokens;
        }
        self.transcript.apply(event);
    }

    fn notice_error(&mut self, what: &str, error: &ErrorObject) {
        self.transcript
            .push_notice(&format!("{what} ({}): {}", error.code, error.message));
    }
}

fn event_session(event: &Event) -> &str {
    match event {
        Event::TurnDelta(e) => &e.session_id,
        Event::ToolCall(e) => &e.session_id,
        Event::PermissionRequest(e) => &e.session_id,
        Event::ToolResult(e) => &e.session_id,
        Event::TurnEnd(e) => &e.session_id,
        Event::Error(e) => &e.session_id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{JsonRpc, Notification, StopReason, TurnDelta, TurnEnd};
    use crate::tui::transcript::Block;
    use serde_json::json;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    fn type_text(app: &mut App, text: &str) {
        for c in text.chars() {
            assert_eq!(app.on_key(key(KeyCode::Char(c))), None);
        }
    }

    fn respond(app: &mut App, id: u64, result: Value) {
        app.on_message(ServerMessage::Response(Response {
            jsonrpc: JsonRpc::V2,
            id: Some(id),
            outcome: Outcome::Result(result),
        }));
    }

    fn respond_error(app: &mut App, id: u64, code: i64, message: &str) {
        app.on_message(ServerMessage::Response(Response {
            jsonrpc: JsonRpc::V2,
            id: Some(id),
            outcome: Outcome::Error(ErrorObject {
                code,
                message: message.into(),
                data: None,
            }),
        }));
    }

    fn notify(app: &mut App, event: Event) {
        app.on_message(ServerMessage::Notification(Notification {
            jsonrpc: JsonRpc::V2,
            event,
        }));
    }

    fn session_json(id: &str) -> Value {
        json!({"id": id, "cwd": "/p", "model": "m-1", "updated_at": "2026-01-01T00:00:00Z"})
    }

    /// An app whose session `s_1` is open, with the open sent as id 1.
    fn opened() -> App {
        let mut app = App::new("/p".into(), None);
        let open = app.open_call();
        app.sent(1, &open);
        respond(&mut app, 1, session_json("s_1"));
        app
    }

    fn delta(session_id: &str, text: &str) -> Event {
        Event::TurnDelta(TurnDelta {
            session_id: session_id.into(),
            turn_id: "t_1".into(),
            text: text.into(),
        })
    }

    fn end(stop_reason: StopReason, input_tokens: u64, output_tokens: u64) -> Event {
        Event::TurnEnd(TurnEnd {
            session_id: "s_1".into(),
            turn_id: "t_1".into(),
            stop_reason,
            usage: Usage {
                input_tokens,
                output_tokens,
            },
        })
    }

    fn blocks(app: &App) -> Vec<Block> {
        app.transcript.blocks().cloned().collect()
    }

    #[test]
    fn opens_a_session_in_the_cwd_with_the_chosen_model() {
        let app = App::new("/p".into(), Some("m-2".into()));

        assert_eq!(
            app.open_call(),
            Call::SessionOpen(SessionOpenParams {
                cwd: "/p".into(),
                model: Some("m-2".into()),
            })
        );
    }

    #[test]
    fn the_open_response_names_the_session() {
        let app = opened();

        assert_eq!(app.session.as_ref().map(|s| s.model.as_str()), Some("m-1"));
        assert_eq!(app.session.as_ref().map(|s| s.id.as_str()), Some("s_1"));
    }

    #[test]
    fn a_failed_open_is_shown() {
        let mut app = App::new("/p".into(), None);
        let open = app.open_call();
        app.sent(1, &open);
        respond_error(&mut app, 1, -32602, "cwd must be absolute");

        assert_eq!(app.session, None);
        assert_eq!(
            blocks(&app),
            [Block::Notice(
                "cannot open the session (-32602): cwd must be absolute".into()
            )]
        );
    }

    #[test]
    fn enter_sends_the_prompt_and_starts_a_turn() {
        let mut app = opened();
        type_text(&mut app, "hi");

        let call = app.on_key(key(KeyCode::Enter));

        assert_eq!(
            call,
            Some(Call::SessionSend(SessionSendParams {
                id: "s_1".into(),
                text: "hi".into(),
            }))
        );
        assert!(app.running);
        assert_eq!(app.input.text(), "");
        assert_eq!(blocks(&app), [Block::User("hi".into())]);
    }

    #[test]
    fn enter_does_nothing_before_the_session_is_open() {
        let mut app = App::new("/p".into(), None);
        type_text(&mut app, "hi");

        assert_eq!(app.on_key(key(KeyCode::Enter)), None);
        assert_eq!(app.input.text(), "hi");
    }

    #[test]
    fn enter_does_nothing_while_a_turn_runs_or_the_input_is_blank() {
        let mut app = opened();
        assert_eq!(app.on_key(key(KeyCode::Enter)), None);

        type_text(&mut app, "one");
        app.on_key(key(KeyCode::Enter));
        type_text(&mut app, "two");

        assert_eq!(app.on_key(key(KeyCode::Enter)), None);
        assert_eq!(app.input.text(), "two");
    }

    #[test]
    fn alt_enter_and_ctrl_j_insert_newlines() {
        let mut app = opened();
        type_text(&mut app, "a");
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::ALT));
        type_text(&mut app, "b");
        app.on_key(ctrl('j'));
        type_text(&mut app, "c");

        assert_eq!(app.input.text(), "a\nb\nc");
        assert!(!app.running);
    }

    #[test]
    fn a_rejected_send_ends_the_turn_with_a_notice() {
        let mut app = opened();
        type_text(&mut app, "hi");
        let call = app.on_key(key(KeyCode::Enter)).unwrap();
        app.sent(2, &call);
        respond_error(&mut app, 2, -32003, "session busy");

        assert!(!app.running);
        assert_eq!(
            blocks(&app).last(),
            Some(&Block::Notice("cannot send (-32003): session busy".into()))
        );
    }

    #[test]
    fn esc_cancels_a_running_turn() {
        let mut app = opened();
        assert_eq!(app.on_key(key(KeyCode::Esc)), None);

        type_text(&mut app, "hi");
        app.on_key(key(KeyCode::Enter));

        assert_eq!(
            app.on_key(key(KeyCode::Esc)),
            Some(Call::SessionCancel(SessionIdParams { id: "s_1".into() }))
        );
    }

    #[test]
    fn notifications_stream_into_the_transcript() {
        let mut app = opened();
        notify(&mut app, delta("s_1", "Hel"));
        notify(&mut app, delta("s_1", "lo"));

        assert_eq!(blocks(&app), [Block::Assistant("Hello".into())]);
    }

    #[test]
    fn notifications_for_other_sessions_are_ignored() {
        let mut app = opened();
        notify(&mut app, delta("s_2", "elsewhere"));

        assert_eq!(blocks(&app), []);
    }

    #[test]
    fn turn_end_stops_the_turn_and_adds_up_usage() {
        let mut app = opened();
        type_text(&mut app, "hi");
        app.on_key(key(KeyCode::Enter));
        notify(&mut app, end(StopReason::Completed, 10, 3));
        notify(&mut app, end(StopReason::Completed, 20, 4));

        assert!(!app.running);
        assert_eq!(
            app.usage,
            Usage {
                input_tokens: 30,
                output_tokens: 7,
            }
        );
    }

    #[test]
    fn ctrl_o_toggles_tool_blocks() {
        let mut app = opened();
        assert!(!app.expand_tools);

        app.on_key(ctrl('o'));
        assert!(app.expand_tools);

        app.on_key(ctrl('o'));
        assert!(!app.expand_tools);
    }

    #[test]
    fn page_keys_scroll_by_the_view_height() {
        let mut app = opened();
        app.page = 7;

        app.on_key(key(KeyCode::PageUp));
        app.on_key(key(KeyCode::PageUp));
        assert_eq!(app.scroll, 14);

        app.on_key(key(KeyCode::PageDown));
        app.on_key(key(KeyCode::PageDown));
        app.on_key(key(KeyCode::PageDown));
        assert_eq!(app.scroll, 0);
    }

    #[test]
    fn sending_scrolls_back_to_the_bottom() {
        let mut app = opened();
        app.scroll = 5;
        type_text(&mut app, "hi");
        app.on_key(key(KeyCode::Enter));

        assert_eq!(app.scroll, 0);
    }

    #[test]
    fn ctrl_c_clears_the_input_then_quits() {
        let mut app = opened();
        type_text(&mut app, "draft");

        app.on_key(ctrl('c'));
        assert_eq!(app.input.text(), "");
        assert!(!app.should_quit());

        app.on_key(ctrl('c'));
        assert!(app.should_quit());
    }

    #[test]
    fn paste_inserts_text_with_normalised_line_endings() {
        let mut app = opened();
        app.on_paste("a\r\nb\tc");

        assert_eq!(app.input.text(), "a\nb    c");
    }

    #[test]
    fn reconnecting_resumes_the_session_and_ends_a_lost_turn() {
        let mut app = opened();
        type_text(&mut app, "hi");
        app.on_key(key(KeyCode::Enter));

        let call = app.on_reconnected();

        assert_eq!(
            call,
            Call::SessionResume(SessionIdParams { id: "s_1".into() })
        );
        assert!(!app.running);
        assert_eq!(
            blocks(&app).last(),
            Some(&Block::Notice(
                "reconnected to sadld; the running turn was lost".into()
            ))
        );
    }

    #[test]
    fn reconnecting_before_the_open_was_answered_opens_again() {
        let mut app = App::new("/p".into(), None);
        let open = app.open_call();
        app.sent(1, &open);

        assert_eq!(app.on_reconnected(), open);
        respond(&mut app, 1, session_json("stale"));
        assert_eq!(app.session, None);
    }

    #[test]
    fn malformed_lines_are_noted() {
        let mut app = opened();
        app.on_malformed("expected value");

        assert_eq!(
            blocks(&app),
            [Block::Notice(
                "unreadable message from sadld: expected value".into()
            )]
        );
    }
}
