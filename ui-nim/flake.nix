{
  description = "muster's Nim UI (exo-607): a standalone nim-seaqt app on the newest Qt (ADR-019)";

  inputs = {
    # The app's own nixpkgs, and with it its Qt: nixos-unstable, Qt 6.11.2 (T1b, ADR-019
    # "newest everything"). seaqt compiles against Qt's private headers and loads only on
    # the Qt minor it was generated for or newer, and one process cannot hold two Qt
    # copies — so EVERYTHING the app loads in-process is built here on this Qt, the two
    # Logos libraries (below) included. Pin by commit.
    # Pinned in nix/nixpkgs-app (nixos-unstable 7fd4004d + an overlay for the Logos tree).
    nixpkgs.url = "path:./nix/nixpkgs-app";

    # The Logos runner's builder. It is no longer the app's Qt: the app takes from it only
    # what runs in OTHER processes — logos_host, the modules and the (pure-QML) design
    # system — which keep Logos's Qt 6.9.2 and reach the app over QtRemoteObjects
    # (`QtRO 2.0`, QDataStream Qt_6_2, in 6.9.2 and 6.11.2 alike). Bump with ui/flake.nix.
    logos-module-builder.url = "github:logos-co/logos-module-builder/4717b9af35d88a20a960067ee55bc5417af5a1f0";

    # liblogos (liblogos_core: start the core, load modules, hand out tokens), rebuilt on
    # the app's Qt. Same rev as the runner's (logos-standalone-app's logos-liblogos); its
    # flake.lock resolves every input to the runner's revs, checked 2026-10-14. Every
    # Logos input under it takes nixpkgs from its own logos-nix, so that nixpkgs is
    # redirected at each one (generated from the lock; the capability module's build
    # tooling is left alone, as nothing of it links into liblogos_core).
    logos-liblogos = {
      url = "github:logos-co/logos-liblogos/64de644ec6c8fcad1eee3546255002f4ff929c21";
      inputs.default-container.inputs.logos-container.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.default-container.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.default-module-loader.inputs.logos-container.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.default-module-loader.inputs.logos-module.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.default-module-loader.inputs.logos-module-loader.inputs.logos-container.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.default-module-loader.inputs.logos-module-loader.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.default-module-loader.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-container.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-cpp-sdk.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-module.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-module-loader.inputs.logos-container.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-module-loader.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-package-manager.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-package-manager.inputs.logos-package.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-package-manager.inputs.nix-bundle-appimage.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-package-manager.inputs.nix-bundle-appimage.inputs.nix-bundle-dir.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-package-manager.inputs.nix-bundle-dir.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-protocol.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-qt-sdk.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
      inputs.process-stats.inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
    };
    # logos-protocol's liblogos_protocol: the lp_* consumer ABI. The SAME rev the modules
    # embed (logos-module-builder's logos-protocol), rebuilt on the app's Qt.
    logos-protocol = {
      url = "github:logos-co/logos-protocol/6401e30ae1cfabac77285ee8e7a82c2cef3858f1";
      inputs.logos-nix.inputs.nixpkgs.follows = "nixpkgs";
    };

    # nim-seaqt's qt-6.11 branch (head 2026-11-17), generated for Qt 6.11.1: the app's Qt
    # is 6.11.2. Since that regeneration it carries QtRemoteObjects (seaqt-gen #18, with
    # #20 and #21), so T3's build-time generation is gone (exo-c49).
    # The branches are rebased upstream — pin by commit, never by branch.
    nim-seaqt = {
      url = "github:seaqt/nim-seaqt/6956721d703242733eaa44e0269b4c7551c5c4b6";
      flake = false;
    };
    # nimside: the qobject: DSL (compile-time QMetaObject, the moc replacement) and the
    # plugin macros, extracted from nora-poc. Preview-grade; pinned by commit.
    nimside = {
      url = "github:seaqt/nimside/38406061afd5d24a57d8f6cb8cdcc5930bb67bc8";
      flake = false;
    };
    # logos_sdk: the lp_* binding and the generator of the typed muster_module client
    # (nix/muster-client.nix). main, with the async client twins merged (#7). Ahead of
    # module/metadata.json's pin (6077eb7) by those twins only, which only a consumer
    # uses; the module moves here when its pin next moves.
    logos-nim-sdk = {
      url = "github:corpetty/logos-nim-sdk/a710a31a940c99b7d5ad811f7f31aa4913f5032a";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, logos-module-builder, logos-liblogos, logos-protocol, nim-seaqt, nimside, logos-nim-sdk }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      # The app itself builds on plain nixos-unstable (its default compiler, Boost, …). Only
      # the Logos tree takes nix/nixpkgs-app's overrides. Qt is the same store path in both.
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs.inputs.upstream { inherit system; }));
      seaqtApp = pkgs: pkgs.callPackage ./nix/seaqt-app.nix { inherit nim-seaqt nimside; };
      # The view contract and the QML that uses it, shared with the C++ build (ui/).
      viewContract = ../ui/src/muster_ui.rep;
      viewQml = ../ui/src/qml;
      # The module's contract, from which the app's typed muster_module client is
      # generated at build time (T5).
      musterLidl = ../module/src/api/muster.lidl;
      logosLidl = system: logos-module-builder.inputs.logos-cpp-sdk.inputs.logos-lidl.packages.${system}.logos-lidl;
      musterClient = pkgs: import ./nix/muster-client.nix {
        inherit pkgs logos-nim-sdk;
        lidl = logosLidl pkgs.stdenv.hostPlatform.system;
        contract = musterLidl;
      };
      # Option B's Logos pieces, split by process (T1b, ADR-019).
      #   In the app's process, on the app's Qt: liblogos_core (the core's C API) and
      #   liblogos_protocol (the lp_* consumer ABI), rebuilt from the runner's revs.
      #   In processes of their own, on Logos's Qt: logos_host and the design system
      #   (pure QML), straight from the runner's logos-standalone-app.
      logosRunner = system: logos-module-builder.inputs.logos-standalone-app.packages.${system}.default;
      logosCore = system: logos-liblogos.packages.${system}.default;
      logosProtocol = system: logos-protocol.packages.${system}.logos-protocol-lib;
    in {
      # A builder for seaqt apps, for the later slices (T2 onward): seaqtApp pkgs { pname; src; main; }
      lib.seaqtApp = seaqtApp;

      packages = forAll (pkgs: rec {
        # T1: one QML file, one nimside qobject:, bound both ways. `--self-test` asserts it.
        hello = seaqtApp pkgs { pname = "seaqt-hello"; src = ./hello; main = "hello.nim"; qml = [ "hello.qml" ]; };
        # T2: the view contract, declared by repContract from the .rep the C++ build's repc
        # reads, and its check (checks.contract). `--dump` prints the generated declaration.
        contract-test = seaqtApp pkgs {
          pname = "muster-contract-test";
          src = ./contract;
          main = "contract_test.nim";
          nimFlags = [ "-d:musterRep=${viewContract}" ];
        };
        # T4a: muster's real QML in a Nim host (option B). `--self-test` loads the view
        # against stub Impls; `--self-test-core --modules <dir> --user-dir <dir>` also
        # starts logos-core and calls muster_module (scripts/nim-app-core-probe.sh).
        muster-app = let runner = logosRunner pkgs.stdenv.hostPlatform.system; core = logosCore pkgs.stdenv.hostPlatform.system; lp = logosProtocol pkgs.stdenv.hostPlatform.system; in seaqtApp pkgs {
          pname = "muster-app";
          src = ./.;
          main = "app/muster_app.nim";
          nimFlags = [
            "-d:musterRep=${viewContract}" "-d:musterQml=${viewQml}" "-d:musterMetadata=${../ui/metadata.json}"
            "-d:logosQmlImports=${runner}/lib" "--path:${logos-nim-sdk}/src"
            "--path:${musterClient pkgs}"
            "--passL:-L${core}/lib -llogos_core -Wl,-rpath,${core}/lib"
            "--passL:-L${lp}/lib -llogos_protocol -Wl,-rpath,${lp}/lib"
          ];
          # The runner's logos_host: the module processes stay on Logos's Qt.
          extraAttrs.qtWrapperArgs = [ "--set-default" "LOGOS_HOST_PATH" "${runner}/bin/logos_host" ];
          # The design system's icons are SVG: without qtsvg's image plugin they draw blank.
          extraBuildInputs = [ pkgs.qt6.qtsvg ];
        };
        # T7: the headless host (the port of module/tools/headless-host's C++): the core
        # and muster_module in-process, a stdin REPL over lp_*. headless/drive.py drives it.
        headless-host = let runner = logosRunner pkgs.stdenv.hostPlatform.system; core = logosCore pkgs.stdenv.hostPlatform.system; lp = logosProtocol pkgs.stdenv.hostPlatform.system; in seaqtApp pkgs {
          pname = "muster-headless-host";
          src = ./.;
          main = "headless/muster_headless_host.nim";
          nimFlags = [
            "--path:${logos-nim-sdk}/src"
            "--passL:-L${core}/lib -llogos_core -Wl,-rpath,${core}/lib"
            "--passL:-L${lp}/lib -llogos_protocol -Wl,-rpath,${lp}/lib"
          ];
          extraAttrs.qtWrapperArgs = [ "--set-default" "LOGOS_HOST_PATH" "${runner}/bin/logos_host" ];
        };
        # T3: QtRemoteObjects from Nim (nim-seaqt binds it since 2026-11-17), and its proof
        # (checks.ro): a nimside source remoted over local:, acquired as a dynamic replica,
        # driven both ways.
        ro-test = seaqtApp pkgs {
          pname = "seaqt-ro-test";
          src = ./ro;
          main = "ro_test.nim";
          extraBuildInputs = [ pkgs.qt6.qtremoteobjects ];
        };
        # T5: muster_module's typed client, generated from muster.lidl.
        muster-client = musterClient pkgs;
        # T1b: the two Logos libraries the app loads in-process, on the app's Qt.
        logos-core = logosCore pkgs.stdenv.hostPlatform.system;
        logos-protocol-lib = logosProtocol pkgs.stdenv.hostPlatform.system;
        default = hello;
      });

      checks = forAll (pkgs: {
        # The toolchain gate: the app builds against the runner's Qt and passes its own
        # self-test offscreen. `nix flake check` / `nix build .#checks.<system>.hello`.
        hello = pkgs.runCommand "seaqt-hello-self-test" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
          ${self.packages.${pkgs.stdenv.hostPlatform.system}.hello}/bin/seaqt-hello --self-test | tee $out
        '';
        # T4a's view half, in the sandbox: the real Main.qml loads in the Nim host and
        # binds to the contract (no core; scripts/nim-app-core-probe.sh adds muster_module).
        muster-app-view = pkgs.runCommand "muster-app-view-check" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
          ${self.packages.${pkgs.stdenv.hostPlatform.system}.muster-app}/bin/muster-app --self-test | tee $out
        '';
        # The T2 gate: repc (the pinned qtremoteobjects) generates the typed source from the
        # view contract; the nimside declaration must present QtRO the same API, index for
        # index, and every backend.<name> in the real QML must be in it.
        ro = pkgs.runCommand "seaqt-ro-check" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR=$TMPDIR
          ${self.packages.${pkgs.stdenv.hostPlatform.system}.ro-test}/bin/seaqt-ro-test | tee $out
        '';
        contract = pkgs.runCommand "muster-contract-check" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen
          ${pkgs.qt6.qtremoteobjects}/libexec/repc -o source ${viewContract} $TMPDIR/rep_source.h
          ${self.packages.${pkgs.stdenv.hostPlatform.system}.contract-test}/bin/muster-contract-test \
            --repc $TMPDIR/rep_source.h --qml ${viewQml} | tee $out
        '';
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.nim pkgs.pkg-config pkgs.qt6.qtbase pkgs.qt6.qtdeclarative ];
          SEAQT = "${nim-seaqt}";
          NIMSIDE = "${nimside}/src";
        };
      });
    };
}
