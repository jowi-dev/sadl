# ADR-0005: Run slash commands on the server, in opencode's format

**Status:** Accepted
**Date:** 2026-10-12

## Problem

thatch installs its `/thatch/*` commands as opencode command files under
`$XDG_CONFIG_HOME/opencode/command/thatch/`. Its wrap-ups, `/thatch/compact`
and `/thatch/exit`, also depend on two plugin features. The plugin marks the
session in its `command.execute.before` hook. On the session's next idle,
once the reply ends with its greenlight token, it calls
`client.tui.executeCommand` with `session_compact` or `client.tui.publish`
with `app.exit`. ADR-0004 left all of this out. The TUI calls also name no
session, because in opencode they act on whatever the TUI shows, and a sadld
sidecar serves every session in its worktree.

## Decision

1. **Commands are opencode's markdown files, read from opencode's config
   directory and then sadl's.** `<name>.md` under `command/` or `commands/`
   names command `name`, subdirectories included. Front matter is ignored.
   The body is a template with `$ARGUMENTS` and `$1`, `$2`, ... A command
   in sadl's directory replaces an opencode one with the same name. Files
   are read on each use, so edits take effect without a restart.
2. **The server expands commands, through a new `session.command`
   request**, rather than the client sending expanded text with
   `session.send`. The hook needs to know a command ran, and the client
   holds no config (ADR-0001). The TUI sends any `/name args` other than
   `/compact` as `session.command`. An unknown name fails with `-32005`.
3. **`command.execute.before` runs in the turn task, before the prompt is
   recorded** (ADR-0004 §4). The text it leaves becomes the user message.
4. **A plugin's TUI calls act on the session the sidecar last told the
   plugin about**: the latest named by an event, a hook or a tool call.
   thatch makes these calls while handling that session's `session.idle`,
   so it is the right one. `session_compact` compacts the session.
5. **`app.exit` becomes an `app.exit` notification to the session's
   clients.** The TUI quits on it. The session keeps running on the server,
   as it does whenever a client detaches, and can be resumed.

## Consequences

- Two sessions in one worktree that go idle at the same moment could
  receive each other's TUI call. A plugin that needs certainty has to wait
  for opencode's TUI calls to name a session.
- Typed text that starts with `/`, such as a path, runs as a command, and
  an unknown one fails without starting a turn. Starting the message with a
  space does not help, because the TUI trims it. The client cannot list
  commands yet, so there is no completion.
- Only `session_compact` and `app_exit` are supported. Other TUI commands
  fail with invalid params.
- The headless `-p` prompt is still sent as plain text.
