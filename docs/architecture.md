# sadl architecture (draft)

Status: **draft for discussion**. Nothing here is decided until it moves into
an ADR under `docs/decisions/`.

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
        │  Provider (behaviour: Anthropic, OpenAI-compat)│
        │  Store (SQLite / JSONL transcripts)          │
        └─────────────────────────────────────────────┘
```

### Client (`client/`, Rust)

- `ratatui` + `crossterm` + `tokio`. A **renderer and input device only**:
  no conversation state beyond what it is drawing, no LLM calls, no tool
  execution.
- On start: connect to the server's Unix socket, and spawn `sadld` if the
  socket is missing (auto-start daemon, like `tmux` itself).
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
  safe and keeps the client thin. Shell execution uses `erlexec` or
  `MuonTrap` rather than raw `Port`s (process-group kill, no orphaned
  children on timeout).
- Provider behaviour with streaming (Req/Finch + SSE). Start with Anthropic
  Messages API; an OpenAI-compatible adapter covers OpenRouter/Venice/Ollama.
- Every turn is persisted before it is acknowledged, so a server restart
  loses at most the in-flight request.

### Protocol

- Transport: Unix domain socket (`$XDG_RUNTIME_DIR/sadl/sadld.sock`).
  `:gen_tcp` supports `{:local, path}` natively; no Phoenix needed.
- Framing: newline-delimited JSON, JSON-RPC 2.0 shaped (requests with ids,
  server-pushed notifications for stream deltas and tool events).
- The schema lives in `docs/protocol.md` and is the contract between the two
  halves. It gets **golden-file fixtures** checked into the repo and tested
  from both sides so the Rust and Elixir types cannot drift.

## Integration with tm

`sadl` becomes a third `AgentKind` in tskmstr (after `Claude` and
`Opencode`), so it has to supply what `AgentRunner` asks for:
`build_invocation`, `parse_outcome`, `resume_command`,
`interactive_shell_command`, `session_env_vars`, `price_for_model`, and
optionally telemetry. Telemetry should be **a server subscription, not hook
scripts**: `tm` can read run events from the server directly instead of
deploying bash hooks into every worktree.

## Risks / open questions

1. **Single point of failure.** One server going down takes every session
   with it. Mitigations: persistence per turn, client reconnect with
   backoff, server run under systemd user unit or auto-started by the client.
2. **Auth and billing.** Claude subscription OAuth in a third-party client
   is not a supported path; sadl should assume API-key billing. At "many
   sessions in parallel", that cost has to be compared against what
   subscription-backed Claude Code costs today.
3. **Parity scope.** Claude Code's value is mostly its tool set, prompts,
   permissions, compaction, skills and subagents, not its UI. An MVP needs
   at least: read/write/edit/glob/grep/bash tools, permission prompts,
   context compaction, resume.
4. **Two languages, one protocol.** Real overhead vs an all-Rust server.
   The case for Elixir is supervision, per-session processes, PubSub
   (attach and observe sessions), and hot upgrades without killing sessions.
5. **Where memory actually goes.** Need a baseline measurement (RSS of an
   idle and a busy Claude Code session) and a budget per sadl client so the
   project can tell whether it is hitting its goal.
