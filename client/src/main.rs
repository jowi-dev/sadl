//! `sadl`: opens a chat session in the current directory on the running
//! `sadld`.

use std::env;
use std::io::stdout;
use std::process::ExitCode;
use std::time::Duration;

use crossterm::event::{self, DisableBracketedPaste, EnableBracketedPaste};
use crossterm::execute;
use sadl::connection::default_socket_path;
use sadl::link::{Backoff, Link};
use sadl::tui::{self, app::App};
use tokio::sync::mpsc;
use tokio::time::timeout;

/// How long to wait for the server before giving up at startup.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match chat().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("sadl: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn chat() -> Result<(), tui::RunError> {
    let path = default_socket_path().ok_or("XDG_RUNTIME_DIR is not set")?;
    let cwd = env::current_dir()?.to_string_lossy().into_owned();
    let mut link = timeout(
        CONNECT_TIMEOUT,
        Link::connect(path.clone(), Backoff::default()),
    )
    .await
    .map_err(|_| format!("sadld is not running at {}", path.display()))??;
    let mut app = App::new(cwd, None);

    let (keys, mut events) = mpsc::unbounded_channel();
    std::thread::spawn(move || {
        while let Ok(event) = event::read() {
            if keys.send(event).is_err() {
                break;
            }
        }
    });

    let mut terminal = ratatui::try_init()?;
    let _ = execute!(stdout(), EnableBracketedPaste);
    let result = tui::run(&mut terminal, &mut link, &mut app, &mut events).await;
    let _ = execute!(stdout(), DisableBracketedPaste);
    ratatui::restore();
    result
}
