#!/usr/bin/env bash
# Offscreen proof of the self-explaining card's host round trips (exo-002.3): one
# runner auto-joins a room, proposes an effect, asks the module for that intent's
# READINESS (the card's "What this needs" box) and DECLINES it — no GUI, no clicks.
# The UI plugin's qInfo is not relayed into the runner log, so the proof keys off the
# module's MUSTER_LP_DEBUG stderr lines (as two-instance-proof.sh does).
# Reports: the readiness payload the card renders (declared / ready / items with
# status + remedy / the disclosure incl. the store node), the decline folding into
# the intent view, and that the QML shell loaded without errors.
set -uo pipefail
cd "$(dirname "$0")/.."
RUNNER=".run/runner/bin/muster-ui"
[ -x "$RUNNER" ] || { echo "build the runner first: make build"; exit 1; }
CFG=$(python3 -c 'import json;print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))')
TOPIC="/muster/1/cardtest-$(date +%s)/proto"
D=$(mktemp -d)
EFFECT='{"to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":1,"nonce":0}'
echo "topic: $TOPIC"
MUSTER_AUTOADMIT=1 MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" \
MUSTER_AUTOPROPOSE="$EFFECT" MUSTER_AUTODECLINE=1 LOGOS_INSTANCE_ID=cardtest QT_QPA_PLATFORM=offscreen \
  setsid "$RUNNER" --user-dir "$D/A" >"$D/A.log" 2>&1 &
echo "runner launched offscreen; waiting for the propose → readiness → decline round trips (up to 40s)..."
ok=1
for i in $(seq 1 8); do
  sleep 5
  grep -aq 'MUSTER-LP decline' "$D/A.log" 2>/dev/null && break
done
echo "── readiness (what the card renders) ──"
grep -a 'MUSTER-LP readiness' "$D/A.log" | tail -1 | sed 's/.*MUSTER-LP readiness //' | cut -c1-1500 || ok=0
echo "── decline → intent view ──"
grep -a 'MUSTER-LP decline' "$D/A.log" | tail -1 | sed 's/.*MUSTER-LP decline //' || ok=0
echo "── QML load ──"
if grep -aiE 'qrc:/.*(error|TypeError|ReferenceError)|QQmlApplicationEngine failed|is not a type' "$D/A.log"; then echo "QML ERRORS ABOVE"; ok=0; else echo "no QML errors"; fi
grep -aq '"declared":true' "$D/A.log" || { echo "FAIL: no declared readiness payload"; ok=0; }
grep -aq '"to":"store-node"' "$D/A.log" || { echo "FAIL: disclosure does not name the store node"; ok=0; }
grep -aq '"declines":1' "$D/A.log" || { echo "FAIL: the decline did not fold"; ok=0; }
[ "$ok" = 1 ] && echo "SUCCESS: readiness + decline round-trip through the host; card payload honest." || echo "FAILED — see $D/A.log"
pkill -9 -f "user-dir $D" 2>/dev/null; pkill -9 -f logos_host_qt 2>/dev/null
[ "$ok" = 1 ] && rm -rf "$D"
exit $((1-ok))
