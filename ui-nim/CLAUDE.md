# ui-nim — muster's UI in Nim, on nim-seaqt (exo-607)

This is the port of the UI backend from C++ (`ui/src/muster_ui_backend.cpp`) to Nim, using [nim-seaqt](https://github.com/seaqt/nim-seaqt) and nimside's `qobject:` DSL. The goal is **no C++ in the repo**. Muster is also the playground where Jacek designs the seaqt DSL. The scope, the options and the slice plan are in `docs/design/seaqt-ui.md`; live status is `pb dep tree exo-607`.

## What is here

- **`flake.nix`**: the toolchain. It pins nim-seaqt `qt-6.8` and nimside by commit, and takes nixpkgs from the **same logos-module-builder rev as `ui/flake.nix`**, so it uses the very `qtbase-6.9.2` the runner links (the same store path, not merely the same version). `lib.seaqtApp` builds an app. `checks.<system>.hello` is the toolchain gate.
- **`nix/seaqt-app.nix`**: one seaqt app runs `nim c` with seaqt and nimside on the path. seaqt's `{.compile.}` pragmas build its generated C++ wrappers during that step. That C++ exists only in the build, never in the repo.
- **`hello/`**: T1. One nimside `qobject:` and one QML file, bound in both directions. `--self-test` checks that QML can call a slot with an argument, that QML can write a property through its setter, and that a Nim change reaches a QML binding.
- **`contract/`**: T2, the view contract.
  - **The macro:** `repContract(MusterUi, "<muster_ui.rep>")` generates a nimside `qobject:` at compile time from the same `.rep` the C++ build's repc reads, so the two backends cannot drift. A repc for nimside.
  - **What each SLOT becomes:** a guarded slot calling `<slot>Impl`, which is forward-declared, so a missing implementation is a compile error.
  - **What each PROP becomes:** a READONLY property with a Nim `setX`.
  - **The check** (`contract_test.nim`, `checks.contract`): compares QtRO's view of that object with repc's typed-source API, index by index; drives all 66 slots and 50 properties through QML; and resolves every `backend.<name>` in `ui/src/qml`.
  - **`--dump`** prints the generated declaration.
- **`app/`**: T4a, probe B, a standalone seaqt app.
  - **`muster_app.nim`** runs the real `ui/src/qml/Main.qml` in a Nim host. The backend is the T2 contract object, and a Nim `logos` shim provides `module()`, `isViewModuleReady()` and `viewModuleReadyChanged`.
  - **With `--modules <dir> --user-dir <dir>`** the host starts logos-core itself (`logos_core.nim`, liblogos's C API). It registers the view's token with `capability_module` and calls `muster_module` over `lp_*` (logos-nim-sdk's `ffi`). An `lp_invoke_async` result lands on the Qt main thread, so it sets a property directly.
  - **Pinning:** liblogos, `logos_host`, the design system and `logos-protocol-lib` all come through the flake's `logos-module-builder` pin.

```
cd ui-nim && nix build .#hello && QT_QPA_PLATFORM=offscreen result/bin/seaqt-hello --self-test
cd ui-nim && nix build .#checks.x86_64-linux.hello     # the same test, in the sandbox
cd ui-nim && nix run .#hello                           # a real window, on a display
cd ui-nim && nix build .#checks.x86_64-linux.contract  # T2: the contract, index for index with repc
cd ui-nim && nix run .#contract-test -- --dump         # the nimside declaration repContract generates
cd ui-nim && nix build .#checks.x86_64-linux.muster-app-view   # T4a: the real Main.qml in the Nim host (sandbox)
scripts/nim-app-core-probe.sh                          # T4a: + logos-core and muster_module.health() over lp_* (needs make build)
```

## Rules

- **The Qt must be the runner's, exactly.** seaqt compiles against Qt's private headers. It loads only on the Qt minor version it was generated for, or newer. One process cannot hold two Qt copies. Bump `logos-module-builder` here in the same change as `ui/flake.nix`. Move to seaqt `qt-6.11` only when Logos moves to Qt 6.11.
- **Pin seaqt and nimside by commit.** Their branches are rebased upstream.
- **The UI reaches muster_module only through the logos API.** This applies here too. Code sharing means the client that logos-nim-sdk generates from `muster.lidl`. It never means linking the core into the UI process.
- **Parity is judged by the self-tests.** A Nim UI build is ready when `MUSTER_UI=nim scripts/ui-parity.sh` is green, exactly as it is for `cpp`. See `scripts/lib/ui-build.sh` for the contract a build must meet.
