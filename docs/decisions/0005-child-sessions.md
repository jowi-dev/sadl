# ADR-0005: Child sessions for plugins and subagents

**Status:** Accepted
**Date:** 2026-10-12

## Problem

ADR-0004 left two gaps in the plugin `client`. `session.create` answered
method not found, and `session.prompt` returned as soon as its turn
started. thatch needs both. It extracts facts in a child session when its
parent goes idle, and its code-review coordinator dispatches subagents and
reads their replies. Without them thatch falls back to nudging the model in
the parent conversation. opencode also gives the model a `task` tool that
runs a prompt in a child session, and sadl had no equivalent.

## Decision

1. **A child session is an ordinary `Sadld.Session` with a parent.** The
   store records `parent_id`. The child inherits the parent's cwd, model,
   provider, tools, permission policy, system prompt and plugins, and its
   plugins hear `session.created` with `parentID`. Deleting a session
   deletes its children.
2. **Children are hidden from clients.** `session.list` (and so `sadl ls`)
   leaves them out, and the client protocol does not change. Child sessions
   are plugin and subagent internals. A client that resumes a child's id
   still gets it.
3. **A child never asks for permission.** No client watches a child, so a
   call its policy would ask about is denied rather than left waiting
   forever. Rules that allow or deny still apply.
4. **`session.prompt` waits for the turn and answers with the final
   assistant message**, as opencode's does. `Sadld.Session.prompt/3` does
   the waiting in the session itself, which replies when the turn ends, so
   no subscription can race the turn.
5. **A busy session refuses a turn at once instead of queueing it.** That is
   the deadlock guard. A hook runs in a turn, so if it prompts its own
   session it gets `-32003` back at once. A cycle of sessions prompting each
   other fails the same way, because every session in the cycle is busy.
6. **The `task` tool is built in for top-level sessions.** It runs its
   `prompt` in a new child with `Sadld.Session.prompt/3` and returns the
   reply. Children are not offered it, which bounds recursion at one level.
   The child is kept, so a plugin can still read it, and it goes when its
   parent is deleted.

## Consequences

- Waiting for a child's turn has no timeout. A provider that never answers
  holds the parent's turn until it is cancelled.
- Cancelling a parent's turn does not cancel a child it is waiting on. The
  child's turn runs to completion on its own.
- A user whose policy asks about plugin tools must allow them for children
  to use them. For example, thatch's extraction child needs
  `thatch_memory_remember` allowed.
- Children accumulate in the store until their parent is deleted. Nothing
  deletes sessions yet apart from plugins.
