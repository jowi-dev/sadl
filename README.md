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

## Chat

With `sadld` running, `sadl` opens a new session in the current directory.

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
history stays on the server.

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
