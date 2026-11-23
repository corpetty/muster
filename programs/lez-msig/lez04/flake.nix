{
  # lez_msig_v04_module 0.2.0: lez-msig's private posture on LEZ v0.4 as a Logos module, named apart
  # from the v0.3 lez_msig_module so a host can hold both (exo-cc7;
  # docs/design/lez-msig.md §6, RFP-005 U.1). The v0.3 module (0.1.0) is ../flake.nix; the two
  # LEZ lines cannot share a dependency graph, so each is its own build of the same contract. The
  # cargo workspace here is the module package: the builder copies this directory and builds
  # `-p lez_msig_v04_module` (metadata.json's nix.rust.env), whose staticlib links into the plugin.
  # linux-amd64 first: risc0 on darwin needs LEZ's Metal workaround.
  description = "lez_msig_v04_module: proves and sends lez-msig's private transactions (LEZ v0.4)";

  nixConfig = {
    extra-substituters = [ "https://cache.nix.logos.co/public" ];
    extra-trusted-public-keys = [ "public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=" ];
  };

  inputs = {
    # Basecamp 0.3.2's generation: protocol 9d59f5de (0.9.0), cpp-sdk 3bf5365c, rust-sdk
    # 040e94e8 (Cargo.toml pins the same rev; tools/regen.sh checks). No SDK overrides.
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.3";

    # LEZ at the tag Cargo.lock pins: only its artifacts/ is read. lee's and programs' build
    # scripts embed the privacy circuit and the built-in programs from it (build_utils), found
    # by walking up from the crate, which a vendored crate cannot (see lezArtifactsHook).
    lez-src = { url = "github:logos-blockchain/logos-execution-zone/v0.4.0-rc3"; flake = false; };

    # The pins LEZ v0.4.0-rc3's own flake builds its wallet with (the same as v0.3.0's); keep them
    # in step with Cargo.lock.
    logos-blockchain-circuits.url = "github:logos-blockchain/logos-blockchain-circuits/2846ee7a4cfa24458bb8063412ab2e753b344d2f";
    rust-rapidsnark.url = "github:logos-blockchain/logos-blockchain-rust-rapidsnark/e91187f8ccb5bbfc7bb00dac88169112428da78f";
  };

  outputs = inputs@{ self, logos-module-builder, lez-src, logos-blockchain-circuits, rust-rapidsnark, ... }:
    let
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      systems = [ "x86_64-linux" ];
      forAllSystems = fn: nixpkgs.lib.genAttrs systems fn;

      module = system:
        let
          pkgs = import nixpkgs { inherit system; };
          # risc0-circuit-recursion 4.0.4 (as on v0.3) downloads this in build.rs unless RECURSION_SRC_PATH
          # names it; the hash is both its file name and its sha256 (LEZ's flake does the same).
          # Since 2026-11-23 risc0's bucket answers 403 (exo-ba5), so muster-v0.4.0 carries a copy;
          # the hash pins the bytes whichever answers, and S3 stays first so the store path holds.
          recursionZkr = pkgs.fetchurl {
            urls = [
              "https://risc0-artifacts.s3.us-west-2.amazonaws.com/zkr/744b999f0a35b3c86753311c7efb2a0054be21727095cf105af6ee7d3f4d8849.zip"
              "https://github.com/corpetty/muster/releases/download/muster-v0.4.0/744b999f0a35b3c86753311c7efb2a0054be21727095cf105af6ee7d3f4d8849.zip"
            ];
            sha256 = "744b999f0a35b3c86753311c7efb2a0054be21727095cf105af6ee7d3f4d8849";
          };
          # Put LEZ's artifacts/ where build_utils' upward walk looks from a vendored crate. The
          # builder takes no preBuild; a setup hook registers one (logos-co/lez-payment-streams'
          # flake does the same).
          lezArtifactsHook = pkgs.makeSetupHook { name = "lez-artifacts-hook"; }
            (pkgs.writeText "lez-artifacts-hook.sh" ''
              lezArtifactsLink() {
                for d in "$NIX_BUILD_TOP/cargo-vendor-dir" "$NIX_BUILD_TOP"; do
                  [ -d "$d" ] && ln -sfn ${lez-src}/artifacts "$d/artifacts"
                done
              }
              preBuildHooks+=(lezArtifactsLink)
            '');
          # The builder compiles only this directory, but msig_core lives in ../core (the same rules
          # for both LEZ lines). Stage a copy with core inside and the workspace pointing at it.
          moduleSrc = pkgs.runCommand "lez-msig-v04-module-src" {} ''
            cp -R --no-preserve=mode,ownership ${./.} $out
            cp -R --no-preserve=mode,ownership ${../core} $out/core
            sed -i 's|msig_core = { path = "../core" }|msig_core = { path = "core" }|' $out/Cargo.toml
            grep -q 'msig_core = { path = "core" }' $out/Cargo.toml
            # a path dependency inside the workspace directory becomes a member, and would pull
            # msig_core's dev-dependencies into a lockfile that does not hold them
            sed -i 's|exclude = \["methods/guest"\]|exclude = ["methods/guest", "core"]|' $out/Cargo.toml
            grep -q 'exclude = \["methods/guest", "core"\]' $out/Cargo.toml
          '';
        in
        logos-module-builder.lib.mkLogosModule {
          src = moduleSrc;
          configFile = ./metadata.json;
          flakeInputs = inputs;
          rustExtraNativeBuildInputs = [ lezArtifactsHook pkgs.llvmPackages.libclang ];
          rustEnv = {
            LBC_ROOT_DIR = "${logos-blockchain-circuits.packages.${system}.default}";
            RAPIDSNARK_LIB_DIR = "${rust-rapidsnark.packages.${system}.rapidsnark}";
            RECURSION_SRC_PATH = "${recursionZkr}";
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            # rocksdb + the risc0 prover + the LEZ graph: bound rustc's parallelism
            CARGO_BUILD_JOBS = "16";
          };
        };
    in
    {
      packages = forAllSystems (system: (module system).packages.${system});
    };
}
