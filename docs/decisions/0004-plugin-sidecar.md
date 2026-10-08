# ADR-0004: Host opencode plugins in a supervised Bun sidecar

**Status:** Accepted
**Date:** 2026-10-08

## Problem

[thatch](https://github.com/jowi-dev/thatch) gives an agent memory,
prediction and behavior engines, fact extraction and review skills. It
ships three integration tiers: an opencode plugin, and an MCP server plus
shell hooks for Claude Code and Cursor. Only the plugin gets direct
extraction in a child session, compaction context, session search, chat and
watcher wake-ups and toasts. sadld is neither host, and porting the
plugin's ~1300 lines of hook logic to Elixir would fork it.

## Decision

1. **sadld runs opencode plugins unmodified in a Bun sidecar.** A plugin's
   whole surface is `server({ client, worktree }) => hooks`.
   `server/priv/sidecar/plugin_host.ts` imports the plugin, calls `server`
   once per worktree with an emulated `client`, and speaks
   `docs/sidecar.md` over its stdin and stdout: sadld sends hooks, events
   and tool calls in; the plugin's `client` calls come out as requests
   sadld answers in opencode's response shapes.
2. **One sidecar per plugin and worktree, started lazily.** The first
   session in a worktree starts it under `Sadld.PluginSupervisor`, through
   erlexec like the `bash` tool (ADR-0002). Sessions in one repository share
   its warm embedding model. OTP restarts it if it crashes, and it stops
   with sadld. There is no separate service unit.
3. **The extension points in `Sadld.Session` are generic.** A session
   holds a list of `Sadld.Plugin` implementations. It merges their tools
   into what the model is offered and dispatches calls to them, passes the
   system prompt and each user message through their hooks, reports tool
   results to them, and sends them lifecycle events. thatch is the first
   consumer, not a special case.
4. **Hooks that can change a turn are synchronous and run in the turn
   task**, never in the session's `handle_call`. A plugin may call back into
   the session (`session.messages`, `session.prompt`) while its hook runs;
   from the turn task that is safe, from the session process it would
   deadlock. Lifecycle events are fire-and-forget.
5. **Plugin-injected text is a user message marked `synthetic`.** It is
   persisted like any other message, so a resumed session replays it, and
   the mark lets a client render it apart from what the user typed.
6. **thatch is a pinned flake input.** Its Nix package carries its
   dependencies with the native ONNX runtime patched for NixOS; the dev
   shell exports the plugin's entry point as `SADL_THATCH_PLUGIN`.

## Consequences

- Plugin hooks with no sadld equivalent yet are not called: compaction
  (#16), slash commands and `command.execute.before`. `client` calls sadld
  cannot honour, such as creating child sessions, fail with method not
  found; thatch falls back to its nudge path for extraction.
- A `client.session.prompt` returns once the message is recorded and its
  turn started, without waiting for the reply as opencode's does.
- Several hooks are `experimental.*` in opencode. Pinning thatch and a
  contract test against the pinned plugin guard against drift.
- Each model step pays a round trip to every plugin for the system prompt,
  and thatch's instructions add input tokens to every request.
