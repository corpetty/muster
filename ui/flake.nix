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
    muster_module.url = "git+file:///home/petty/Github/corpetty/muster?dir=module";
    # ADR-013: build the UI on a basecamp-COHERENT builder instead of following
    # muster_module's Nim-cdylib builder, so the generated client + QtRO view-glue
    # compile against basecamp's own cpp-sdk/qt-sdk/protocol and ABI-match its
    # ui-host (exo-c6a). Pinned to basecamp's current top-level builder rev.
    logos-module-builder.url = "github:logos-co/logos-module-builder/4717b9af35d88a20a960067ee55bc5417af5a1f0";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    let
      base = logos-module-builder.lib.mkLogosQmlModule {
        src = ./.;
        configFile = ./metadata.json;
        # metadata.json#dependencies = ["muster_module"], resolved from the input
        # of the same name so the generated modules().muster_module client is typed,
        # and so muster_module is bundled into the standalone runner's module set.
        flakeInputs = inputs;
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
