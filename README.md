# sadl

A lightweight agentic coding tool split into a thin Rust TUI client
(`client/`) and a long-lived Elixir server (`server/`), so many concurrent
sessions share one supervised backend instead of each paying for its own
runtime. Built to run as an agent runner for [tskmstr](../tskmstr) (`tm`).

See [`docs/architecture.md`](docs/architecture.md) for the design draft.

## Setup

```
direnv allow      # or: nix develop
```

Provides `cargo`/`rustc`/`clippy`/`rustfmt` and `elixir`/`erlang`/`mix`.

## Usage

With `sadld` running:

| Command                                   | What it does                                            |
|-------------------------------------------|---------------------------------------------------------|
| `sadl [--model M] [PROMPT]`               | Chat in a new session in the current directory, sending `PROMPT` first if given |
| `sadl --resume ID`                        | Chat in an existing session                             |
| `sadl -p PROMPT [--output-format json]`   | Run one turn with no TUI and print the result           |
| `sadl ls`                                 | List sessions, most recently updated first              |
| `sadl attach ID`                          | Watch a session's turns as they run, read-only          |

`-p` also takes `--model` or `--resume`. It prints the turn's text, or with
`--output-format json` one line like:

```json
{"session_id":"s_1","result":"Done.","success":true,"stop_reason":"completed","usage":{"input_tokens":120,"output_tokens":8}}
```

`error` is added when the run failed. It exits non-zero unless the turn
completed. A resumed or attached session starts with an empty transcript:
the server does not replay history yet.

## Chat

| Key                              | Action                                  |
|----------------------------------|-----------------------------------------|
| Enter                            | Send the prompt                         |
| Alt+Enter, Shift+Enter, Ctrl+J   | Insert a newline                        |
| Esc                              | Cancel the running turn                 |
| Ctrl+O                           | Expand or collapse tool calls           |
| PageUp, PageDown                 | Scroll the transcript                   |
| Ctrl+C                           | Clear the prompt, or quit when empty    |
| y, n                             | Allow or deny a tool call that asks     |

The status line shows the model, the session id, token totals for the turns
this window has seen, and whether a turn is running. The client keeps about
8 MB of transcript text and drops the oldest blocks beyond that; the full
history stays on the server. An attached window takes only Ctrl+O, PageUp,
PageDown and Ctrl+C.

## Permissions

Every tool call runs unless `$XDG_CONFIG_HOME/sadl/permissions.json`
(`~/.config/sadl/permissions.json`) says otherwise. Each session reads the
file when it opens:

```json
{
  "default": "ask",
  "rules": [
    {"tool": "read", "action": "allow"},
    {"tool": "bash", "command": "git status*", "action": "allow"},
    {"tool": "bash", "command": "rm *", "action": "deny"}
  ]
}
```

The first rule matching a call's tool (and, for `bash`, its whole command,
where `*` matches anything) decides; `default` covers the rest. A denied call
fails and the model is told why. A call that asks replaces the prompt with
`? allow <tool> <args>  y / n` until a client attached to the session answers.
See [ADR-0003](docs/decisions/0003-permission-policy.md).
