//! The interactive chat TUI: a renderer and input device for one session.
//! It holds nothing beyond what it draws; the conversation lives in `sadld`.

pub mod app;
pub mod input;
pub mod transcript;
pub mod view;
pub mod wrap;

use std::error::Error;

use crossterm::event::Event;
use ratatui::Terminal;
use ratatui::backend::Backend;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::link::{Incoming, Link};
use crate::protocol::Call;
use app::App;

/// Why [`run`] stopped early.
pub type RunError = Box<dyn Error + Send + Sync>;

/// Runs the chat on `terminal` until the user quits or `events` closes.
///
/// Opens the app's session on `link`, then redraws after every terminal
/// event from `events` and every message from the server. Messages already
/// waiting on the socket are handled before the next key, so a key always
/// acts on what the server has said so far. Fails if drawing fails or the
/// server rejects the handshake on a reconnect.
pub async fn run<B>(
    terminal: &mut Terminal<B>,
    link: &mut Link,
    app: &mut App,
    events: &mut UnboundedReceiver<Event>,
) -> Result<(), RunError>
where
    B: Backend,
    B::Error: Send + Sync + 'static,
{
    let open = app.open_call();
    send(link, app, open).await;
    while !app.should_quit() {
        terminal.draw(|frame| view::draw(frame, app))?;
        tokio::select! {
            biased;
            incoming = link.recv() => match incoming? {
                Incoming::Message(message) => {
                    if let Some(call) = app.on_message(message) {
                        send(link, app, call).await;
                    }
                }
                Incoming::Reconnected => {
                    let call = app.on_reconnected();
                    send(link, app, call).await;
                }
                Incoming::Malformed(detail) => app.on_malformed(&detail),
            },
            event = events.recv() => match event {
                Some(Event::Key(key)) => {
                    if let Some(call) = app.on_key(key) {
                        send(link, app, call).await;
                    }
                }
                Some(Event::Paste(text)) => app.on_paste(&text),
                Some(_) => {}
                None => break,
            },
        }
    }
    Ok(())
}

/// Sends `call` and tells `app` its id. A failed write is shown; the next
/// read notices the dead connection and reconnects.
async fn send(link: &mut Link, app: &mut App, call: Call) {
    match link.send(call.clone()).await {
        Ok(id) => app.sent(id, &call),
        Err(error) => app
            .transcript
            .push_notice(&format!("cannot reach sadld: {error}")),
    }
}
