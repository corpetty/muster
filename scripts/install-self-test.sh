#!/usr/bin/env bash
# Offscreen proof that the card can offer to install a missing module (exo-dcc.10). One
# runner auto-joins a room and proposes a module action (the invoke driver) naming a
# module this host does not have. It then asks the module for that intent's readiness,
# which is what the card's "What this needs" box renders.
#
# The standalone runner bundles neither modules_state nor Package Manager, so this checks
# the runner's half:
#   - the module item reads unknown, with moduleState "unknown": with no registry the
#     host cannot say whether it is installed, and muster does not call a module it does
#     not declare (a call to one that isn't running blocks for lp's whole deadline);
#   - it names the package to install;
#   - the module thread is never blocked: no gap of 8 s or more between its log lines
#     before readiness answers (the 20 s stall this used to cost).
# Basecamp's half (the registry's three states, packages.install opening Package Manager)
# needs Basecamp itself; see docs/design/monero-in-rooms.md §6, M1d.
# Keys off the module's MUSTER_LP_DEBUG stderr lines, as card-self-test.sh does.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
TOPIC="/muster/1/installtest-$(date +%s)/proto"
D=$(mktemp -d)
MISSING=monero_wallet_backend
EFFECT='{"effect":"invoke","module":"'"$MISSING"'","method":"list_networks","args":[]}'
echo "topic: $TOPIC"
ui_launch "$D/A" "$D/A.log" \
  MUSTER_AUTOADMIT=1 MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" \
  MUSTER_AUTOPOLICY=invoke MUSTER_AUTOPROPOSE="$EFFECT" LOGOS_INSTANCE_ID=installtest
echo "runner launched offscreen; waiting for the propose → readiness round trip (up to 60s)..."
ok=1
for i in $(seq 1 12); do
  sleep 5
  grep -aq 'MUSTER-LP readiness' "$D/A.log" 2>/dev/null && break
done
LINE=$(grep -a 'MUSTER-LP readiness' "$D/A.log" | tail -1 | sed 's/.*MUSTER-LP readiness //')
[ -n "$LINE" ] || { echo "FAIL: no readiness payload"; ok=0; }
echo "── the module item (what the card renders) ──"
ITEM=$(printf '%s' "$LINE" | python3 -c '
import sys, json
j = json.loads(sys.stdin.read())
for it in j.get("items", []):
    if it.get("kind") == "module":
        print(json.dumps(it)); break' 2>/dev/null)
echo "${ITEM:-<none>}"
[ -n "$ITEM" ] || { echo "FAIL: no module item in readiness"; ok=0; }
printf '%s' "$ITEM" | grep -q '"name": "'"$MISSING"'"' || { echo "FAIL: the module item does not name $MISSING"; ok=0; }
printf '%s' "$ITEM" | grep -q '"status": "unknown"' || { echo "FAIL: $MISSING does not read unknown"; ok=0; }
printf '%s' "$ITEM" | grep -q '"moduleState": "unknown"' || { echo "FAIL: moduleState is not unknown (no registry in the runner)"; ok=0; }
printf '%s' "$ITEM" | grep -q '"install": "'"$MISSING"'"' || { echo "FAIL: the item does not name the package to install"; ok=0; }
printf '%s' "$ITEM" | grep -q "Package Manager" || { echo "FAIL: the remedy does not name Package Manager"; ok=0; }
echo "── the module thread ──"
GAP=$(grep -a 'MUSTER-LP' "$D/A.log" | awk -F'[][]' '
  { split($2, t, /[ :]/); s = t[2]*3600 + t[3]*60 + t[4]
    if (prev != "" && s - prev > max) max = s - prev
    prev = s }
  /MUSTER-LP readiness/ { printf "%.1f", max; exit }')
echo "longest silence before readiness answered: ${GAP:-?} s"
awk -v g="${GAP:-99}" 'BEGIN { exit !(g < 8) }' || { echo "FAIL: the module thread was blocked (${GAP:-?} s)"; ok=0; }
echo "── QML load ──"
if grep -aiE 'qrc:/.*(error|TypeError|ReferenceError)|QQmlApplicationEngine failed|is not a type' "$D/A.log"; then echo "QML ERRORS ABOVE"; ok=0; else echo "no QML errors"; fi
[ "$ok" = 1 ] && echo "SUCCESS: a module this host lacks reads unknown, names the package to install, and never blocks the module thread." || echo "FAILED — see $D/A.log"
[ "$ok" = 1 ]
