# sadl

A lightweight agentic coding tool split into a thin Rust TUI client
(`client/`) and a long-lived Elixir server (`server/`), so many concurrent
sessions share one supervised backend instead of each paying for its own
runtime. Built to run as an agent runner for [tskmstr](../tskmstr) (`tm`).

See [`docs/architecture.md`](docs/architecture.md) for the design draft.

## Setup

```
direnv allow      # or: nix develop
```

Provides `cargo`/`rustc`/`clippy`/`rustfmt` and `elixir`/`erlang`/`mix`.
