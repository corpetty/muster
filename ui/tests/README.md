# ui/tests — P4 UI acceptance

Headless acceptance for the muster-ui view. `run-health.sh` launches the module
in the module-builder's own standalone host and `health.mjs` asserts, over the
QML inspector protocol, that the full seam resolves:

> QML view → C++ backend → generated `modules().muster_module` client → Nim core
> → `.rep` PROP → QML, surfacing **`muster_module.health() → ok`**.

```bash
ui/tests/run-health.sh          # offscreen + software render; no display needed
MUSTER_UI_PLATFORM=xcb ui/tests/run-health.sh   # watch it on a real display
```

Exit 0 = PASS. On failure the app log is dumped inline.

## Why the standalone host, not basecamp

This is the standalone-host analogue of basecamp's `logos-qt-mcp`
`app.click(...)` / `app.expectTexts(...)` flow. Shipping basecamp's `ui-host` is
ABI-skewed from the `nim-cdylib-authoring` module-builder
(`logos-view-module-runtime` + `logos-cpp-sdk`), so the muster-ui view crashes on
instantiation there — see
[`docs/labbook/nim-cdylib-modules-cannot-load-in-basecamp-sdk-skew.md`](../../docs/labbook/nim-cdylib-modules-cannot-load-in-basecamp-sdk-skew.md).

`logos-standalone-app` bundles its **own** `ui-host` + `capability_module`, built
from the **same** builder as the plugin, so both ABI boundaries are
self-consistent and the capability-token handshake + `health()` call complete.
When the upstream skew is fixed, re-point this at basecamp — **`health.mjs` is
unchanged**; only the launcher (`run-health.sh`) swaps hosts.

## Why it works headless

The assertion reads the QML **object tree** (`root.ready`, `root.health`) via the
inspector, not rendered pixels — so it passes under `QT_QPA_PLATFORM=offscreen`
with no display. (`exo-c6a`'s earlier "standalone renders nothing headless" was a
logging-capture artifact: the `ui-host` / `health()` lines need
`QT_FORCE_STDERR_LOGGING=1` to reach stderr, and the offscreen framebuffer is
blank by construction. The handshake completes headless regardless; the
`QObject::connect: No such signal …eventResponse` warnings are cosmetic.)

## Inspector expressions (verified)

All resolve in the loaded view's root scope:

| expression | value |
|---|---|
| `logos.isViewModuleReady('muster_ui')` | `true` |
| `root.ready` | `true` |
| `root.health` | `"ok"` |
| `root.backend.checkHealth()` | invokes the "Re-check health" SLOT |
