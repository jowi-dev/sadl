{
  description = "sadl - thin Rust TUI client + Elixir agent server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # The opencode plugin sadld hosts in a Bun sidecar (ADR-0004). Pinned by
    # rev: its package bundles the patched native ONNX runtime, and the
    # sidecar relies on its plugin surface staying put.
    thatch.url = "github:jowi-dev/thatch/8e84a8bf304eb86dd74afb44a04afc4b50e9ff4a";
  };

  outputs = { self, nixpkgs, flake-utils, thatch }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        beam = pkgs.beam.packages.erlang_27;
        # thatch builds only where it has a pinned dependency hash.
        thatchPkg = thatch.packages.${system}.default or null;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # client/
            pkgs.cargo
            pkgs.rustc
            pkgs.rust-analyzer
            pkgs.clippy
            pkgs.rustfmt

            # server/
            beam.elixir_1_18
            beam.erlang
            pkgs.elixir-ls

            # server/priv/sidecar
            pkgs.bun

            pkgs.gh
          ];

          # Keep mix/hex state inside the repo instead of $HOME.
          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export ERL_AFLAGS="-kernel shell_history enabled"
          '' + pkgs.lib.optionalString (thatchPkg != null) ''
            # The plugin sadld's sidecar loads for each worktree.
            export SADL_THATCH_PLUGIN=${thatchPkg}/libexec/thatch/src/index.ts
          '';
        };
      }
    );
}
