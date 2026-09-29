{
  description = "muster's Nim UI (exo-607): nim-seaqt + nimside, built against the exact Qt the Logos runner links";

  inputs = {
    # nixpkgs comes from the SAME logos-module-builder rev ui/flake.nix pins, so qt6 here
    # is the very qtbase-6.9.2 store path the standalone runner, ui-host and Basecamp
    # link. seaqt compiles against Qt's private headers and loads only on the Qt minor it
    # was generated for or newer, and one process cannot hold two Qt copies — so the Qt
    # must be identical, not merely compatible. Bump this together with ui/flake.nix.
    logos-module-builder.url = "github:logos-co/logos-module-builder/4717b9af35d88a20a960067ee55bc5417af5a1f0";

    # nim-seaqt's qt-6.8 branch: generated for Qt 6.8, so it runs on 6.9.2 (qt-6.11 needs
    # Qt >= 6.11 and cannot load in a Logos process today). The rev Status Desktop vendors.
    # The branches are rebased upstream — pin by commit, never by branch.
    nim-seaqt = {
      url = "github:seaqt/nim-seaqt/7d40abd7b493036b4ede5b111fc4260237504796";
      flake = false;
    };
    # nimside: the qobject: DSL (compile-time QMetaObject, the moc replacement) and the
    # plugin macros, extracted from nora-poc. Preview-grade; pinned by commit.
    nimside = {
      url = "github:seaqt/nimside/38406061afd5d24a57d8f6cb8cdcc5930bb67bc8";
      flake = false;
    };
    # logos_sdk: the lp_* binding (and later the client generated from muster.lidl), at
    # the SAME rev module/metadata.json pins, so the view and the module speak one SDK.
    logos-nim-sdk = {
      url = "github:corpetty/logos-nim-sdk/9aa82f3ddca199c4ec2c56a03ba0b60b36338ea1";
      flake = false;
    };
  };

  outputs = { self, logos-module-builder, nim-seaqt, nimside, logos-nim-sdk }:
    let
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
      seaqtApp = pkgs: pkgs.callPackage ./nix/seaqt-app.nix { inherit nim-seaqt nimside; };
      # The view contract and the QML that uses it, shared with the C++ build (ui/).
      viewContract = ../ui/src/muster_ui.rep;
      viewQml = ../ui/src/qml;
      # T4a (option B): the Logos host pieces a Nim app links, taken from the builder
      # rev above so they are the runner's own. logos-standalone-app carries
      # liblogos_core (the core's C API), logos_host (the per-module process) and the
      # design system (lib/Logos). logos-protocol-lib carries the lp_* consumer ABI the
      # modules embed.
      logosApp = system: logos-module-builder.inputs.logos-standalone-app.packages.${system}.default;
      logosProtocol = system: logos-module-builder.inputs.logos-protocol.packages.${system}.logos-protocol-lib;
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
        muster-app = let app = logosApp pkgs.system; lp = logosProtocol pkgs.system; in seaqtApp pkgs {
          pname = "muster-app";
          src = ./.;
          main = "app/muster_app.nim";
          nimFlags = [
            "-d:musterRep=${viewContract}" "-d:musterQml=${viewQml}"
            "-d:logosQmlImports=${app}/lib" "--path:${logos-nim-sdk}/src"
            "--passL:-L${app}/lib -llogos_core -Wl,-rpath,${app}/lib"
            "--passL:-L${lp}/lib -llogos_protocol -Wl,-rpath,${lp}/lib"
          ];
          extraAttrs.qtWrapperArgs = [ "--set-default" "LOGOS_HOST_PATH" "${app}/bin/logos_host" ];
        };
        default = hello;
      });

      checks = forAll (pkgs: {
        # The toolchain gate: the app builds against the runner's Qt and passes its own
        # self-test offscreen. `nix flake check` / `nix build .#checks.<system>.hello`.
        hello = pkgs.runCommand "seaqt-hello-self-test" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
          ${self.packages.${pkgs.system}.hello}/bin/seaqt-hello --self-test | tee $out
        '';
        # T4a's view half, in the sandbox: the real Main.qml loads in the Nim host and
        # binds to the contract (no core; scripts/nim-app-core-probe.sh adds muster_module).
        muster-app-view = pkgs.runCommand "muster-app-view-check" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
          ${self.packages.${pkgs.system}.muster-app}/bin/muster-app --self-test | tee $out
        '';
        # The T2 gate: repc (the pinned qtremoteobjects) generates the typed source from the
        # view contract; the nimside declaration must present QtRO the same API, index for
        # index, and every backend.<name> in the real QML must be in it.
        contract = pkgs.runCommand "muster-contract-check" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen
          ${pkgs.qt6.qtremoteobjects}/libexec/repc -o source ${viewContract} $TMPDIR/rep_source.h
          ${self.packages.${pkgs.system}.contract-test}/bin/muster-contract-test \
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
