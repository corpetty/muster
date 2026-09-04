# The basecamp bake blanks the view: an SDK-rev skew, not a QML bug

**Date:** 2026-09-03. **Pebble:** exo-222 (blocks exo-4be / the exo-891 verify-box harness). **Related:** exo-193, exo-c6a (the original ADR-013 SDK skew).

## Symptom

Building the P4 render bake against **current** `muster_ui` (the full product surface — `Home`/`Room`/`Composer`/`MusterCard`/…) and running `ui/tests/muster-ui-test.mjs` offscreen: **all 9 tests fail**. The Muster sidebar launcher is found and clicked, but no content renders — not even the nav bar (`walkthroughToggle`, `roomToggle` "not found", `"Propose a transfer"` never appears).

This *looks* like a QML error (a bad import/type in one of the new `.qml` files — the ADR-011 "nix build doesn't evaluate QML" trap). **It is not.**

## Root cause

Run the harness with `--verbose` (surfaces the app's `[app:out]` stream). The real error:

```
[error] [muster_module] Failed to load plugin: muster_module_plugin.so:
        undefined symbol: logos_module_set_unload_done_callback
[critical] Module process crashed: muster_module
```

`muster_module` **crashes on load**, so the ui-host's `health()`/`describe()` calls never resolve and the view never comes up. Confirm with `nm -D`:

```
muster_module_plugin.so:            U logos_module_set_unload_done_callback   # imports it
package_manager_plugin.so:          T logos_module_set_unload_done_callback   # DEFINES it
package_downloader_plugin.so:       T logos_module_set_unload_done_callback   # DEFINES it
```

basecamp's **own** modules *define/export* the symbol; muster's plugin *imports* it as a host symbol. The host (built from basecamp's SDK) does not export it → undefined symbol → crash.

It is an **SDK-generation skew**, inherent to current muster (reproduced with clean natural nix resolution — not a `follows` artifact):

| | logos-cpp-sdk | contract |
|---|---|---|
| muster's builders (`logos-co/…@4717b9af` ui, `corpetty/…@720ac2f` module) | `58c65737` | module **imports** `logos_module_set_unload_done_callback` from the host |
| basecamp's host + own modules | `8554ecd7` | module **defines/exports** it |

## Why it worked before, and why now

The last green bake (6/6 lifecycle) used `muster_ui@55540084` — the **minimal lifecycle-spike UI** (no room nav; that's why its "roomToggle" tests failed too). Its `muster_module` build resolved a cpp-sdk that then matched basecamp's host. Since then upstream `logos-cpp-sdk` advanced (`58c65737`, 2026-09-01) and basecamp advanced its host to `8554ecd7`, and the two contracts diverged. The current full UI never even gets to render — the module dies first.

## What does NOT fix it

`follows`-pinning muster's builder `logos-cpp-sdk` (± `qt-sdk`, `view-module-runtime`) to basecamp's top-level SDK inputs fixes the *runtime* contract but **breaks the build**:

```
logos-qt-sdk not found at …   (muster_ui-module-lib cmake)
```

The two SDK generations are mutually incompatible in layout, so no combination of flake `follows` satisfies both build and runtime. (Toolchain follows — `rust-overlay`/`nixpkgs` — are a red herring here; they change nothing about this symbol.)

## The fix direction (not yet done)

Bump muster's **builder pins** to a `logos-module-builder` rev whose `logos-cpp-sdk` generation matches basecamp's current host (`8554ecd7`-era):

- `module/flake.nix`  → `logos-module-builder` (currently `corpetty/720ac2f`)
- `ui/flake.nix`      → `logos-module-builder` (currently `logos-co/4717b9af`)

Then re-verify: (1) muster still builds (the SDK bump may cascade into the Nim/C++ glue and the generated client), and (2) `nm -D muster_module_plugin.so` shows the symbol **defined (T)**, like basecamp's own modules. Alternatively, pin basecamp's host down to muster's SDK generation. Either way it is a coherence *re-alignment*, the same move ADR-013 made originally — the pins have simply drifted apart again as upstream moved.

## ✅ RESOLVED (2026-09-04)

Fixed by realigning muster_module's builder generation, not by follows. The fork
`720ac2f` = basecamp's builder base `logos-co/4717b9af` + **78 commits**, which mix
the codegen work muster needs (`65c3b58` #202 codegen, `165839f` codegen.packages,
`720ac2f` RUNPATH — all touching only `cmake/LogosModule.cmake` + `lib/mkLogosModule.nix`)
with **SDK-bump chores** (`12cbe94` cpp-sdk→58c6573, `9e13ae8` protocol 0.9, …) that
pushed the load contract newer.

The fix (a builder branch `codegen-on-basecamp`): cherry-pick **only** the three
codegen commits onto `4717b9af`, none of the SDK bumps — they apply clean (disjoint
files). Then in muster's `module/flake.nix`, point the builder at that branch and
**pin its floated SDK inputs** to basecamp's coherent generation (cpp-sdk `c3fa1b5a`,
qt-sdk `2ec59459`, module `2ec64c4a`, protocol `6401e30a`, plugin-qt `f33f264a`,
rust-overlay `14f58845`, …). Now muster_module builds the same contract the host
loads: `nm -D muster_module_plugin.so` no longer lists the symbol as an undefined
import, the module loads in the bake, and the full `muster_ui` view renders.

Dead ends confirmed along the way: (a) pinning muster's SDKs DOWN while keeping the
fork builder `720ac2f` fails the build — the fork needs the *newer* `logos-plugin-qt`
(`logos-qt-host` attribute), absent in basecamp's older one; (b) toolchain follows
(`rust-overlay`/`nixpkgs`) change nothing about the symbol. The generation is a matched
set: builder logic ↔ SDK API ↔ host contract must all agree.

**Harness result on the coherent bake: 8/9 green** — render, health, room render,
the verify box on-display (re-derived safeTxHash bound to chain+Safe), propose strip,
lifecycle, reject+reset, walkthrough. Only `submit` fails, and only for want of a live
anvil (independently covered by `safe_anvil_e2e` / `coordinate_submit_anvil`).

**One follow-up before this leaves the machine:** `module/flake.nix` points the builder
at a LOCAL `git+file://…?ref=codegen-on-basecamp`. Push `codegen-on-basecamp` to
`corpetty/logos-module-builder` and repin to a github ref so a fresh clone builds.

## Independent of this: delivery bundling works (exo-050)

`delivery_module@v0.2.0` bundles into the bake cleanly (`modules/delivery_module/{delivery_module_plugin.so,liblogosdelivery.so}`) and the ui-host connects to its registry (`RemoteTransportConnection: Successfully connected to registry logos_delivery_module`). That part of the exo-891 plan is done; only the SDK re-alignment stands between here and a green in-room verify-box render (exo-4be).
