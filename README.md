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

The status line shows the model, the session id, the session's token totals
and whether a turn is running. The client keeps about 8 MB of transcript text
and drops the oldest blocks beyond that; the full history stays on the server.
