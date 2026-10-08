# ADR-0003: Server lifecycle and upgrades

**Status:** Accepted
**Date:** 2026-10-07

## Problem

The MVP starts `sadld` from the client when its socket is missing (#13).
That leaves three questions open: whether to also ship a systemd user unit
(and a NixOS/home-manager module), how the two ways of starting the server
coexist, and how the server is upgraded without losing live sessions:
hot release upgrades, or drain-and-restart with resume from SQLite.

## Decision

1. **Client auto-start stays the default and the only path that must
   work.** `sadl` needs no setup beyond `sadld` on `PATH` (or `$SADLD`).
   Every other way of running the server is optional.
2. **Ship an optional systemd user unit**, `sadld.service`, that runs the
   release in the foreground (`Type=exec`, `ExecStart=sadld start`,
   `Restart=on-failure`). It is for users who want the server up at login,
   its logs in the journal, or its restarts managed. It needs no protocol
   or client change: the client finds the socket and connects. If an
   auto-started server already holds the socket, the unit's server refuses
   to start (`:eaddrinuse`) and systemd reports the failure; the user
   stops the auto-started server once and the unit owns it from then on.
3. **No systemd socket activation for now.** It would hand `sadld` a
   listening descriptor instead of a path, which the listener does not
   take, and the client's auto-start already covers "start on first use".
4. **A home-manager module (and NixOS user-service option) comes after
   the flake exports a `sadld` package.** The module installs the package
   and the unit above; it adds no behaviour of its own. Until the package
   exists there is nothing for a module to install.
5. **Upgrades are drain-and-restart, not hot code upgrades.** To upgrade,
   the old server stops accepting connections, gives running turns a grace
   period to finish, and exits; the new release starts (by the unit, or by
   the next client that finds the socket missing). Clients reconnect with
   backoff and `session.resume` their session from SQLite, as they already
   do after any disconnect. A turn still running when the grace period
   ends is lost; the client already tells the user so.
6. **Version skew is handled by the handshake.** A client that reconnects
   to a newer server either agrees on a `protocol_version` or gets error
   `-32000` with the supported versions and reports it. No other
   compatibility mechanism is added.

## Why not hot upgrades

- Every turn is already persisted before it is acknowledged, and sessions
  already resume from SQLite after a crash (ADR-0001). Drain-and-restart
  reuses that path; hot upgrades would be a second, rarely exercised one.
- Hot upgrades need appups/relups written and tested for every release,
  and state migrations for every changed `Session` state shape. That cost
  is paid on each release for a benefit of a few seconds per upgrade.
- Nix installs each release into its own immutable store path, which does
  not fit a release that upgrades itself in place.
- Native code (exqlite's NIF, erlexec's port program) cannot be swapped
  under a running VM anyway, so some upgrades would need a restart
  regardless.

## Consequences

- The cost of an upgrade is the in-flight turns at shutdown, bounded by
  the grace period. Idle sessions lose nothing.
- Follow-up work, each its own ticket:
  - a `mix release` named `sadld` (the client already runs `sadld start`,
    but no release is configured yet);
  - wire `autostart::connect_or_start` into `sadl` startup and the `Link`
    reconnect loop, so a client also restarts a server that went away;
  - graceful drain on SIGTERM: stop the listener, wait for running turns
    up to a grace period, then exit;
  - the `sadld.service` unit file;
  - a flake `packages.sadld` output, then the home-manager module.
- Revisit hot upgrades only if long-running turns make restarts costly in
  practice; resuming an interrupted turn from its persisted tool calls is
  the cheaper fix to try first.
