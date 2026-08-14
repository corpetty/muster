{
  description = "Muster demo UI - QML view + C++ backend module (forked from logos-chat-ui v0.2.2)";

  nixConfig = {
    extra-substituters = [ "https://cache.nix.logos.co/public" ];
    extra-trusted-public-keys = [ "public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=" ];
  };

  inputs = {
    # Follow chat_module's own builder, so the logos-protocol/logos-qt-sdk
    # chain matches across both.
    logos-module-builder.follows = "chat_module/logos-module-builder";
    # Pinned to the v0.2.2 release tag: this view and the module it renders are
    # released in lockstep, so the module built here is the release the package
    # manager resolves.
    chat_module.url = "github:logos-co/logos-chat-module/v0.2.2";
    # Follow chat_module's delivery pin, so both build against the same
    # delivery module.
    logos-delivery-module.follows = "chat_module/logos-delivery-module";
    # The execution-zone wallet. Muster calls it dynamically (invokeRemoteMethod
    # by name, the way hackyguru/persona does) rather than binding a generated
    # client, so this input exists to put lez_core in the runtime module set.
    lez_core.url = "github:logos-blockchain/logos-execution-zone-module";
  };

  outputs = inputs@{ logos-module-builder, logos-delivery-module, ... }:
    let
      base = logos-module-builder.lib.mkLogosQmlModule {
        src = ./.;
        configFile = ./metadata.json;
        flakeInputs = { delivery_module = logos-delivery-module; } // inputs;
      };

      nixpkgs = logos-module-builder.inputs.nixpkgs;

      # `nix run .#exchange`: drive the real two-party message round-trip and hold
      # the receiving window open showing the result. The doc-test launches this
      # to capture one post-exchange screenshot (see doctests/chat-ui-exchange.test.yaml);
      # the full flow lives in docs/two-instance-exchange.md. APP_BIN is this
      # flake's standalone runner; the driver scripts are bundled from
      # ./doctests/exchange.
      exchangeRunner = system:
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.writeShellApplication {
          name = "chat-ui-exchange";
          runtimeInputs = with pkgs; [ nodejs coreutils util-linux procps bash ];
          text = ''
            export APP_BIN="${base.apps.${system}.default.program}"
            exec bash ${./doctests/exchange}/run-exchange-show.sh "$@"
          '';
        };

      # `nix run .#group`: form a real three-party group conversation and hold the
      # newest member's window open showing the result. The doc-test launches this
      # to capture one screenshot of the formed group (see
      # doctests/chat-ui-group.test.yaml). APP_BIN is this flake's standalone
      # runner; the driver scripts are bundled from ./doctests/group.
      groupApp = system:
        let
          pkgs = import nixpkgs { inherit system; };
          runner = pkgs.writeShellApplication {
            name = "chat-ui-group";
            runtimeInputs = with pkgs; [ nodejs coreutils util-linux procps bash ];
            text = ''
              export APP_BIN="${base.apps.${system}.default.program}"
              exec bash ${./doctests/group}/run-group-show.sh "$@"
            '';
          };
        in {
          type = "app";
          program = "${runner}/bin/chat-ui-group";
        };
      # `nix build .#runner`: the standalone runner, exposed as a package purely
      # so it can be pre-built.
      #
      # `nix run .` resolves apps.default, which is a *different* derivation
      # from packages.default -- the latter is the .lgx module. So
      # `nix build .#default` warms the wrong thing entirely, and the first
      # `nix run` then builds the LEZ proving stack from Rust source: measured
      # 2026-08-14 at 827 cargo derivations and counting after 36 minutes, on a
      # store with nothing cached. `make app` used to do exactly that and
      # returned in seconds looking successful.
      #
      # The wrapper exists because apps.default.program is a *string* path, not
      # a derivation; interpolating it here puts the runner in this package's
      # build closure, which is what makes building this warm that.
      runnerPkg = system:
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.writeShellScriptBin "muster-runner"
             ''exec ${base.apps.${system}.default.program} "$@"'';
    in
      base // {
        apps = builtins.mapAttrs
          (system: sysApps: sysApps // {
            exchange = { type = "app"; program = "${exchangeRunner system}/bin/chat-ui-exchange"; };
            group = groupApp system;
          })
          base.apps;
        # Also a package so `nix build .#exchange` resolves: the doc-test runner
        # pre-builds its launch target that way to warm the store before the run.
        packages = builtins.mapAttrs
          (system: sysPkgs: sysPkgs // {
            exchange = exchangeRunner system;
            runner = runnerPkg system;
          })
          base.packages;
      };
}
