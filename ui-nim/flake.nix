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
  };

  outputs = { self, logos-module-builder, nim-seaqt, nimside }:
    let
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
      seaqtApp = pkgs: pkgs.callPackage ./nix/seaqt-app.nix { inherit nim-seaqt nimside; };
    in {
      # A builder for seaqt apps, for the later slices (T2 onward): seaqtApp pkgs { pname; src; main; }
      lib.seaqtApp = seaqtApp;

      packages = forAll (pkgs: rec {
        # T1: one QML file, one nimside qobject:, bound both ways. `--self-test` asserts it.
        hello = seaqtApp pkgs { pname = "seaqt-hello"; src = ./hello; main = "hello.nim"; qml = [ "hello.qml" ]; };
        default = hello;
      });

      checks = forAll (pkgs: {
        # The toolchain gate: the app builds against the runner's Qt and passes its own
        # self-test offscreen. `nix flake check` / `nix build .#checks.<system>.hello`.
        hello = pkgs.runCommand "seaqt-hello-self-test" { } ''
          export HOME=$TMPDIR QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
          ${self.packages.${pkgs.system}.hello}/bin/seaqt-hello --self-test | tee $out
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
