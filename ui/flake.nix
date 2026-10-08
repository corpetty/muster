{
  description = "muster-ui — QML view + C++ backend calling muster_module through the logos API (P4 loading spike)";

  inputs = {
    # The muster core module — kept as an input ONLY so its published `.lidl`
    # output (packages.<sys>.lidl, a copy of the committed muster.lidl) is read
    # to generate the typed modules().muster_module client. Its own plugin is
    # built by its own flake (the Nim-cdylib builder) and is NOT rebuilt here.
    # git+file (not path:) so only the git-TRACKED tree is read — a path: input
    # copies untracked build symlinks/scratch, which changes muster_module's
    # derivation and breaks its Nim build (pkg/results). Tracked tree == what
    # `cd module && nix build` uses. Commit module changes for them to be seen.
    # RELATIVE (`../` = the repo root from ui/), so it resolves from any clone —
    # not a machine-local absolute path (exo-1ec.2). A plain `nix build` here uses this
    # pin directly. NOTE (exo-fb7): nix re-fetches a relative git input at eval time
    # ("file:../ not supported") and that fetch + the eval cache can go stale, so
    # `make build` does NOT rely on this ref — it OVERRIDES muster_module with an absolute
    # git+file path derived from $(CURDIR) (portable, computed at build time) and disables
    # the eval cache, making .run/runner a deterministic function of the committed tree.
    muster_module.url = "git+file:../?dir=module";
    # ADR-013: build the UI on a basecamp-COHERENT builder instead of following
    # muster_module's Nim-cdylib builder, so the generated client + QtRO view-glue
    # compile against basecamp's own cpp-sdk/qt-sdk/protocol and ABI-match its
    # ui-host (exo-c6a). Pinned to basecamp's current top-level builder rev.
    logos-module-builder.url = "github:logos-co/logos-module-builder/4717b9af35d88a20a960067ee55bc5417af5a1f0";
    # The real transport (P3): muster_module depends on delivery_module (it calls it
    # over the lp_* ABI to boot delivery's Waku node and carry the sealed room
    # frames). It must therefore be in the standalone runner's module set, so
    # coordinate_join's lp_client_create("delivery_module") resolves. v0.3.x is
    # Testnet v0.3's (exo-eb6.1): logos.dev is cluster 3 there, and logos.test needs
    # the RLN modules and a funded membership (exo-eb6.3). v0.3.2 (logos-delivery
    # v0.39.1) is Basecamp 0.3.2's catalog release; its store catch-up keeps to the
    # store's 24 h query limit, where v0.3.0's is refused on every first launch
    # (exo-dcc.12). Same pin as module/flake.nix. Mapped to the module name
    # `delivery_module` below.
    logos-delivery-module.url = "github:logos-co/logos-delivery-module/v0.3.2";
    # The LEZ wallet (P-L3): muster_module calls lez_core over lp_* to send assets on
    # the zone, so it must be in the standalone runner's module set for
    # lp_client_create("lez_core") to resolve. lez_core 0.5.0, LEZ 0.3.0 (b89e5d2,
    # exo-eb6.4); the demo/ speed build keeps its own older pin.
    lez_core.url = "github:logos-blockchain/logos-execution-zone-module/b89e5d24df5babc2490d2e5d47756fb1f33435dd";
    # The official EVM keystore (exo-149): muster_module calls keystore_module over lp_*,
    # so it must be in the standalone runner's module set. Same pin as module/flake.nix
    # (Basecamp 0.3.1's catalog release, keystore_module 0.1.0). muster_ui does not call it.
    logos-evm-keystore-module.url = "github:logos-co/logos-evm-keystore-module/2318c679e2b7176967bd45052f3d64b2a8b06931";
    # The platform's EVM RPC (exo-d4d.3): muster_module reads chains through it over lp_*, so
    # it rides the runner's module set. Same pin as module/flake.nix (eth_rpc_module 0.1.0).
    logos-evm-eth-rpc-module.url = "github:logos-co/logos-evm-eth-rpc-module/42cc465e0cbd748117a0af0cf983404348683335";
    # tx_sender_module (exo-d4d.5) and fee_module, which it needs to load: the catalog's 0.1.0s.
    logos-evm-tx-sender-module.url = "github:logos-co/logos-evm-tx-sender-module/7cd2fead60a78ac9ac8a4337fd9f01e1ab5515e2";
    logos-evm-fee-module.url = "github:logos-co/logos-evm-fee-module/5bf49b768cf178d2e8c58267f17822060f813fbf";
    # The RLN modules a delivery v0.3 node on logos.test needs (exo-eb6.3 R1). The packages
    # are delivery v0.3.2's own re-exports, so their versions are the ones it was built
    # against; this pins only their LIDL contracts, at the same rev (logos-rln-modules
    # 25357cf), for the code generator.
    logos-rln-modules = { url = "github:logos-co/logos-rln-modules/25357cfd877ba18d6e0880564b8fd7ba0abf2d70"; flake = false; };
  };

  outputs = inputs@{ logos-module-builder, ... }:
    let
      # delivery_module as this builder sees it (exo-eb6.1). The runner bundles the
      # real module (its packages.<sys>.lgx, untouched). But this builder's code
      # generator also parses every dependency's packages.<sys>.lidl, and delivery
      # v0.3.0's contract declares `optional_depends [...]`, which its LIDL parser
      # (basecamp's, ADR-013) predates. muster_ui never calls delivery, so its contract
      # is handed over without that one line; nothing the UI uses changes.
      deliveryForUi =
        let d = inputs.logos-delivery-module;
        in d // {
          packages = builtins.mapAttrs (system: ps: ps // {
            lidl = (import logos-module-builder.inputs.nixpkgs { inherit system; }).runCommand
              "delivery_module-lidl-for-muster-ui" { } ''
                mkdir -p $out
                sed '/^[[:space:]]*optional_depends[[:space:]]/d' ${ps.lidl}/delivery_module.lidl > $out/delivery_module.lidl
              '';
          }) d.packages;
        };
      # The RLN modules as this builder sees them (exo-eb6.3 R1). The runner's host predates
      # `optional_dependencies`, the way delivery v0.3.0 declares them, so it would never
      # load them for delivery; muster declares them itself instead. Each is delivery's
      # re-exported .lgx, plus its contract from logos-rln-modules for the generator.
      rlnModule = name: lidlPath: {
        packages = builtins.mapAttrs (system: ps: {
          lgx = ps."${name}-lgx";
          lidl = (import logos-module-builder.inputs.nixpkgs { inherit system; }).runCommand
            "${name}-lidl-for-muster-ui" { } ''
              mkdir -p $out
              cp ${inputs.logos-rln-modules}/${lidlPath} $out/${name}.lidl
            '';
        }) inputs.logos-delivery-module.packages;
      };
      base = logos-module-builder.lib.mkLogosQmlModule {
        src = ./.;
        configFile = ./metadata.json;
        # metadata.json#dependencies = ["muster_module"], resolved from the input
        # of the same name so the generated modules().muster_module client is typed,
        # and so muster_module is bundled into the standalone runner's module set.
        # delivery_module is muster_module's transitive dependency; it is provided
        # here (mapped from logos-delivery-module) so the builder can pull it into
        # the same module set — muster_ui does not call it, so it declares no client.
        flakeInputs = {
          delivery_module = deliveryForUi;
          lez_core = inputs.lez_core;
          keystore_module = inputs.logos-evm-keystore-module;
          eth_rpc_module = inputs.logos-evm-eth-rpc-module;
          tx_sender_module = inputs.logos-evm-tx-sender-module;
          fee_module = inputs.logos-evm-fee-module;
          liblogos_rln_module = rlnModule "liblogos_rln_module" "logos-rln-module/rust-lib/liblogos_rln_module.lidl";
          liblogos_lez_rln_module = rlnModule "liblogos_lez_rln_module" "logos-lez-rln-module/rust-lib/liblogos_lez_rln_module.lidl";
        } // inputs;
      };

      nixpkgs = logos-module-builder.inputs.nixpkgs;

      # `.#runner`: the standalone runner (logos-standalone-app hosting the muster
      # view + muster_module), exposed as a buildable PACKAGE so it can be
      # pre-built/GC-rooted. `nix run .` resolves apps.default — a *different*
      # derivation — so `nix build .#default` warms the .lgx, not the runner.
      # apps.default.program is a string path, so interpolating it here pulls the
      # runner into this package's closure, which is what makes building it warm
      # the run target (same trick as demo/muster-ui/flake.nix).
      runnerPkg = system:
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.writeShellScriptBin "muster-ui"
             ''exec ${base.apps.${system}.default.program} "$@"'';
    in
      base // {
        packages = builtins.mapAttrs
          (system: sysPkgs: sysPkgs // { runner = runnerPkg system; })
          base.packages;
      };
}
