# ADR-0003: Context compaction by summary

**Status:** Accepted
**Date:** 2026-10-07

## Problem

A long session eventually outgrows the model's context window, and the
provider rejects the request. The architecture draft left the compaction
strategy open.

## Decision

Compact pi-style: when the context nears the window, summarize the older
messages with the session's own model and send the summary in their
place, keeping the newest messages verbatim.

- **When:** before every provider request in a turn, so a long run of tool
  calls is covered too, not just the start of a turn. Compaction is needed
  once the context leaves less than `reserve_tokens` of the window free.
  The context's size is the provider's reported usage for the previous
  request plus a four-characters-per-token estimate of the messages since;
  with no report yet (a fresh or resumed session), the whole context is
  estimated.
- **What is kept:** at least `keep_recent_tokens` of the newest messages.
  The cut never falls between an assistant message and its tool results,
  which providers reject.
- **How:** the messages to summarize are sent as text in one user message,
  with a summarization system prompt and no tools, so the model writes a
  summary rather than carrying on. Long tool output is truncated in that
  request. A later compaction summarizes only the messages since the last
  one and folds in the previous summary.
- **Storage:** the stored messages never change. Each compaction is a row
  of its own (summary, first message kept), and only the latest is used.
  Only what is sent to the provider changes, so the full transcript stays
  available for replay and export.
- **Manual:** `session.compact` (the TUI's `/compact`) runs a compaction as
  a turn of its own. When the recent tail is the whole conversation, it
  summarizes everything.
- **Visibility:** each compaction sends a `turn.compacted` notification with
  the summary; the summary request's usage counts toward the turn's.

Defaults: `context_window` 128 000, `reserve_tokens` 16 384,
`keep_recent_tokens` 20 000, set under `config :sadld, Sadld.Compaction`.

## Consequences

- The context window is one configured number, not per model. A session on
  a model with a smaller window must have it configured.
- A failed summary request fails the turn, like any provider error; the
  session is left uncompacted and the next turn tries again.
- The estimate ignores the tool definitions sent with each request, which
  `reserve_tokens` has to absorb until the provider has reported usage.
