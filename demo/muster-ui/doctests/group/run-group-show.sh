#!/usr/bin/env bash
# Role: doc-test display entry (the `#group` flake app); wraps run-group.sh then holds the window open.
# Run the real three-party group conversation, then hold the newest member's
# window open showing the result — the entry point for the `#group` flake app the
# doc-test drives.
#
# A group forms slowly (three delivery nodes finding each other, then two
# membership commits over the network), while the doc-test caps its capture step
# at 120s. So this splits the work: the slow group flow runs first, on its own
# inspector ports, and all three instances are *kept alive* (chats are ephemeral
# — the module persists nothing, so there is no history to reload a fresh window
# from). Only once the flow is done does SHOW_PORT open, as a TCP proxy onto
# Carol's live inspector. The doc-test attaches to that finished window and
# screenshots it well within its budget — the flow happens during the unbounded
# `launch_timeout` port-wait, before SHOW_PORT ever opens.
#
# Usage:
#   run-group-show.sh [base-dir]
# Env:
#   APP_BIN       run-logos-standalone-ui path (baked in by the flake app)
#   SHOW_PORT     capture port the doc-test attaches to (default 3768)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${1:-$(mktemp -d "${TMPDIR:-/tmp}/chat-group-show.XXXXXX")}"
DATA_DIR="$BASE/data"
OUT_DIR="${OUT_DIR:-$BASE/images}"
SHOW_PORT="${SHOW_PORT:-3768}"
# Carol (the last member to join) is the window we expose: her screen shows the
# creator's message received with a sender label beside the full roster.
# The flow runs on inspector ports 4778-4780 — distinct from the #exchange app's
# 4768-4769, so the two don't collide when the doc-test runs both specs in one
# job and a prior app's setsid'd module hosts outlive teardown.
CAROL_PORT=4780
mkdir -p "$DATA_DIR" "$OUT_DIR"

# All three exchange instances outlive run-group.sh here (KEEP_INSTANCES), so
# their teardown is ours: snapshot the logos process set before launch and, on
# exit, kill exactly the processes this run added (the module host processes set
# their own session, so a process-group kill would miss them). Plus the proxy.
LOGOS_PAT='logos_host_qt|logos-standalone-app|ui-host'
PRE_PIDS="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
PROXY_PID=""
show_cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  local now ours
  now="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
  ours="$(comm -13 <(printf '%s\n' "$PRE_PIDS") <(printf '%s\n' "$now") || true)"
  [ -n "$ours" ] && kill -9 $ours 2>/dev/null || true
}
trap 'exit 0' TERM INT
trap show_cleanup EXIT

# Phase 1: the real group flow, on inspector ports 4768/4769/4770 so SHOW_PORT
# stays closed until the finished window is ready. KEEP_INSTANCES leaves all
# three running with the completed group on screen.
echo "=== phase 1: three-party group chat (instances kept alive) ==="
ALICE_PORT=4778 BOB_PORT=4779 CAROL_PORT="$CAROL_PORT" \
  WORK_DIR="$DATA_DIR" KEEP_WORK_DIR=1 KEEP_INSTANCES=1 OUT_DIR="$OUT_DIR" \
  bash "$here/run-group.sh" "$OUT_DIR"

# Phase 2: make sure Carol's window still shows the group thread and roster
# before it is exposed to the doc-test.
echo "=== phase 2: verify the group is on screen ==="
SHOW_PORT="$CAROL_PORT" node "$here/select-group.mjs"

# Phase 3: open SHOW_PORT onto Carol's live inspector and hold the window for the
# doc-test to screenshot. The doc-test kills this process group when done; the
# EXIT trap reaps the proxy and all three instances. Probe the port before
# declaring ready: a proxy that failed to bind (e.g. SHOW_PORT already in use)
# would otherwise turn into a silent hold that never opens the port.
LISTEN_PORT="$SHOW_PORT" TARGET_PORT="$CAROL_PORT" node "$here/port-proxy.mjs" &
PROXY_PID=$!
proxy_up=""
for _ in $(seq 1 10); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$SHOW_PORT") 2>/dev/null; then proxy_up=1; break; fi
  sleep 1
done
[ -n "$proxy_up" ] || { echo "proxy on port $SHOW_PORT never came up" >&2; exit 1; }
echo "=== ready: group complete; exposing Carol on port $SHOW_PORT ==="
while true; do sleep 3600 & wait $!; done
