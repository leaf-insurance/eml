{
  description = "eml: a pure Gleam parser for MIME email (.eml) messages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        beamPackages = pkgs.beam.packages.erlang_28;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.gleam
            beamPackages.erlang
            beamPackages.rebar3
            # For the Elixir smoke test.
            beamPackages.elixir
            # For the JavaScript target.
            pkgs.nodejs_24
          ];
        };

        formatter = pkgs.nixfmt;
      }
    );
}
