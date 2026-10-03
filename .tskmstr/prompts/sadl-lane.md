# sadl work lane

Autonomous work session for a single ticket in this repository. Do
not scope-creep beyond the named ticket.

Tickets are GitHub issues on `jowi-dev/sadl`. A ticket key is
`SADL-<issue number>`, so issue #12 is `SADL-12`.

## Start

1. Run `tm ready <KEY>` and stop if it reports the ticket blocked.
2. Read the issue with `gh issue view <number>`. `tm ready` does not
   enforce the prose `Depends on #N` lines in issue bodies. For each one,
   check `gh issue view N --json state`. If any dependency is still open,
   stop and report the ticket as blocked on it.
3. Work only `<KEY>`. Note unrelated bugs or cleanup as follow-ups
instead of fixing them here.

## Repo layout

- `client/` is the Rust TUI (crate `sadl`): a renderer and input device
  only. It holds no conversation state, makes no LLM calls, runs no tools.
- `server/` is the Elixir/OTP daemon (app `sadld`). Sessions, tools, the
  provider, and persistence all live here.
- `protocol/fixtures/` holds golden JSON fixtures. Both test suites must
  decode and re-encode every fixture losslessly. A protocol change updates
  `docs/protocol.md`, the fixtures, and both sides' types together.
- `docs/architecture.md` is the design draft. Settled decisions live in
  `docs/decisions/`. Do not rewrite an accepted ADR; add a new one if a
  ticket changes a decision.

## Workflow

- Run every toolchain command inside the Nix dev shell: `nix develop -c
  <cmd>` (or an already-loaded direnv shell). Do not install toolchains or
  dependencies outside the flake.
- Write a failing test before the implementation that makes it pass.
- Keep commits small and focused, one logical change per commit, with
  imperative-mood messages ("Add socket listener", not "Added ...").
- Do not add a `Co-Authored-By: Claude` trailer to commits.
- Stay on the branch and worktree `tm work` provisioned for this ticket.
  Never commit or push to `main`.
- Open the pull request with `tm pr create` against `main`.

## Hazards

- `nix develop` creates and stages a `flake.lock` when none is tracked.
  Do not commit it unless the ticket asks for it; unstage and delete it
  otherwise.
- Do not edit `flake.nix` unless the ticket requires a toolchain change.
- Do not edit `.tskmstr.toml` or `.tskmstr/`; they configure this lane.
- Build outputs (`client/target/`, `server/_build/`, `server/deps/`) and
  the in-repo `.nix-mix/` and `.nix-hex/` homes are gitignored. Never
  force-add them.

## Before finishing

Leave every check below green, in this order. Run each from the repo
root through the dev shell. Skip a half of the repo only if its project
does not exist yet (`client/Cargo.toml` or `server/mix.exs` is missing);
the ticket that generates it (SADL-1) must make its checks pass.

Client (`client/`):

1. `nix develop -c cargo fmt --manifest-path client/Cargo.toml --check`
2. `nix develop -c cargo clippy --manifest-path client/Cargo.toml --all-targets -- -D warnings`
3. `nix develop -c cargo test --manifest-path client/Cargo.toml`

Server (`server/`):

4. `nix develop -c sh -c 'cd server && mix format --check-formatted'`
5. `nix develop -c sh -c 'cd server && mix compile --warnings-as-errors'`
6. `nix develop -c sh -c 'cd server && mix credo'`
7. `nix develop -c sh -c 'cd server && mix test'`

Fix formatting with `cargo fmt` / `mix format` rather than by hand. Before
opening the PR, confirm `git status` is clean apart from intended changes.
