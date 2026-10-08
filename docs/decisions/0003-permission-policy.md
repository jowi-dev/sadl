# ADR-0003: Per-session permission policy with prompts over the protocol

**Status:** Accepted
**Date:** 2026-10-07

## Problem

ADR-0001 shipped the MVP without permission prompts: every tool call the
model makes runs. That is fine for trusted, hand-driven sessions but not for
a model given `bash` in a repository that matters. Tools run on the server,
while the person who can approve a call sits at whichever client is
attached, possibly several or none.

## Decision

1. **A policy decides each tool call: `allow`, `ask` or `deny`.** It is a
   default action plus an ordered list of rules; the first rule that
   matches the call's tool (and, for `bash`, a `*`-glob over the whole
   command) decides. `Sadld.Permissions` documents the format.
2. **The policy lives on the server**, in
   `$XDG_CONFIG_HOME/sadl/permissions.json`. Each session reads it once when
   it starts or resumes and keeps it for its lifetime, so editing the file
   affects only sessions started afterwards. Without a file every call is
   allowed, which keeps the MVP's behaviour. A file that is not a valid
   policy makes session start fail rather than fall back to allowing
   everything.
3. **`ask` is carried over the protocol.** The session broadcasts
   `permission.request` for the call to every attached client and the turn
   waits. Any client answers with the `session.permit` request; the first
   answer wins and later ones get `-32004`. A denied call, by policy or by
   a client, becomes an error `tool.result` the model reads, and the turn
   carries on.
4. **No timeout.** A request with no client to answer it waits until one
   does or the turn is cancelled.

## Consequences

- The client stays a renderer: it shows the prompt and sends the answer,
  and never evaluates the policy.
- A client that attaches while a call is waiting is not told about it
  (protocol v0 has no replay), so the turn can only be cancelled from
  there. Replaying pending requests on `session.resume` is follow-up work.
- Per-session policies chosen by the client (for example a `session.open`
  parameter) and "always allow" answers that amend the policy are left for
  later; both fit the rule format without changing it.
