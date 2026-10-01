{
  description = "sadl - thin Rust TUI client + Elixir agent server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        beam = pkgs.beam.packages.erlang_27;
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

            pkgs.gh
          ];

          # Keep mix/hex state inside the repo instead of $HOME.
          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export ERL_AFLAGS="-kernel shell_history enabled"
          '';
        };
      }
    );
}
