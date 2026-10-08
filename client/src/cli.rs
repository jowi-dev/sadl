//! The `sadl` command line.

use clap::{Parser, Subcommand, ValueEnum};

use crate::start::Start;

/// A thin client for the sadld coding agent.
#[derive(Debug, Parser)]
#[command(name = "sadl", version, args_conflicts_with_subcommands = true)]
pub struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Model for a new session (the server's default when omitted).
    #[arg(long, value_name = "MODEL", conflicts_with = "resume")]
    model: Option<String>,

    /// Resume the session with this id instead of opening a new one.
    #[arg(long, value_name = "ID")]
    resume: Option<String>,

    /// Run PROMPT without the TUI, print the result and exit.
    #[arg(short = 'p', long = "print", value_name = "PROMPT")]
    print: Option<String>,

    /// How a headless run (`-p`) reports its result.
    #[arg(long, value_enum, value_name = "FORMAT", requires = "print")]
    output_format: Option<OutputFormat>,

    /// Prompt to send as soon as the interactive session is open.
    #[arg(value_name = "PROMPT", conflicts_with = "print")]
    prompt: Option<String>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// List persisted sessions, most recently updated first.
    Ls,
    /// Watch a session's turns as they run, read-only.
    Attach {
        /// The session to watch.
        id: String,
    },
}

/// How a headless run reports its result on stdout.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, ValueEnum)]
pub enum OutputFormat {
    /// The final assistant text.
    #[default]
    Text,
    /// One JSON object: the result, session id, usage and success.
    Json,
}

/// What a `sadl` invocation does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    /// The chat TUI on `start`'s session, sending `prompt` once it opens.
    Interactive {
        start: Start,
        prompt: Option<String>,
    },
    /// One turn of `prompt` on `start`'s session, with no TUI.
    Headless {
        start: Start,
        prompt: String,
        format: OutputFormat,
    },
    /// Print the persisted sessions.
    List,
    /// The chat TUI on session `id`, read-only.
    Attach { id: String },
}

impl Cli {
    /// What this invocation does. A new session's tools run in `cwd`.
    pub fn mode(self, cwd: String) -> Mode {
        match self.command {
            Some(Command::Ls) => return Mode::List,
            Some(Command::Attach { id }) => return Mode::Attach { id },
            None => {}
        }
        let start = match self.resume {
            Some(id) => Start::Resume { id },
            None => Start::Open {
                cwd,
                model: self.model,
            },
        };
        match self.print {
            Some(prompt) => Mode::Headless {
                start,
                prompt,
                format: self.output_format.unwrap_or_default(),
            },
            None => Mode::Interactive {
                start,
                prompt: self.prompt,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mode(args: &[&str]) -> Mode {
        let argv = std::iter::once("sadl").chain(args.iter().copied());
        Cli::try_parse_from(argv)
            .expect("valid arguments")
            .mode("/p".into())
    }

    fn rejects(args: &[&str]) -> bool {
        let argv = std::iter::once("sadl").chain(args.iter().copied());
        Cli::try_parse_from(argv).is_err()
    }

    fn open(model: Option<&str>) -> Start {
        Start::Open {
            cwd: "/p".into(),
            model: model.map(Into::into),
        }
    }

    #[test]
    fn no_arguments_opens_a_new_interactive_session() {
        assert_eq!(
            mode(&[]),
            Mode::Interactive {
                start: open(None),
                prompt: None,
            }
        );
    }

    #[test]
    fn model_and_prompt_open_a_session_and_send_the_prompt() {
        assert_eq!(
            mode(&["--model", "m-2", "fix the build"]),
            Mode::Interactive {
                start: open(Some("m-2")),
                prompt: Some("fix the build".into()),
            }
        );
    }

    #[test]
    fn resume_resumes_the_session() {
        assert_eq!(
            mode(&["--resume", "s_1"]),
            Mode::Interactive {
                start: Start::Resume { id: "s_1".into() },
                prompt: None,
            }
        );
    }

    #[test]
    fn print_runs_headless_as_text_by_default() {
        assert_eq!(
            mode(&["-p", "hi"]),
            Mode::Headless {
                start: open(None),
                prompt: "hi".into(),
                format: OutputFormat::Text,
            }
        );
    }

    #[test]
    fn print_takes_an_output_format_model_and_resume() {
        assert_eq!(
            mode(&["-p", "hi", "--output-format", "json", "--model", "m"]),
            Mode::Headless {
                start: open(Some("m")),
                prompt: "hi".into(),
                format: OutputFormat::Json,
            }
        );
        assert_eq!(
            mode(&["--resume", "s_1", "--print", "again"]),
            Mode::Headless {
                start: Start::Resume { id: "s_1".into() },
                prompt: "again".into(),
                format: OutputFormat::Text,
            }
        );
    }

    #[test]
    fn ls_lists_sessions() {
        assert_eq!(mode(&["ls"]), Mode::List);
    }

    #[test]
    fn attach_names_the_session() {
        assert_eq!(mode(&["attach", "s_1"]), Mode::Attach { id: "s_1".into() });
    }

    #[test]
    fn contradictory_arguments_are_rejected() {
        assert!(rejects(&["--model", "m", "--resume", "s_1"]));
        assert!(rejects(&["-p", "hi", "also a prompt"]));
        assert!(rejects(&["--output-format", "json"]));
        assert!(rejects(&["--output-format", "yaml", "-p", "hi"]));
        assert!(rejects(&["attach"]));
    }
}
