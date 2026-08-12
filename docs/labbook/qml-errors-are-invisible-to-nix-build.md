# QML errors are invisible to `nix build`, and the failure surfaces two layers away (2026-08-11)

Cost: an afternoon, and a status report that claimed something worked when it had never run.

## What happened

Added three QML files to the `demo/muster-ui` fork (a card renderer, a wallet panel, a send dialog). `nix build .#lgx` was green. The `.lgx` contained the new files, `qmldir` listed them, the plugin `.so` had the right IID, and the main run log showed all four modules loading and `delivery is online`. Every signal I looked at said success.

The window said **"Failed to load UI plugin /nix/store/…-logos-muster_ui-plugin-dir"**.

## The actual causes

Three invalid references, any one of which aborts a component:

| Wrote | Reality |
|---|---|
| `flat: true` on `LogosButton` | No such property. It has `variant` (`LogosButton.Variant.Secondary`, …) |
| `Theme.palette.textPrimary` | The token is `Theme.palette.text` |
| `Theme.palette.danger` | The token is `Theme.palette.error` |

Also fixed pre-emptively: a JSON field named `private`, which is a reserved word in QML. Renamed to `shielded`.

The authoritative token list is in the design-system source, not in the docs:

```
<logos-design-system-src>/src/qml/Logos/Theme/*.qml      # palette / spacing / typography keys
<logos-design-system-src>/src/qml/Logos/Controls/qmldir  # which Logos* types exist
```

Extract them before writing QML rather than guessing from what looks conventional:

```bash
grep -rhoE "readonly property color [a-zA-Z]+" .../Theme/*.qml | awk '{print $4}' | sort -u
```

## Why every signal lied

1. **`nix build` does not evaluate QML.** It is copied into the bundle as data. A build that passes says nothing about whether the UI runs.
2. **The failure is reported two layers from its cause.** The plugin loaded *fine* — the `ui-host` log shows `called initLogos on plugin "muster_ui"` and the models being remoted. The QML then failed, the ui-host quit **47 ms later**, and the parent process rendered a generic "Failed to load UI plugin". The message names the plugin, which is the one thing that was not wrong.
3. **The error is in a different log than the obvious one.** Not in the app's stdout. It lives under:
   ```
   <user-dir>/module_data/chat_module/<instance-id>/chat_ui_<timestamp>.log
   ```
   The tell is `ui-host: received termination signal, quitting` arriving milliseconds after startup.

## The reasoning error worth remembering

I grepped the main log for QML errors, found none, and reported "zero QML errors". The QML had never executed. **Absence of errors in a log is not evidence of success unless you have established that success would produce a positive entry in *that* log.** The correct check was the window having content — or, failing a screen, the ui-host still being alive after startup.

## Running qmllint (this works — use it before touching QML)

```bash
cd demo/muster-ui/src/qml
QT=$(nix build nixpkgs#qt6.qtdeclarative --no-link --print-out-paths)
DS=<logos-design-system-src>/src/qml     # find with: ls -d /nix/store/*logos-design-system-src*
nix shell nixpkgs#qt6.qtdeclarative --command \
  qmllint -I "$QT/lib/qt-6/qml" -I "$DS" -I . ChatUi/YourFile.qml
```

All three `-I` paths are needed: Qt's own QML modules, the design system, and `.` so the `ChatUi` module resolves from its `qmldir`.

Known false positives to filter: `Member "mono" not found on type "Typography"` (it exists, as a string property), anything about `Logos.ChatBackend` (host-registered at runtime), and `unqualified access` on `modelData` inside delegates.

**Caveat learned the hard way: a clean qmllint does not mean the component loads.** A panel that qmllint passed with zero errors still failed at runtime with no message anywhere. qmllint catches typos and missing properties — it does not catch whatever this class of failure is. Bisecting by removing the component from its parent view is still the reliable method.

## What does *not* substitute for looking at the window (2026-08-12)

Four plausible ways to confirm a view rendered without a human looking at it. All four fail on this machine, and three fail in a way that reads as success:

- **`grim`** — `compositor doesn't support the screen capture protocol`. X11 `import -window root` captures nothing here either.
- **`QT_QPA_PLATFORM=offscreen`, and `QT_QUICK_BACKEND=software`** — the host starts, the plugin loads, the backend connects to every module and health-probes on schedule, and **the QML view is never instantiated at all**. The run's `chat_ui_*.log` holds transport lines and nothing else: zero occurrences of "qml", zero non-`DEBUG` lines. Verified identical on an unmodified `HEAD` checkout, so this is the environment rather than a regression. The real display separately throws `libEGL: failed to create dri2 screen`.
- **A `console.info` probe in `ChatView.qml`'s `Component.onCompleted`** — does not reach the run's `chat_ui` log, though `ProcessLog` handles `QtInfoMsg`. Do not build a check on it.
- **"No QML errors in the log"** — the trap this document is about, and every configuration above produces exactly that.

**So: ask the operator for a screenshot.** Twice on 2026-08-12 that was the only real evidence — first that the *baseline* rendered at all, which is what proved the log-based checks worthless rather than the change under test; then that the multi-asset wallet card rendered correctly. A screenshot also catches what no automated check would: the second one showed the per-holding blocker note landing on the right row, and prompted noticing that `Fund` could still shield into an unregistered private account.

State plainly which paths remain unverified rather than letting a green build imply they were covered.

## Prevention

`CMakeLists.txt` carries a `CHAT_UI_QML_DEVTOOLS` option that registers the QML as a real Qt module so `qmllint` and `.qmltypes` cover it. New files are now listed there. Turn it on before touching QML:

```bash
-DCHAT_UI_QML_DEVTOOLS=ON   # needs a Qt6 Qml/Quick env; point QML_IMPORT_PATH at the design system
```

The general rule for this stack: **anything resolved at runtime — QML, module names in `logos.module("…")`, event-name strings — needs the app actually launched to be verified.** Only C++ and the contracts are checked by the build.
