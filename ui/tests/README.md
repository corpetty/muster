# ui/tests — Muster UI acceptance harness (P4)

`muster-ui-test.mjs` drives `muster-ui` inside a **logos-basecamp** host via
[logos-qt-mcp](https://github.com/logos-co/logos-qt-mcp), headless (offscreen),
and asserts the real lifecycle surfaces:

1. **render** — the view instantiates in the ui-host (the `exo-c6a` blocker; ADR-013),
2. **health** — `muster_module.health()` marshals back to `"ok"`,
3. **propose** — the module re-derives the EIP-712 `safeTxHash` and the
   re-materialization strip shows it (F-4 / invariant 1 — the real check, not the
   prototype's simulated hashes).

It writes a screenshot to `$MUSTER_SHOT` (default `./muster-ui.png`).

Status: **3/3 green** as of 2026-08-21 (ADR-013). See `docs/02-implementation-plan.md`
ADR-013 and pebble `exo-193` for the full story.

## Why basecamp (not the standalone runner)

`logos-standalone-app` renders no `ui_qml` view on the current stack; `logos-basecamp`
is the working host. Per **ADR-013**, `muster-ui` must be built on a **basecamp-coherent**
`logos-module-builder` (its `ui/flake.nix` pins basecamp's builder rev) so the
generated `muster_module` client + QtRO view-glue ABI-match basecamp's ui-host.

## Producing the app-under-test

The harness takes any basecamp binary that has `muster_module` + `muster_ui` baked
in. Today that means a **local** logos-basecamp dev build (the bake-in edits are not
committed to the upstream basecamp repo). Two supporting fixes are required until they
land upstream (both tracked in ADR-013 / `exo-193`):

- **Builder RUNPATH fix** (`logos-module-builder`): the Nim `codegen.nim.link` libs
  (secp256k1) need their lib dir in the plugin RUNPATH. Fixes non-bundled hosts.
- **basecamp co-location**: basecamp's `app.nix` strips external module RUNPATH
  entries and logos-core unsets `LD_LIBRARY_PATH`, so `libsecp256k1.so.5` must be
  co-located in the module dir (`$ORIGIN`).

### 1. Bake muster into a local logos-basecamp checkout

In `logos-basecamp/flake.nix`, add the two inputs:

```nix
muster_module.url = "path:/ABS/PATH/TO/muster/module";
muster_ui.url     = "path:/ABS/PATH/TO/muster/ui";
```

add them to the `outputs = { ... }` argument set, bind their installs in the
`forAllSystems` let (co-locating secp for the basecamp case):

```nix
musterUiInstall     = muster_ui.packages.${system}.install;
musterModuleInstall = (import nixpkgs { inherit system; }).runCommand "muster-module-install-secp" {} ''
  cp -r --no-preserve=mode ${muster_module.packages.${system}.install} $out
  cp -L ${(import nixpkgs { inherit system; }).secp256k1}/lib/libsecp256k1.so.5 $out/modules/muster_module/
'';
```

add `musterModuleInstall, musterUiInstall` to the `packages = forAllSystems ({ … })`
argument set, and append them to the dev app's module set:

```nix
musterInstalls = [ musterModuleInstall musterUiInstall ];
# …
app = import ./nix/app.nix { …; installedModules = installedDev ++ musterInstalls; };
```

> Bake in muster's **own** `.install` outputs (as above), not `installDev` over
> `.lib` — basecamp's `installDev` re-bundle of `.lib` fails with
> `qml/Main.qml not found` (a bundler-version skew); the standalone install is
> self-consistent.

### 2. Build everything

```bash
LOGOS_CACHE="--extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU= \
  --accept-flake-config"

# the app-under-test (muster baked in) and the qt-mcp framework
nix build /PATH/TO/logos-basecamp#app          --out-link result-app  $LOGOS_CACHE
nix build /PATH/TO/logos-basecamp#logos-qt-mcp --out-link result-mcp  $LOGOS_CACHE
```

### 3. Run the harness

```bash
LOGOS_QT_MCP="$PWD/result-mcp" \
MUSTER_SHOT="$PWD/muster-ui.png" \
  node ui/tests/muster-ui-test.mjs --ci "$PWD/result-app/bin/LogosBasecamp"
```

Expected: `3 passed, 0 failed`, and `muster-ui.png` showing the Muster view — the
Safe account from `describe()`, the proposed intent, the green re-materialization
strip with the re-derived `safeTxHash`, and `module.health() → ok`.

## Extending

Add a `test("muster_ui: …", async (app) => { … })` block. Useful primitives on
`app`: `click(text)`, `expectTexts([…])` (exact match), `waitFor(fn, opts)`,
`screenshot()`, and `inspector.send("findByProperty" | "setProperty" | "callMethod"
| "evaluate", …)`. Find controls by `objectName` (the composer fields are
`proposeTo` / `proposeValue` / `proposeNonce` / `proposeButton`).
