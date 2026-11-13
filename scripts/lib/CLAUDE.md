# scripts/lib — shell helpers the self-tests source

`ui-build.sh` picks which UI build an offscreen self-test drives (`MUSTER_UI=cpp|nim`) and launches and cleans up its instances. The C++ backend is the default. The Nim (seaqt) port is epic exo-607, `docs/design/seaqt-ui.md`.

- **Source these files, never execute them.** A self-test does `. scripts/lib/ui-build.sh`, then `ui_require_runner`, then `trap ui_cleanup EXIT`.
- **The contract** in `ui-build.sh`'s header is what makes the self-tests a parity oracle for the Nim build. Change it only together with every script that relies on it.
- **Cleanup is per session.** `ui_launch` starts each instance under `setsid`, and `ui_cleanup` kills only those sessions. Never go back to a machine-wide `pkill -f logos_host_qt`: other sessions and other self-tests run on the same machine. macOS has no `setsid` and its `ps` has no session id, so there `ui_launch` makes the session from python3 and `ui_cleanup` kills the instance's process group, which is its pid either way.
- `scripts/ui-parity.sh` runs the whole suite for one build and prints a green/red table.
- `portable.sh` is sourced by the release tooling that runs on Linux and macOS (`scripts/catalog-release.sh`): `lgx_variant` (this host's `.lgx` variant) and `sha256_of`. Its header lists the bash 3.2 and Darwin-tool spellings to avoid.
- **The C++ backend's own log lines** (its `[muster_ui]` qInfo, the autopilot's decisions) do not reach a self-test's logs by default; Qt sends them to the systemd journal. Run with `QT_FORCE_STDERR_LOGGING=1` to put them in the logs (exo-ca3).
- **Even then they are not bare.** ui-host relays them QDebug-quoted, several to a line, and now and then cuts one across two of its chunks or lets another process's line land inside one (seen on Linux CI). Read them with `ui_log <log>` (`ui_log.py`), never with a `sed` that only turns `\"` into `"`: that left every voice self-test line unreadable on Linux CI, which then failed "B never played" although B had. `scripts/tests/voice-self-test-replay.py` holds `ui_log.py` on lines cut from that run. `fileshare-self-test.sh` and `lez-msig-self-test.sh` still read with that `sed` and `grep -o`.
