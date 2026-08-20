# A `ui_qml` module built by the Nim-cdylib module-builder cannot load in shipping basecamp (SDK-rev skew)

**Finding, 2026-08-20.** A QML UI module (`muster-ui`) authored through
`logos-module-builder` branch `nim-cdylib-authoring` builds, packages, installs,
and *appears in the sidebar* of `logos-basecamp`, but its view **cannot be
instantiated by basecamp's `ui-host`**: the host either crashes with
`std::bad_alloc` or times out waiting for the view to become ready. Root cause is
a **version skew between the SDK revisions the Nim-cdylib builder pins and the
ones shipping basecamp uses** — specifically `logos-view-module-runtime` and
`logos-cpp-sdk`. This blocks the entire "Nim core behind a LIDL contract + QML
frontend, hosted in basecamp" path (ADR-008), so it needs an upstream fix in
`logos-module-builder` (align/advance the Nim-cdylib SDK pins + codegen to the
host's).

This document is written to stand on its own for an upstream reviewer who was
not present for the debugging. It includes exact revisions, the symptom chain,
the reproduction, and the concrete ask.

---

## TL;DR — the ask

`logos-module-builder@nim-cdylib-authoring` produces `ui_qml` module plugins that
are **not ABI-compatible with the `ui-host` in current `logos-basecamp`**,
because the builder pins older SDK revs than the host:

| SDK input | shipping basecamp | module-builder `nim-cdylib-authoring` | match? |
|---|---|---|---|
| `logos-view-module-runtime` | `1fde7d43bb2d7382045aa5da6bf442994d0cf5cf` | `3c3735c25c8d…` | ❌ |
| `logos-cpp-sdk` | `4b66dac015e4b977d33cfae80a4c8e1d518679f3` | `e3744fb84cef…` | ❌ |
| `logos-qt-sdk` | `c6be61d0ba3f…` | `c6be61d0ba3f…` | ✅ |
| `logos-protocol` | `03842db5c149…` | `03842db5c149…` | ✅ |

- Aligning **`logos-view-module-runtime`** to the host's rev **fixes the
  `std::bad_alloc` crash** during view instantiation.
- The remaining blocker is the **`logos-cpp-sdk`** skew (LogosAPI / view-glue
  ABI). But **aligning `logos-cpp-sdk` to the host's rev regresses to
  `bad_alloc`**, because the `nim-cdylib-authoring` C++ view-glue codegen is
  written against the *older* cpp-sdk and does not compile/behave correctly
  against `4b66dac0`.

**So the fix is not a one-line pin bump.** The Nim-cdylib authoring path must be
**advanced to (and validated against) the SDK revisions the shipping host
actually loads** — the codegen updated for the current `logos-cpp-sdk`, and the
builder's `logos-view-module-runtime`/`logos-cpp-sdk` pinned to (or `follows`)
the host set. Ideally the builder should not pin SDK revs independently of the
host it targets at all.

**Core (`type: core`, cdylib) modules are NOT affected** — `muster_module`
(built by the same branch, cpp-sdk `e3744fb8`) loads fine in both `logoscore`
and basecamp. The break is specific to the **`ui_qml` view path**
(`logos-view-module-runtime` + the generated C++ view-glue linked against
`logos-cpp-sdk`).

---

## Context: what was being built

Muster's P4 UI (`docs/02-implementation-plan.md`) is a `ui_qml` module,
`muster-ui`, that talks to the Muster core (`muster_module`, a Nim cdylib behind
the `muster.lidl` contract) **through the logos API** using the generated typed
client — the plan's "UI talks to the module only through the logos API; the typed
client is generated, not hand-written."

- `muster-ui`: `type: ui_qml`, `interface: universal` — a `.rep` view contract +
  a `*Backend` class, built via `logos-module-builder.lib.mkLogosQmlModule`. The
  backend calls `modules().muster_module.health()` and feeds a `.rep` PROP that
  QtRO syncs to QML.
- `muster_module`: `type: core`, cdylib, Nim behind `muster.lidl`, built via
  `logos-module-builder.lib.mkLogosModule` on the `nim-cdylib-authoring` codegen
  path (`codegen.nim`).
- Both use `logos-module-builder` at branch **`nim-cdylib-authoring`** (the
  branch that adds the Nim cdylib authoring path; not yet upstream on `main`).
- Host: `logos-basecamp`, default `app` package (dev build), run headless under
  `xvfb` + `QT_QPA_PLATFORM=offscreen` / `QT_QUICK_BACKEND=software`.
- Driver: `logos-qt-mcp` (basecamp's `tests/ui-tests.mjs` framework:
  `app.click(name)`, `app.expectTexts([...])`).

## The failure (symptom chain)

Everything up to view *instantiation* works:

1. `muster-ui` builds (`.#lgx` / `.#lgx-portable`), installs via `lgpm`, and —
   baked into basecamp's `installedDev` — **appears in the sidebar** (its icon
   renders from its metadata). So packaging + registration are fine.
2. `logos-qt-mcp` `app.click("muster_ui")` targets it. basecamp begins loading:
   ```
   App launcher clicked: "muster_ui"
   Loading UI module: "muster_ui"
   Loading core dependency for "muster_ui" : "muster_module"
   Module loaded: muster_module
   ViewModuleHost: spawning …/ui-host --name muster_ui --path …/muster_ui_plugin.so …
   ui-host [ "muster_ui" ]: "ui-host: loaded plugin \"muster_ui\" from \"…/muster_ui_plugin.so\""
   ```
   The core dependency loads and the `ui-host` **successfully dlopens the UI
   plugin**.
3. Then, depending on which SDK revs `muster-ui` was built against:
   - **Default (both view-runtime + cpp-sdk skewed):**
     ```
     ui-host [ "muster_ui" ]: "terminate called after throwing an instance of 'std::bad_alloc'"
     ui-host [ "muster_ui" ]: "what():  std::bad_alloc"
     ViewModuleHost: process exited for "muster_ui" with code 6
     ```
     Crash during view-module instantiation, *before* any backend method runs.
   - **`logos-view-module-runtime` aligned to host rev, `logos-cpp-sdk` at the
     builder's original rev:** no crash, but
     ```
     [warning] Failed to register token with capability module for: muster_module
     Failed to load UI module "muster_ui" : "Timeout waiting for ui-host for muster_ui"
     ```
     The plugin loads but the view never signals ready — the capability-token /
     LogosAPI handshake does not complete, so `onContextReady → checkHealth() →
     modules().muster_module.health()` cannot resolve.
   - **Both `logos-view-module-runtime` and `logos-cpp-sdk` aligned to host
     revs:** regresses to `std::bad_alloc` — the `nim-cdylib-authoring` view-glue
     codegen is written against the older `logos-cpp-sdk` (`e3744fb8`) and
     produces incompatible glue when built against `4b66dac0`.

## Root cause

`ui_qml` modules load across two ABI boundaries that the module and the host must
agree on:

1. **`logos-view-module-runtime`** — the `ui-host` ↔ view-plugin contract (how
   the host instantiates and drives the QML view module). A rev mismatch here
   corrupts instantiation → `std::bad_alloc`.
2. **`logos-cpp-sdk`** — the `LogosAPI` types + the generated C++ client the
   backend calls (`modules().<dep>.<method>()`) and the capability-token
   handshake. A rev mismatch here stalls the handshake → the view never becomes
   ready → host timeout.

`logos-qt-sdk` and `logos-protocol` **match** (`c6be61d0` / `03842db5`), which is
why the *core* module and everything up to view-instantiation work — the break is
narrowly the two SDKs the `ui_qml` path is most sensitive to.

The reason this cannot be fixed by simply bumping the builder's pins is that the
**codegen is coupled to the cpp-sdk it targets**: the generated C++ view-glue for
`interface: universal` is written against `logos-cpp-sdk@e3744fb8`'s API, and
does not survive a bump to `4b66dac0`. So advancing the pin requires
**advancing/validating the codegen too**.

## Reproduction

On a machine with the Nim-cdylib toolchain (see
`docs/labbook/atomic-swaps-toolchain-on-fedora.md` for the host env) and
`logos-basecamp` checked out:

1. Build `muster-ui` (`ui/`, a `mkLogosQmlModule` flake following
   `nim-cdylib-authoring`) and `muster_module` (`module/`).
2. Bake both into basecamp's `installedDev` (add them as flake inputs +
   `installDev` entries in `logos-basecamp/flake.nix`), `nix build path:<basecamp>`.
3. Drive it with `logos-qt-mcp`:
   ```bash
   nix build path:<basecamp>#logos-qt-mcp -o result-mcp
   LOGOS_QT_MCP=$PWD/result-mcp node <muster-test.mjs> --ci <basecamp>/bin/LogosBasecamp --verbose
   # muster-test.mjs: app.click("muster_ui"); app.expectTexts(["Muster — module health", "muster_module.health() → ok"])
   ```
   → `ui-host … std::bad_alloc … exited with code 6`.
4. Pin `logos-module-builder`'s `logos-view-module-runtime` to basecamp's rev
   (`1fde7d43bb2d…`), rebuild → crash becomes `Timeout waiting for ui-host`.
5. Also pin `logos-cpp-sdk` to basecamp's rev (`4b66dac0…`), rebuild →
   `std::bad_alloc` returns (codegen mismatch).

To find the host's revs: `logos-basecamp/flake.lock` (`logos-view-module-runtime`,
`logos-cpp-sdk` nodes). To find the builder's: the resolved inputs of
`module/flake.lock` after building, or `logos-module-builder@nim-cdylib-authoring`'s
`flake.nix` + lock.

## Secondary bugs found (smaller, also upstream)

These are independent of the SDK skew and were fixed with local workarounds to
get far enough to hit the skew; they are worth reporting to the module-builder
owners:

- **`nim.link` libraries are `NEEDED` but not on the `.so`'s `RUNPATH`.** The
  Nim-cdylib build links `-lsecp256k1` (from `metadata.json` `codegen.nim.link` /
  `nix.packages.runtime`), so `muster_module_plugin.so` has
  `NEEDED libsecp256k1.so.5`, but its `DT_RUNPATH` is
  `$ORIGIN:…openssl…:…qt…:…gcc-lib` — **the secp256k1 lib dir is absent**. Result:
  `Cannot load library …: libsecp256k1.so.5: cannot open shared object file`
  when a host with a scrubbed env dlopens it. `LD_LIBRARY_PATH` on the host
  process does not help (the module-loading subprocess — `logos_host`/`ui-host` —
  does not inherit it). Workaround: drop `libsecp256k1.so.5` next to the `.so`
  (`$ORIGIN` *is* in the RUNPATH). Real fix: the builder should add each
  `nim.link` library's lib dir to the `.so`'s RUNPATH (or bundle it) so
  `nix.packages.runtime` libraries are resolvable at plugin-load time.

- **dev vs portable variant-key recognition (documentation gap).** A dev basecamp
  build only recognizes modules keyed `linux-amd64-dev` in its manifest; a module
  bundled with the *portable* installer (`installPortable`) is keyed `linux-amd64`
  and is reported `Module not found in known modules`. `installDev` yields
  `linux-amd64-dev` and is recognized. This is presumably intended, but it is a
  sharp edge when baking a locally-built module into a dev host (and it interacts
  badly with the RUNPATH bug above, because `installPortable` is the variant that
  bundles the native libs but is *not* recognized by a dev host).

## What needs to change upstream (concrete)

Owner: **`logos-co/logos-module-builder`** (the `nim-cdylib-authoring` branch /
whoever lands the Nim authoring path), in coordination with **`logos-basecamp`**
(the host defining the current SDK set).

1. **Advance the Nim-cdylib authoring path's SDK pins to the shipping host's**,
   and validate the `interface: universal` C++ view-glue codegen against them:
   - `logos-cpp-sdk` → `4b66dac015e4b977d33cfae80a4c8e1d518679f3` (or newer, matching basecamp)
   - `logos-view-module-runtime` → `1fde7d43bb2d7382045aa5da6bf442994d0cf5cf` (matching basecamp)
   The codegen change is the substantive part — the `bad_alloc` on cpp-sdk
   `4b66dac0` shows the generated glue is not yet compatible with that rev.
2. **Stop pinning SDK revs in the builder independently of the target host**, or
   provide a supported way for a module to `follows`/override them to the host's
   set, so a `ui_qml` module can be built ABI-matched to the basecamp it will run
   in. (The plan's own guidance — "revalidate the stack decisions table against
   upstream HEADs at the start of every phase" — is exactly this class of drift.)
3. **RUNPATH `nim.link` libraries** (secondary bug above) so
   `nix.packages.runtime` deps load without an `$ORIGIN` hack.
4. Consider an **acceptance test in the module-builder** that builds a minimal
   `ui_qml` module and loads it in a matching basecamp/`ui-host` (the
   `logos-qt-mcp` harness already exists in basecamp `tests/ui-tests.mjs`) — this
   skew would have been caught by such a test.

## Appendix

- Muster tracking: pebble `exo-c6a` (this session's full debugging log, with the
  three fixes and the failure-mode-per-alignment matrix).
- Host/toolchain env quirks for this box: `atomic-swaps-toolchain-on-fedora.md`.
- Exact error strings and the alignment matrix are in the reproduction section
  above; all commands were run headless under `xvfb-run` + Qt software rendering
  (basecamp itself renders fine headless — this is not a display issue).
- Edits left in the working checkouts to reproduce the "best" (view-runtime
  aligned) state: `logos-basecamp/flake.nix` (muster bake-in, `installDev`) and
  `logos-module-builder/flake.nix` (`logos-view-module-runtime` pinned to
  `1fde7d43`; `logos-cpp-sdk` reverted to unpinned). Both are revertable and
  should be reverted once the upstream fix lands.
