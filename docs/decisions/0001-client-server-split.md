# ADR-0001: Thin Rust client, Elixir session server

**Status:** Accepted
**Date:** 2026-10-01

## Problem

Claude Code and opencode each cost 400 MB–1 GB of RSS per session, which caps
how many parallel agent sessions one machine can run.

## Decision

1. **Split into a Rust TUI client (`client/`) and one Elixir server
   (`server/`) in one repo.** The client renders and takes input; it holds no
   conversation state, makes no LLM calls and runs no tools.
2. **One BEAM process per session** under a `DynamicSupervisor`. A session
   crash is isolated to that session; SQLite persistence covers a full VM
   restart.
3. **Tools execute on the server** in the session's `cwd`, which the client
   supplies when it opens the session. Client and server always share a
   machine.
4. **Protocol: JSON-RPC 2.0-shaped, newline-delimited JSON over a Unix
   domain socket.** Encoding cost is negligible; drift between the Rust and
   Elixir types is prevented by golden fixtures in `protocol/fixtures/`
   that both test suites decode and re-encode.
5. **MVP is pi.dev-shaped:** `read`/`write`/`edit`/`bash`, no permission
   prompts, one OpenAI-compatible provider (Venice.ai).

## Consequences

- Per-session client memory budget: **≤ 50 MB RSS**.
- Multiple clients can attach to one session (PubSub), which later gives
  `tm` live telemetry without hook scripts.
- Two toolchains, both provided by `flake.nix`.
