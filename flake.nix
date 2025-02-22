{
  description = "Psyche";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    nix-gl-host = {
      url = "github:arilotter/nix-gl-host-rs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        crane.follows = "crane";
        rust-overlay.follows = "rust-overlay";
      };
    };
  };

  outputs =
    inputs@{
      flake-parts,
      crane,
      rust-overlay,
      nix-gl-host,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { system, ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              (import rust-overlay)
              nix-gl-host.overlays.default
            ];

            config.allowUnfree = true;
            config.cudaSupport = true;
            config.cudaVersion = "12.4";
          };
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [ "rust-src" ];
          };
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

          testResourcesFilter =
            path: _type:
            (builtins.match ".*tests/resources/.*$" path != null)
            || (builtins.match ".*.config/.*$" path != null);
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            filter = path: type: (testResourcesFilter path type) || (craneLib.filterCargoSources path type);
          };

          torch = pkgs.libtorch-bin.dev.overrideAttrs (
            old:
            let
              version = "2.4.1";
              cuda = "124";
            in
            {
              version = version;
              src = pkgs.fetchzip {
                name = "libtorch-cxx11-abi-shared-with-deps-${version}-cu${cuda}.zip";
                url = "https://download.pytorch.org/libtorch/cu${cuda}/libtorch-cxx11-abi-shared-with-deps-${version}%2Bcu${cuda}.zip";
                hash = "sha256-/MKmr4RnF2FSGjheJc4221K38TWweWAtAbCVYzGSPZM=";
              };
            }
          );

          env = {
            CUDA_ROOT = pkgs.cudaPackages.cudatoolkit.out;
            LIBTORCH = torch.out;
            LIBTORCH_INCLUDE = torch.dev;
            LIBTORCH_LIB = torch.out;
          };

          commonArgs = {
            inherit env src;
            strictDeps = true;

            nativeBuildInputs = with pkgs; [
              pkg-config # for Rust crates to find their native deps: CUDA, OpenSSL, etc.
              perl # needed to build OpenSSL Rust crate
            ];

            # dynamicly linked, used at runtime
            buildInputs =
              [ torch ]
              ++ (with pkgs; [ openssl ])
              ++ (with pkgs.cudaPackages; [
                cudatoolkit
                cuda_cudart
                nccl
              ]);
          };

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          buildPackage =
            name:
            craneLib.buildPackage (
              commonArgs
              // {
                inherit cargoArtifacts;
                pname = name;
                cargoExtraArgs = "--bin ${name}";
                doCheck = false; # tests are run with nextest in `nix flake check`
              }
            );

          buildWholeWorkspace = craneLib.buildPackage (
            commonArgs
            // {
              inherit cargoArtifacts;
            }
          );
        in
        rec {
          devShells.default = pkgs.mkShell {
            inputsFrom = [ buildWholeWorkspace ];
            inherit env;
            buildInputs = with pkgs; [
              nvtopPackages.full

              just

            ];
          };
        };
    };
}
