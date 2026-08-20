# ui/tests — P4 UI acceptance (agent context)

Headless acceptance for the muster-ui view, driven against the module-builder's
own ABI-matched host (`logos-standalone-app`), **not basecamp** — shipping
basecamp's `ui-host` is SDK-skewed from the nim-cdylib builder (see
`docs/labbook/nim-cdylib-modules-cannot-load-in-basecamp-sdk-skew.md`).

## Run

```
ui/tests/run-health.sh                          # offscreen + software; no display
MUSTER_UI_PLATFORM=xcb ui/tests/run-health.sh   # watch it on a real display
```

Exit 0 = PASS. Asserts `muster_module.health() -> ok` surfaces in the view.

## How it works

- `run-health.sh` launches the standalone host with a `QML_INSPECTOR_PORT`, waits
  for the inspector, runs `health.mjs`, and tears down **only** the processes it
  started (pre/post pid-set diff — never touches a pre-existing instance).
- `health.mjs` speaks the QML inspector protocol (newline-delimited JSON over TCP,
  the same one `demo/muster-ui/doctests` use) and asserts on the QML **object
  tree** (`root.ready`, `root.health`), not pixels.

## Invariants for anyone editing here

- **Assert on the object tree, never on a screenshot** — keep it display-free so it
  passes headless (the offscreen framebuffer is blank by construction).
- **Drive the standalone host, not basecamp**, until the `ui-host` SDK skew is
  fixed upstream — then re-point `run-health.sh`; `health.mjs` is unchanged
  (tracked in `exo-c6a`).
- **`QT_FORCE_STDERR_LOGGING=1` is mandatory** to see `ui-host` / `health()` lines;
  without it a *working* run looks silent — this misdiagnosis is what `exo-c6a`
  originally recorded.
- **Commit new QML files.** The flake build excludes untracked files, so a new
  sibling of `Main.qml` (e.g. `Theme.qml`) can be green under hot-reload
  (`DEV_QML_PATH`) while the packaged module is broken. Verify against the built
  module with `LOGOS_QML_HOT_RELOAD=0`.
