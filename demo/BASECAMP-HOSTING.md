# Hosting `muster_ui` inside logos-basecamp — work plan

> **Status: planning snapshot, 2026-08-17. Not yet done.** This is the output of
> a research pass into basecamp's actual source, kept so the investigation is not
> repeated. It pins specific upstream revisions (below); the platform moves faster
> than these docs, so re-check the revs at the start of the work. Where a claim
> was read straight from source it is cited `file:line`; where it is inferred or
> not yet run, it is marked **(unverified)**.

## Scope — which muster this is about

This plan is for **`demo/muster-ui`**, the speed build: the fork of
`logos-co/logos-chat-ui` v0.2.2 that runs standalone today via `make app`. It is
**not** the specified `muster-ui.lgx` (Nim core + QML), which is P4 in
[`docs/02-implementation-plan.md`](../docs/02-implementation-plan.md) and a separate
effort. Basecamp hosting for *that* is already written into the plan as a solved
platform problem; this doc is about getting the *demo* into basecamp.

## Headline

Muster is **already built as a basecamp `ui_qml` module**. The packaging, the
view↔host seam, and the capability model are each either done or free. The real
work is **its three dependency modules** — and one of them, `lez_core`, has no
installable package today. `lez_core` is the critical path; everything else is
reconciliation and verification.

---

## Already solved / inherited — do not redo

| Concern | Status | Evidence |
|---|---|---|
| `.lgx` packaging | **Done** | `cd demo/muster-ui && nix build 'path:.#lgx' --accept-flake-config` (see [`demo/Makefile`](Makefile) `build:`). Basecamp installs it via "Install LGX Package" or the catalog downloader (basecamp `docs/spec.md` §Package Installation). |
| View↔host seam | **Done (inherited from chat-ui)** | [`src/qml/ChatUi/ChatStore.qml:14-17`](muster-ui/src/qml/ChatUi/ChatStore.qml) already reads the host `logos` context property and calls `logos.module("muster_ui")` / `logos.model("muster_ui", …)` — the exact `LogosQmlBridge` API basecamp injects at `PluginLoader::finishUiQmlLoad` (sets context properties `logos` and `isActiveTab`, then `setSource(view)`). The standalone runner is a thin host over the *same* seam, not a different one. |
| Capability / permission | **Nothing to declare** | Shipping `logos-capability-module` (rev `390486e…`) is an always-grant token broker: `requestModule` mints a UUID with no policy check. A module's `capabilities` array is `qDebug()`-logged and discarded (`logos_core.cpp`), never enforced. Inter-module calls — including the dynamic invoke-by-name of `lez_core` — mint a token on first call and always succeed. |
| QML sandbox | **Clears it** | `ui_qml` views load into basecamp's process under a deny-all-network, filesystem-allowlisted, no-native-code sandbox (`QmlSandbox::configure`, basecamp `docs/spec.md` §QML App Sandboxing). muster's [`src/qml/ChatUi/qmldir`](muster-ui/src/qml/ChatUi/qmldir) declares **no** native `plugin` (clears the F-008 sandbox-escape rejection); clipboard is a pure-QML hidden `TextEdit` ([`ClipboardProxy.qml`](muster-ui/src/qml/ChatUi/ClipboardProxy.qml)); the only filesystem touch is a cosmetic `Settings{ memberAddExplained }` bool ([`ChatView.qml:551`](muster-ui/src/qml/ChatView.qml)). All real network/fs work is in the out-of-process backend — the correct side of the boundary. |
| Dependency auto-load | **Mechanism exists** | Loading a `ui_qml` app auto-loads its declared Logos Module dependencies first via `logos_core_load_module_with_dependencies()` (basecamp `docs/spec.md`). The `dependencies` array drives load order (only — it is not a call-permission grant). |

**Consequence worth carrying forward:** capability scoping is *aspirational in the
host today*. Muster's own FS-5 / F-12 capability story (no network, no key APIs,
no storage outside declared scopes) cannot lean on the platform yet — the platform
grants everything. That is a note for the real client, not a blocker for the demo.

---

## The work, ranked by risk

### 1. Dependency packaging & the `lez_core` name mismatch — biggest, partly novel

Basecamp bundles **only** infra modules (`package_manager`, `package_downloader`,
`capability`, `view-module-runtime`, `design-system`, plus `main_ui` /
`package_manager_ui`). Muster's three deps are not among them and must each be
installed as `.lgx` into the user modules dir.

- **`chat_module` / `delivery_module`** — logos-co modules with an `.lgx` path, so
  obtainable. Caveat: chat-ui's own "In Basecamp" README installs *only its own*
  `.lgx`, never these deps, and no CI exercises it. Producing/staging their `.lgx`
  is on us. **(the exact build target for their `.lgx` is unverified)**
- **`lez_core` — blocker.** Its flake
  (`logos-blockchain/logos-execution-zone-module`) outputs only `packages.lib` /
  `packages.default` (a raw core `.so`/`.dylib`) and an `inspectModule` app. **No
  `.lgx`, no `install-portable`, no bundler output.** Making it installable is
  genuine upstream work: give the module an `.lgx`/portable output it currently
  lacks.
- **Confirmed naming bug.** Muster declares `dependencies: ["lez_core"]`
  ([`metadata.json:12`](muster-ui/metadata.json)), but that module's manifest
  `name` is **`liblogos_execution_zone_wallet_module`** (verified in the resolved
  module's `metadata.json`). Standalone works only because the *flake input* is
  aliased `lez_core`. Basecamp resolves dependencies **and routes inter-module
  calls by manifest name**, so under basecamp both the dependency load and every
  `modules().lez_core.*` call (`ChatBackendWallet.cpp`, `ChatBackendAssets.cpp`)
  would fail to resolve. **Fix required:** reconcile the name — either rename the
  dependency to the real manifest name and regenerate the typed wrapper, or
  repackage/rename the module as `lez_core`.

### 2. Design-system version binding — silent-failure risk

The host resolves `import Logos.Theme` / `Logos.Controls` / `Logos.Icons`
**exclusively** from basecamp's own pinned design-system copy
(rev `94092b0…`), on disk at `appLibDir/Logos/<mod>`, allowlisted in
`SharedLogosModules.h` (`{Theme, Controls, Icons}`). `RestrictedUrlInterceptor`
actively redirects the module's *own* copy away, so a module cannot shadow it.
All types are declared at version `1.0` with **no semver negotiation**.

Risk: muster is built/tested against whatever design-system its own flake pins. A
renamed or removed token/control property binds silently to basecamp's version and
surfaces as a QML *runtime* error or visual drift — i.e. the invisible "Failed to
load UI plugin" with nothing in the log (see
[`docs/labbook/qml-errors-are-invisible-to-nix-build.md`](../docs/labbook/qml-errors-are-invisible-to-nix-build.md)).

**Work:** align muster's design-system pin to basecamp's, then launch and eyeball;
a green build proves nothing here.

**Also verify (unverified):** basecamp's runtime actually lays `Logos/{Theme,
Controls,Icons}` on disk under `applicationDirPath/../lib`. Its `nix/app.nix`
comments suggest the design system is static-linked into `main_ui` via qrc
("Nothing to copy to `$out/lib/Logos`"), yet the sandbox for *hosted* ui_qml
modules resolves `Logos.*` from on-disk `appLibDir`. If the on-disk copy is absent
in the AppImage/dir bundle, hosted modules' `Logos.*` imports fail. Confirm against
an unpacked bundle.

### 3. Backend out-of-process packaging completeness

In basecamp the `main` backend does **not** run in-process. `PluginLoader` spawns
a `ViewModuleHost` child (`ui-host` binary), which loads the backend `.so`, calls
`initLogos(LogosAPI*)`, and publishes it over a private QtRO local socket. For
*typed* remoting the host looks for a **`muster_ui_replica_factory.{so,dylib}`**
next to the backend; the view reaches it via `logos.module("muster_ui")`.

**Work / verify (unverified):** confirm `mkLogosQmlModule` emits that replica
factory and that the `.lgx` bundles backend `.so` + factory + the QML view. This
is a packaging-completeness check, not new code — but if the factory is missing,
the view falls back to dynamic (untyped) remoting and the typed `ChatBackend`
enums/properties the QML relies on (`ChatBackend.Online`, `walletStatus`, etc.)
may not resolve.

### 4. Data directory / identity / lifecycle

- **Directory model.** Standalone is "one peer = one `--user-dir`," with the
  wallet living *inside* the chat instance dir (`ChatBackend::walletDir`).
  Basecamp manages its own user profile under `module_data/<module>/`. Confirm
  `walletDir` resolves correctly under basecamp's layout. Multi-peer testing
  becomes two `--user-dir`-isolated basecamp instances (basecamp supports
  `--user-dir`; FURPS Physical assumes it).
- **Lifecycle / shutdown.** The wallet is in-memory and persists **only** because
  the backend destructor calls `chat_module.shutdown()` — the [`Makefile`](Makefile)
  `stop:` target exists precisely because a hard kill loses a real payment receipt.
  Under basecamp the backend is a separate `ui-host` process; confirm basecamp's
  unload/quit sends it a **graceful terminate**, not a kill, or wallet state is
  lost on every quit. **(unverified)**

### 5. You are on the thin edge of what's exercised

The "install a `ui_qml` module **plus its non-infra dependency modules**" path is
documented but **only exercised with synthetic test modules** — the
`basecamp-fullapi-ui-qml` doctest manually `install-portable`-stages a test plugin
+ test provider under a `--user-dir` (no catalog, no network). chat-ui's own
basecamp path is README-documented but **never CI-exercised**; the one
end-to-end catalog example (`basecamp-crossversion-accounts`) is `.disabled`.
Muster pushes further still (three real deps, one unpackaged). **Budget debugging
time for being first down this path**, not just wiring time.

---

## Recommended sequencing

Mirror the one exercised precedent (the `basecamp-fullapi-ui-qml` staging model)
before spending effort on the expensive part:

1. **Cheap flush-out.** Build muster's `.lgx`; stage `chat_module` /
   `delivery_module` `.lgx` by hand into a `--user-dir` basecamp's modules dir;
   fix the `lez_core` manifest-name so the dependency resolves; try to **load**
   muster with lez_core temporarily stubbed or absent. This surfaces items 2–4 as
   real errors in an afternoon and tells you whether the module even mounts.
2. **Decide on `lez_core`.** Only once the module loads, invest in giving
   `logos-execution-zone-module` an `.lgx` output (item 1's blocker). This is the
   true critical-path item and the most likely to need upstream coordination.
3. **Verify the deferred items** (2–4 "unverified" marks) against a real running
   basecamp, and capture anything that bit us in
   [`docs/labbook/`](../docs/labbook/).

## Open questions to resolve during the work

- [ ] Exact build targets for `chat_module` / `delivery_module` `.lgx`, and whether
      basecamp's catalog already carries them (avoids hand-staging).
- [ ] Does `mkLogosQmlModule` emit `muster_ui_replica_factory.*` into the `.lgx`?
- [ ] Is `Logos/{Theme,Controls,Icons}` present on disk under `appLibDir` in the
      shipped bundle, or only qrc-embedded in `main_ui`?
- [ ] Does basecamp terminate the `ui-host` backend gracefully on unload/quit?
- [ ] `lez_core` packaging: rename the module to `lez_core`, or rename muster's
      dependency + regenerate the wrapper? (The latter keeps the upstream module
      untouched.)

## Evidence appendix — source locations & pinned revs

Read against these; re-check before starting since upstream moves.

- **basecamp:** `~/Github/logos-co/logos-basecamp` @ `a231f50`. Authoritative host
  docs: `docs/spec.md`, `docs/project.md`. Host seam: `src/UIPluginManager.cpp`,
  `src/PluginLoader.cpp`, `src/restricted/{QmlSandbox,RestrictedUrlInterceptor}.cpp`,
  `src/restricted/SharedLogosModules.h`. Bundled module set: `flake.nix`
  (`installedDev`).
- **logos-view-module-runtime:** rev `3c3735c25c8d66cc713623420dc74e445442592a`.
  `include/LogosQmlBridge.h` (the `logos` context object API: `callModule`,
  `callModuleAsync`, `module`, `model`, `watch`, `onModuleEvent`), `ui-host/main.cpp`
  (out-of-process backend host).
- **logos-design-system:** rev `94092b07d66df91ffdabb14495a1c90d6116b1b2`. Installs
  `lib/Logos/{Theme,Controls,Icons}/` each with a `qmldir` at version `1.0`.
- **logos-capability-module:** rev `390486e225dcbf7e95072808f3130a35e4a694c6`.
  `requestModule` always grants; own docs: "Current implementation always grants
  requests; future versions may enforce capability/permission policies."
- **package manager C API:** `lgpm.h` / `lgx.h` (embedded vs user module/plugin
  dirs; `lgpm_install_file`, `lgpm_scan_installed`).
- **muster:** [`demo/muster-ui/metadata.json`](muster-ui/metadata.json),
  [`demo/muster-ui/flake.nix`](muster-ui/flake.nix),
  [`demo/muster-ui/src/qml/ChatUi/ChatStore.qml`](muster-ui/src/qml/ChatUi/ChatStore.qml).
- **lez_core:** consumed as flake input `github:logos-blockchain/logos-execution-zone-module`;
  local mirror `~/Github/logos-co/logos-workspace/repos/logos-modules/logos-execution-zone-module`
  (manifest name `liblogos_execution_zone_wallet_module`, `type: core`, no `.lgx`
  output).
- **Exercised precedent:** `logos-basecamp/doctests/basecamp-fullapi-ui-qml.test.yaml`
  (ui_qml + provider, manual staging). Documented-but-not-CI: chat-ui `README.md`
  "In Basecamp". Disabled catalog example:
  `logos-basecamp/doctests/basecamp-crossversion-accounts.test.yaml.disabled`.
</content>
</invoke>
