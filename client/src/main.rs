//! `sadl`: a chat session, a headless run or a session listing on the
//! running `sadld`. See [`sadl::cli`] for the command line.

use std::env;
use std::io::stdout;
use std::process::ExitCode;
use std::time::Duration;

use clap::Parser;
use crossterm::event::{self, DisableBracketedPaste, EnableBracketedPaste};
use crossterm::execute;
use sadl::cli::{Cli, Mode, OutputFormat};
use sadl::connection::default_socket_path;
use sadl::headless::{self, Run, RunOutcome};
use sadl::link::{Backoff, Link};
use sadl::list;
use sadl::start::Start;
use sadl::tui::{self, RunError, app::App};
use tokio::sync::mpsc;
use tokio::time::timeout;

/// How long to wait for the server before giving up at startup.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli).await {
        Ok(code) => code,
        Err(error) => {
            eprintln!("sadl: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn run(cli: Cli) -> Result<ExitCode, RunError> {
    let cwd = env::current_dir()?.to_string_lossy().into_owned();
    let mode = cli.mode(cwd);
    let mut link = connect().await?;
    match mode {
        Mode::Interactive { start, prompt } => {
            let app = App::new(start);
            let app = match prompt {
                Some(prompt) => app.with_prompt(prompt),
                None => app,
            };
            chat(link, app).await?;
        }
        Mode::Attach { id } => chat(link, App::new(Start::Resume { id }).read_only()).await?,
        Mode::List => print!("{}", list::format(&list::fetch(&mut link).await?)),
        Mode::Headless {
            start,
            prompt,
            format,
        } => {
            let outcome = headless::run(&mut link, Run::new(start, prompt)).await?;
            report(&outcome, format)?;
            if !outcome.success {
                return Ok(ExitCode::FAILURE);
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

async fn connect() -> Result<Link, RunError> {
    let path = default_socket_path().ok_or("XDG_RUNTIME_DIR is not set")?;
    let link = timeout(
        CONNECT_TIMEOUT,
        Link::connect(path.clone(), Backoff::default()),
    )
    .await
    .map_err(|_| format!("sadld is not running at {}", path.display()))??;
    Ok(link)
}

/// Prints a headless run's result on stdout: its text, or the whole
/// outcome as one JSON line. In text form a failure goes to stderr.
fn report(outcome: &RunOutcome, format: OutputFormat) -> Result<(), RunError> {
    match format {
        OutputFormat::Text => {
            if !outcome.result.is_empty() {
                println!("{}", outcome.result.trim_end_matches('\n'));
            }
            if let Some(error) = &outcome.error {
                eprintln!("sadl: {error}");
            }
        }
        OutputFormat::Json => println!("{}", serde_json::to_string(outcome)?),
    }
    Ok(())
}

async fn chat(mut link: Link, mut app: App) -> Result<(), RunError> {
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
