# shellcheck shell=bash
# Which UI build an offscreen self-test drives, and how it launches and cleans up
# that build's instances (exo-607 T0). Sourced by the self-tests; never executed.
#
#   MUSTER_UI=cpp   (default) the C++ backend, `make build` → .run/runner
#   MUSTER_UI=nim   the Nim (seaqt) app → .run/runner-nim, built by
#                   scripts/build-runner-nim.sh (make build-nim) on the C++ runner's
#                   modules (exo-607 T6, ADR-019)
#
# THE CONTRACT a UI build must meet to be driven by these tests — the Nim build
# inherits it unchanged, which is what makes the self-tests its parity oracle:
#   * an executable at $RUNNER that takes `--user-dir <dir>` and honours
#     LOGOS_INSTANCE_ID and QT_QPA_PLATFORM=offscreen;
#   * it hosts muster_module (with delivery_module and lez_core), whose
#     MUSTER_LP_DEBUG lines ("MUSTER-LP …") land on its stdout/stderr;
#   * it runs the MUSTER_AUTO* autopilot (ui/src/muster_ui_backend.cpp
#     onContextReady; ui-nim/app/backend.nim contextReady), since offscreen nothing can click;
#   * a QML load error reaches the same log.
#
# To see the C++ backend's own lines (its [muster_ui] qInfo, the autopilot's decisions)
# in a self-test's logs, run it with QT_FORCE_STDERR_LOGGING=1: ui_launch passes the
# environment through, and without it Qt sends ui-host's logging to the systemd journal
# (`journalctl --user _PID=<ui-host pid>`), not to the runner's log. exo-ca3 was
# diagnosed from the journal that way.
#
# Even then those lines are not in the log bare. ui-host relays the plugin's output a chunk
# at a time, each chunk one line, QDebug-quoted, `ui-host [ "muster_ui" ]: "<chunk>"`, often
# several of the plugin's lines to a chunk, and now and then a line is cut across two chunks
# or another process's line lands inside one (seen on Linux CI, run 39836679442). The Nim
# build writes its lines bare. Read a [muster_ui] line with `ui_log <log>`, which prints the
# log with each of the UI's lines whole on a line of its own, and every other line unchanged
# (scripts/lib/ui_log.py says what it undoes); grep -o over the raw log finds only what the
# relay's quoting and cuts happen to leave alone.
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
# Two overrides for scripts/ui-screenshot.sh (exo-720.2), both unset in an ordinary run:
#   MUSTER_RUNNER  another build meeting the contract above — a dev runner
#                  (scripts/lib/ui-dev.sh): a runner's compiled code with this tree's QML
#   MUSTER_QPA     the Qt platform instead of offscreen — xcb on an Xvfb display, where the
#                  QML view IS instantiated (offscreen it never is), so it can be recorded
RUNNER="${MUSTER_RUNNER:-$RUNNER}"

# The delivery network a self-test's instances join:
#   MUSTER_FLEET=logos.dev   (default) cluster 3, no RLN — a node starts with nothing more
#   MUSTER_FLEET=logos.test  cluster 2, RLN on since Testnet v0.3: a delivery v0.3 node
#                            there sends nothing until it has the RLN modules and an
#                            active, funded membership (exo-eb6.3), so not the default yet
#   MUSTER_FLEET=local       no fleet (exo-eb6.7): the instances make their own network on
#                            this host. The first one launched (the hub) listens on a
#                            free 127.0.0.1 port; each later one dials it. Delivery's own
#                            e2e shape: cluster 198, one shard, relay. The hub also serves
#                            a store, and every other instance names it as its store peer
#                            (entryNodes), so a frame published before an instance
#                            subscribed (an invite's grant, exo-e6aa) reaches it by
#                            catch-up, as on a fleet. Nothing off this host is reached. It
#                            checks the code while the fleet is down; the fleet runs stay
#                            the live check.
# The fleets' configs are infra/fleets/<name>.json.
#
# MUSTER_MIX=preferred|required (unset: off) reaches every instance through the
# environment and sends its room messages through the mixnet (exo-dcc.4,
# docs/labbook/mixnet-on-delivery-03.md). Each instance is then a mix node others route
# through, and one that has exited stays in the network's mix pool for a while: a later
# run's sends that pick it wait 5 s and retry.
MUSTER_FLEET="${MUSTER_FLEET:-logos.dev}"

# ui_local_config [hub multiaddr] — a local node's createNode config on a free port,
# dialing the hub when one is named.
ui_local_config() {
  python3 - "${1:-}" <<'EOF'
import json, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
import tempfile
hub = sys.argv[1]
cfg = {"logLevel": "INFO", "listenAddress": "127.0.0.1", "tcpPort": port, "clusterId": 198,
       "numShardsInNetwork": 1, "relay": True, "store": not hub, "filter": False,
       "lightpush": False, "peerExchange": False, "discv5Discovery": False,
       "reliabilityEnabled": True}
if not hub:
    # the store's database in a scratch directory, never the runner's working directory
    cfg["storeMessageDbUrl"] = "sqlite://" + tempfile.mkdtemp(prefix="muster-local-store-") + "/store.sqlite3"
if hub:
    cfg["staticnodes"] = [hub]
    cfg["entryNodes"] = [hub]   # the hub's store: muster's catch-up peer (node_config.nim)
print(json.dumps(cfg))
EOF
}

# ui_fleet_config — the createNode config for the first instance a test launches, as one
# line of JSON: the selected fleet's, or locally the hub's.
ui_fleet_config() {
  if [ "$MUSTER_FLEET" = local ]; then ui_local_config; return; fi
  local f="infra/fleets/$MUSTER_FLEET.json"
  [ -f "$f" ] || { echo "no fleet config $f (MUSTER_FLEET=$MUSTER_FLEET; infra/fleets/refresh.sh)" >&2; exit 2; }
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["delivery_createNode_config"]))' "$f"
}

# ui_peer_config <hub log> — the config for each instance launched after the first, once
# the first has had time to come up. On a fleet that is the fleet's config, after 3 s.
# Locally it waits up to 30 s for the hub's node to start, reads its address from
# delivery's "Started libp2p node" line, and dials it; exit 1 if the hub never started.
ui_peer_config() {
  local hublog="$1" addr="" i
  if [ "$MUSTER_FLEET" != local ]; then sleep 3; ui_fleet_config; return; fi
  for i in $(seq 1 60); do
    addr=$(grep -a -m1 'Started libp2p node' "$hublog" 2>/dev/null | python3 -c '
import re, sys
m = re.search(r"peerId: (16U\w+), listenAddrs: \[(/ip4/[^/]+/tcp/\d+)", sys.stdin.read())
print(m.group(2) + "/p2p/" + m.group(1) if m else "")')
    [ -n "$addr" ] && break
    sleep 0.5
  done
  [ -n "$addr" ] || { echo "the local hub's node never started (no 'Started libp2p node' in $hublog)" >&2; exit 1; }
  ui_local_config "$addr"
}

# ui_log <log> — the log with the UI's own lines as it wrote them, one to a line (above);
# nothing for a log that is not there yet.
UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ui_log() { python3 -I "$UI_LIB_DIR/ui_log.py" "$1" 2>/dev/null; }

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
# A session of its own for each instance: util-linux's setsid, or on macOS, which has none,
# the same call from python3. Either way the runner keeps its pid, which names its session
# and its process group.
if command -v setsid >/dev/null 2>&1; then UI_SETSID=(setsid)
else UI_SETSID=(python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])'); fi

# ui_launch <user-dir> <log> [VAR=value …] — one offscreen instance in its own session.
ui_launch() {
  local dir="$1" log="$2"; shift 2
  env "$@" QT_QPA_PLATFORM="${MUSTER_QPA:-offscreen}" "${UI_SETSID[@]}" "$RUNNER" --user-dir "$dir" >"$log" 2>&1 &
  UI_PIDS+=("$!")
  disown "$!"
}

# ui_cleanup — kill every session ui_launch started, and nothing else. macOS's ps has no
# session id, so there it kills the instance's process group, which setsid made its pid.
ui_cleanup() {
  local pid sid
  for pid in ${UI_PIDS[@]+"${UI_PIDS[@]}"}; do
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$sid" in *[!0-9]*) sid="" ;; esac   # macOS's ps prints its keyword list instead
    [ -n "$sid" ] && pkill -9 -s "$sid" 2>/dev/null
    [ -n "$sid" ] || pkill -9 -g "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
  done
  UI_PIDS=()
}
