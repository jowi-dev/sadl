# ADR-0005: Discover opencode-style skills and load them with a `skill` tool

**Status:** Accepted
**Date:** 2026-10-12

## Problem

thatch ships its fact extraction, review and writing behaviour as skills:
`SKILL.md` files with YAML front matter (`name`, `description`) and a
markdown body. Its nudges tell the model to load one by name, such as
`thatch-fact-extractor`. Without a way to find and load skills, those
nudges point at nothing (ADR-0004 hosts the plugin but not its skills).

## Decision

1. **Skills use opencode's layout**: `<skills dir>/<dir>/SKILL.md`. Only
   `name` and `description` are read from the front matter, as single-line
   `key: value` pairs; the rest of the file is the body. Files without
   both fields are skipped.
2. **Skills dirs, most specific first; the first to claim a name wins:**
   1. `.opencode/skills` in the session's working directory and each
      ancestor, nearest first;
   2. `$XDG_CONFIG_HOME/sadl/skills`;
   3. `$XDG_CONFIG_HOME/opencode/skills`.

   A project overrides the user, and the user's own sadl skills override
   the ones opencode plugins install. This matches the context-file order in
   `Sadld.SystemPrompt`, where the most specific instructions also win.
3. **A built-in `skill` tool** takes a name and returns the skill's body,
   headed by its name and directory so the model can resolve files the
   skill mentions. It looks skills up on every call.
4. **The system prompt lists every available skill** (name and
   description) when the `skill` tool is offered, so the model knows they
   exist. The tool's own description stays static because tool specs are
   not built per working directory.

## Where thatch's skills come from

The thatch plugin installs its skills itself: its `server()` calls
`installSkills` into `${XDG_CONFIG_HOME:-~/.config}/opencode/skills`, which
is dir 3 above. That runs when sadld starts the plugin's sidecar, so no
setup step is needed. `thatch setup` installs into `~/.claude/skills` for
Claude Code instead, which sadld does not search.

## Consequences

- With thatch, the skill list adds about 12 KB to every system prompt (36
  skills, long descriptions). opencode pays the same in its tool
  description.
- A session's prompt lists the skills found when it started. Skills
  installed later (for example by the very first plugin start on a machine)
  can still be loaded by name but are not listed until the next session.
- Full YAML (multi-line or nested values) is not parsed. Add a YAML
  library if a skill needs it.
