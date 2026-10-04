# ADR-0002: erlexec for shell execution

**Status:** Accepted
**Date:** 2026-10-04

## Problem

The `bash` tool must kill a command's whole process group on timeout or
cancel, so commands that background children (`sleep 100 &`) leave no
orphans. The architecture draft allowed either `erlexec` or `MuonTrap`.

## Decision

Use **`erlexec`**. It puts the command in its own process group
(`{group, 0}`) and kills the group when the command exits or is stopped
(`kill_group`). MuonTrap kills descendants only through cgroups; without a
writable cgroup hierarchy it signals the direct child alone, which leaves
backgrounded children running.

## Consequences

- erlexec builds a C++ port program, so the dev shell's compiler is a
  build dependency of the server.
- erlexec stops a command when its starter dies only if the starter
  linked to it, and that link also carries the command's exit. The `bash`
  tool therefore starts commands from a short-lived runner that is linked
  to the calling turn and traps exits, so cancelling the turn kills the
  group without a non-zero exit crashing the turn.
