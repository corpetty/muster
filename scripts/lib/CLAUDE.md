# scripts/lib — shell helpers the self-tests source

`ui-build.sh` picks which UI build an offscreen self-test drives (`MUSTER_UI=cpp|nim`) and launches and cleans up its instances. The C++ backend is the default. The Nim (seaqt) port is epic exo-607, `docs/design/seaqt-ui.md`.

- **Source these files, never execute them.** A self-test does `. scripts/lib/ui-build.sh`, then `ui_require_runner`, then `trap ui_cleanup EXIT`.
- **The contract** in `ui-build.sh`'s header is what makes the self-tests a parity oracle for the Nim build. Change it only together with every script that relies on it.
- **Cleanup is per session.** `ui_launch` starts each instance under `setsid`, and `ui_cleanup` kills only those sessions. Never go back to a machine-wide `pkill -f logos_host_qt`: other sessions and other self-tests run on the same machine.
- `scripts/ui-parity.sh` runs the whole suite for one build and prints a green/red table.
