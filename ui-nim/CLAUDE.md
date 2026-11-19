# ui-nim — muster's UI in Nim, on nim-seaqt (exo-607)

This is the port of the UI backend from C++ (`ui/src/muster_ui_backend.cpp`) to Nim, using [nim-seaqt](https://github.com/seaqt/nim-seaqt) and nimside's `qobject:` DSL. The goal is **no C++ in the repo**. Muster is also the playground where Jacek designs the seaqt DSL. The scope, the options and the slice plan are in `docs/design/seaqt-ui.md`; live status is `pb dep tree exo-607`.

## What is here

- **`flake.nix`**: the toolchain. It pins nim-seaqt `qt-6.11` and nimside by commit, on nixos-unstable's Qt 6.11.2 (T1b). It also builds `logos-core` and `logos-protocol-lib`, the two Logos libraries the app loads in-process, on that Qt from the runner's revisions. `lib.seaqtApp` builds an app. `checks.<system>.hello` is the toolchain gate.
- **`nix/nixpkgs-app/`**: the nixpkgs the Logos tree builds on, nixos-unstable plus the overrides it needs (GCC 14, Boost 1.87, `<cstring>`), applied without rebuilding Qt.
- **`nix/seaqt-app.nix`**: one seaqt app runs `nim c` with seaqt and nimside on the path. seaqt's `{.compile.}` pragmas build its generated C++ wrappers during that step. That C++ exists only in the build, never in the repo.
- **`hello/`**: T1. One nimside `qobject:` and one QML file, bound in both directions. `--self-test` checks that QML can call a slot with an argument, that QML can write a property through its setter, and that a Nim change reaches a QML binding.
- **`contract/`**: T2, the view contract.
  - **The macro:** `repContract(MusterUi, "<muster_ui.rep>")` generates a nimside `qobject:` at compile time from the same `.rep` the C++ build's repc reads, so the two backends cannot drift. A repc for nimside.
  - **What each SLOT becomes:** a guarded slot calling `<slot>Impl`, which is forward-declared, so a missing implementation is a compile error.
  - **What each PROP becomes:** a READONLY property with a Nim `setX`.
  - **The check** (`contract_test.nim`, `checks.contract`): compares QtRO's view of that object with repc's typed-source API, index by index; drives all 66 slots and 50 properties through QML; and resolves every `backend.<name>` in `ui/src/qml`.
  - **`--dump`** prints the generated declaration.
- **`nix/seaqt-ro.nix`, `nix/seaqt-gen-patches/` and `ro/`**: T3.
  - **What it is:** nim-seaqt plus QtRemoteObjects, **generated at build time** by the pinned seaqt-gen with four patches, and clang 14 from a pinned nixos-24.05.
  - **Why build time:** the generated wrappers are C++, so they are never committed. Only the patches are.
  - **The proof:** `ro/ro_test.nim` (`checks.ro`) remotes a nimside source and drives a dynamic replica both ways.
  - **To use it:** an app passes `seaqt = seaqtRO pkgs` to `seaqtApp`.
- **`app/`**: the standalone app (option B, ADR-019).
  - **`muster_app.nim`**: the host. It runs the real `ui/src/qml/Main.qml`, with a Nim `logos` shim providing `module()`, `isViewModuleReady()` and `viewModuleReadyChanged`. With `--modules <dir>` it starts logos-core itself, as logos-standalone-app does (`--user-dir` / `LOGOS_USER_DIR`, `capability_module`, then `ui/metadata.json`'s dependencies), registers the view's token with `capability_module`, and runs the backend's startup.
  - **`backend.nim`**: every SLOT of the contract and the `MUSTER_AUTO*` autopilot (T5), slot for slot with `ui/src/muster_ui_backend.cpp`. It calls `muster_module` only through `mm.<method>Async`, the async twin of the client generated from `muster.lidl`, so the view never blocks. Included into `muster_app.nim`, because nimside wants each Impl in the module that declares the contract.
  - **`sched.nim`**: `after` / `every` / `barrier` on one QTimer.
- **`headless/`**: the headless host (T7), logos-core and a module driven from stdin; see its README. It shares `app/logos_core.nim`'s `startCore` with the app.
- **`tests/autovoice/`**: the voice autopilot's decisions (voice notes' S9) with no Qt and no runner, so it runs on a Mac too. `gen.py` makes a harness that includes `app/backend.nim` whole, against stubs generated from the `.rep` and `muster.lidl` (as `contract/` and the SDK's client are) and `fake_module.nim`, a fake `muster_module` with the voice state machine; `run.sh` builds it with the nim on PATH, else this flake's nixpkgs pin's, and checks the recorder's and the player's calls. A fake stands in for the module only, the process boundary; the backend is the real file.
- **`nix/muster-client.nix`**: the typed `muster_module` client, generated at build time from `module/src/api/muster.lidl` by the pinned SDK's `lidl-gen`. Never committed.
- **The runner**: `scripts/build-runner-nim.sh` (`make build-nim`) writes `.run/runner-nim/bin/muster-ui`, the app on the C++ runner's modules. `MUSTER_UI=nim` selects it in the self-tests and in `make run` / `run-fleet`.

```
cd ui-nim && nix build .#hello && QT_QPA_PLATFORM=offscreen result/bin/seaqt-hello --self-test
cd ui-nim && nix build .#checks.x86_64-linux.hello     # the same test, in the sandbox
cd ui-nim && nix run .#hello                           # a real window, on a display
cd ui-nim && nix build .#checks.x86_64-linux.contract  # T2: the contract, index for index with repc
cd ui-nim && nix run .#contract-test -- --dump         # the nimside declaration repContract generates
cd ui-nim && nix build .#checks.x86_64-linux.ro             # T3: QtRemoteObjects from Nim (bindings generated in the build)
cd ui-nim && nix build .#checks.x86_64-linux.muster-app-view   # T4a: the real Main.qml in the Nim host (sandbox)
cd ui-nim && nix build .#logos-core .#logos-protocol-lib     # T1b: the in-process Logos libraries, on the app's Qt
scripts/nim-app-core-probe.sh                          # T4a: + logos-core and muster_module.health() over lp_* (needs make build)
scripts/build-runner-nim.sh                            # T6: .run/runner-nim (needs make build: it uses the C++ runner's modules)
scripts/nim-headless-probe.sh                          # T7: the headless host drives muster_module from stdin (needs make build)
MUSTER_UI=nim scripts/ui-parity.sh                     # the parity oracle: every offscreen self-test on the Nim build
ui-nim/tests/autovoice/run.sh                          # the voice autopilot against a fake module, no Qt (any host; [<dir>/backend.nim] for another backend)
```

## Rules

- **One Qt per process.** seaqt compiles against Qt's private headers. It loads only on the Qt minor version it was generated for, or newer. One process cannot hold two Qt copies. Since T1b (ADR-019, "newest everything") the app has its own Qt, nixos-unstable's 6.11.2. Every library the app loads in-process is built here on that Qt, never taken from the builder's closure: `liblogos_core` and `liblogos_protocol`, through `nix/nixpkgs-app` (see its CLAUDE.md). The module processes keep Logos's Qt 6.9.2. Bump `logos-module-builder` here in the same change as `ui/flake.nix`, and move the `logos-liblogos` / `logos-protocol` pins with the runner's.
- **The app is standalone** (ADR-019, option B). Write it as if Basecamp did not exist. The C++ Basecamp UI in `ui/` is frozen. It gets no feature of its own, but the QML and the `.rep` are shared, so a slot added to the contract is implemented in both backends. The compile fails on either side until it is.
- **Pin seaqt and nimside by commit.** Their branches are rebased upstream.
- **The UI reaches muster_module only through the logos API.** This applies here too. Code sharing means the client that logos-nim-sdk generates from `muster.lidl`. It never means linking the core into the UI process.
- **Parity is judged by the self-tests.** A Nim UI build is ready when `MUSTER_UI=nim scripts/ui-parity.sh` is green, exactly as it is for `cpp` (11/11 on both, 2026-10-14). See `scripts/lib/ui-build.sh` for the contract a build must meet.
- **Never block the main thread.** Every module call is an `…Async` twin; the next step goes in its continuation. A sync call here would freeze the view, which the C++ backend in `ui-host` never could.
