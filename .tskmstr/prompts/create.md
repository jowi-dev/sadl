# Create a ticket

Draft a new ticket for this repository. Keep the ticket body human-readable;
put the detailed plan in thatch memory, not the ticket.

## Recall thatch memory first

Before drafting, search thatch memory for context relevant to this repo and the
work you are about to describe — prior plans, conventions, and decisions — so
the ticket agrees with what the project already knows.

## Draft with the thatch skill

Use the `thatch-ticket-description` skill to draft the ticket: clear sections,
bold/italic emphasis for scanning, and no invented requirements.

## Write the plan back to thatch memory

Record the detailed plan and background you gathered in thatch memory so a later
session can recall it. Keep the ticket body itself concise and readable.

## Repo-specific context

Tickets are GitHub issues on `jowi-dev/sadl` (`tm ticket create` files
them there). `tm` refers to an issue as `SADL-<number>`. Issue bodies
refer to each other as `#N`.

**Before drafting, read** `docs/architecture.md` and every ADR in
`docs/decisions/`. A ticket must agree with them. If the work changes a
settled decision, the ticket says to add a new ADR; it never edits an
accepted one. Check `gh issue list --state all` for an existing ticket
that already covers the work.

**Title:** an area prefix plus a short noun phrase, matching the existing
issues:

- `Client: socket connection and typed protocol messages`
- `Server: bash tool with timeouts and process-group kill`
- `CI: run client and server checks through the Nix dev shell`
- Cross-cutting or protocol work may go unprefixed, e.g.
  `Define protocol v0 and golden fixtures`.

**Labels:** one area label: `area:client`, `area:server`,
`area:protocol`, or `area:infra`. Add a second area label only when the
work truly spans both halves. Add `later` for anything outside the MVP
scope in `docs/architecture.md`. Do not set `tm:status/*` labels by hand;
`tm` manages them.

**Body:** short and concrete, in the style of the existing issues:

- One or two paragraphs naming the module, message, or command to build,
  with code identifiers in backticks.
- The test that proves it, when it is not obvious (e.g. "Test that a
  `sleep 100 &` child is reaped on cancel").
- An optional `**Done when:**` line naming the passing checks.
- A final `Depends on #N, #M.` line for prerequisites. `tm ready` does not
  enforce these prose dependencies, so keep them accurate; lanes check
  them by hand.

**Project constraints a ticket must respect:**

- The Rust client is a renderer and input device only: no conversation
  state, no LLM calls, no tool execution. Tools run on the Elixir server.
- Protocol changes touch `docs/protocol.md`, the golden fixtures in
  `protocol/fixtures/`, and both sides' types in the same ticket.
- All toolchains and dependencies come from `flake.nix`; nothing is
  installed outside the dev shell.
- The gates a lane must leave green are, for the client, `cargo fmt
  --check`, `cargo clippy -- -D warnings`, and `cargo test`; for the
  server, `mix format --check-formatted`, `mix compile
  --warnings-as-errors`, `mix credo`, and `mix test`. Scope tickets so one
  lane can land them with those gates green.
- Keep a ticket to one lane's worth of work. Split anything larger into
  several tickets linked with `Depends on`.
