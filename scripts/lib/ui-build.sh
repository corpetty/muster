# shellcheck shell=bash
# Which UI build an offscreen self-test drives, and how it launches and cleans up
# that build's instances (exo-607 T0). Sourced by the self-tests; never executed.
#
#   MUSTER_UI=cpp   (default) the C++ backend, `make build` → .run/runner
#   MUSTER_UI=nim   the Nim (seaqt) backend → .run/runner-nim — nothing builds it
#                   until exo-607 T6, so every self-test is red on it by design
#
# THE CONTRACT a UI build must meet to be driven by these tests — the Nim build
# inherits it unchanged, which is what makes the self-tests its parity oracle:
#   * an executable at $RUNNER that takes `--user-dir <dir>` and honours
#     LOGOS_INSTANCE_ID and QT_QPA_PLATFORM=offscreen;
#   * it hosts muster_module (with delivery_module and lez_core), whose
#     MUSTER_LP_DEBUG lines ("MUSTER-LP …") land on its stdout/stderr;
#   * it runs the MUSTER_AUTO* autopilot (ui/src/muster_ui_backend.cpp
#     onContextReady), since offscreen nothing can click;
#   * a QML load error reaches the same log.
#
# Cleanup is per instance: each launch runs in its own session (setsid) and
# ui_cleanup kills exactly those sessions (the runner and the logos_host_qt
# children it spawned), so a self-test never takes down another session's runners.

MUSTER_UI="${MUSTER_UI:-cpp}"
case "$MUSTER_UI" in
  cpp) RUNNER=".run/runner/bin/muster-ui" ;;
  nim) RUNNER=".run/runner-nim/bin/muster-ui" ;;
  *) echo "MUSTER_UI must be cpp or nim, got '$MUSTER_UI'" >&2; exit 2 ;;
esac

# ui_require_runner — exit 1 (red) with the reason when the selected build is absent.
ui_require_runner() {
  if [ ! -x "$RUNNER" ]; then
    case "$MUSTER_UI" in
      cpp) echo "build the runner first: make build" ;;
      nim) echo "RED: no Nim UI build at $RUNNER — nothing builds it until exo-607 T6 (docs/design/seaqt-ui.md)" ;;
    esac
    exit 1
  fi
  echo "UI build: $MUSTER_UI ($RUNNER)"
}

UI_PIDS=()

# ui_launch <user-dir> <log> [VAR=value …] — one offscreen instance in its own session.
ui_launch() {
  local dir="$1" log="$2"; shift 2
  env "$@" QT_QPA_PLATFORM=offscreen setsid "$RUNNER" --user-dir "$dir" >"$log" 2>&1 &
  UI_PIDS+=("$!")
  disown "$!"
}

# ui_cleanup — kill every session ui_launch started, and nothing else.
ui_cleanup() {
  local pid sid
  for pid in "${UI_PIDS[@]}"; do
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$sid" ] && pkill -9 -s "$sid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
  done
  UI_PIDS=()
}
