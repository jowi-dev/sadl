# sadl architecture (draft)

Status: **draft**. Settled decisions live in `docs/decisions/`.

## Goal

Run many concurrent agent sessions (driven by `tm` lanes) without each one
costing 400 MB–1 GB of RSS the way Claude Code and opencode do today. The
target is **~10–50 MB per session client**, with shared state and supervision
in one long-lived server.

## Shape

```
 tmux pane            tmux pane            tm (headless run)
 ┌──────────┐         ┌──────────┐         ┌──────────────┐
 │ sadl TUI │         │ sadl TUI │         │ sadl -p ...  │
 │ (Rust)   │         │ (Rust)   │         │ (Rust, no UI)│
 └────┬─────┘         └────┬─────┘         └──────┬───────┘
      │ UDS, JSON lines    │                      │
      └─────────┬──────────┴──────────────────────┘
                ▼
        ┌─────────────────────────────────────────────┐
        │ sadld (Elixir/OTP)                           │
        │  SessionSupervisor (DynamicSupervisor)       │
        │   └─ Session (GenServer, one per session)    │
        │       ├─ conversation state + turn loop      │
        │       ├─ ToolRunner (Task.Supervisor)        │
        │       └─ PubSub topic "session:<id>"         │
        │  Provider (behaviour; OpenAI-compat first)   │
        │  Store (SQLite)                              │
        └─────────────────────────────────────────────┘
```

### Client (`client/`, Rust)

- `ratatui` + `crossterm` + `tokio`. A **renderer and input device only**:
  no conversation state beyond what it is drawing, no LLM calls, no tool
  execution.
- On start: connect to the server's Unix socket, and spawn `sadld` if the
  socket is missing or refuses connections (auto-start daemon, like `tmux`
  itself). The client runs `$SADLD start` (`sadld` from `PATH` by default)
  detached in its own process group, then polls the socket until the server
  answers or a timeout passes. An exclusive lock on `sadld.lock` beside the
  socket lets only one of many clients starting at once launch a server.
- Modes, mirroring what `tm`'s `AgentRunner` needs:
  - interactive: `sadl [--model M] [--resume ID] [PROMPT]`
  - headless: `sadl -p PROMPT --output-format json` → prints a `RunOutcome`
    that `tm` parses
  - attach: `sadl attach ID` (read-only or take-over); falls out of PubSub
    for free

### Server (`server/`, Elixir)

- One `Session` GenServer per conversation, under a `DynamicSupervisor`.
  A crashed session restarts from its persisted transcript; the other
  sessions are unaffected.
- **Tools run on the server**, in the session's `cwd` (sent by the client on
  `session.open`). The server and client are on the same machine, so this is
  safe and keeps the client thin. Shell execution uses `erlexec`
  rather than raw `Port`s (process-group kill, no orphaned
  children on timeout; see ADR-0002).
- Provider behaviour with streaming (Req/Finch + SSE). Start with an
  OpenAI-compatible adapter pointed at Venice.ai; it also covers
  OpenRouter/Ollama. Anthropic's Messages API is a later adapter.
- Every turn is persisted before it is acknowledged, so a server restart
  loses at most the in-flight request.
- Sessions and their messages, tool calls and results included, live in
  SQLite at `$XDG_DATA_HOME/sadl/sadl.db` (`exqlite`, no Ecto).

### Protocol

- Transport: Unix domain socket (`$XDG_RUNTIME_DIR/sadl/sadld.sock`).
  `:gen_tcp` supports `{:local, path}` natively; no Phoenix needed.
- Framing: newline-delimited JSON, JSON-RPC 2.0 shaped (requests with ids,
  server-pushed notifications for stream deltas and tool events).
- The schema lives in `docs/protocol.md` and is the contract between the two
  halves. It gets **golden-file fixtures** checked into the repo and tested
  from both sides so the Rust and Elixir types cannot drift.

## MVP scope (pi.dev-shaped, not Claude Code-shaped)

- Four tools: `read`, `write`, `edit`, `bash`. No permission prompts (YOLO,
  like pi); permissions come later.
- One provider: Venice.ai through an OpenAI-compatible adapter (default
  model GLM 5.3 Flash, `z-ai-glm-5-3-flash`, configurable). The API key
  comes from `VENICE_API_KEY` or `$XDG_CONFIG_HOME/sadl/api_key`, never
  from committed config. The provider is a behaviour so Anthropic and
  others can be added later.
- SQLite-backed sessions with resume.
- Driven by hand first. `tm` integration comes after the tool proves itself.

## Integration with tm (later)

`sadl` becomes a third `AgentKind` in tskmstr (after `Claude` and
`Opencode`), so it has to supply what `AgentRunner` asks for:
`build_invocation`, `parse_outcome`, `resume_command`,
`interactive_shell_command`, `session_env_vars`, `price_for_model`, and
optionally telemetry. Telemetry should be **a server subscription, not hook
scripts**: `tm` can read run events from the server directly instead of
deploying bash hooks into every worktree.

## Open questions

1. **Server lifecycle:** auto-started by the client, a systemd user unit, or
   both. MVP default: client auto-start (zero config).
2. **Compaction strategy** once conversations outgrow the model's context.
3. **Server naming:** `sadld` for now; `stable` is on the table.
