#!/usr/bin/env bash
# Offscreen proof that the room's infrastructure is dictated by its drivers (exo-428):
# one runner auto-joins a fresh room — its connectivity must name ONLY the delivery
# node (no RPC probed) — then proposes. Under POLICY=safe (default) the proposal must
# INTRODUCE the RPC row, naming the proposal; under POLICY=threshold it must not.
# Keys off the module's MUSTER_LP_DEBUG stderr lines, as card-self-test.sh does.
#   scripts/infra-self-test.sh            # Safe: RPC appears after the proposal
#   POLICY=threshold scripts/infra-self-test.sh   # threshold: RPC never appears
set -uo pipefail
cd "$(dirname "$0")/.."
RUNNER=".run/runner/bin/muster-ui"
[ -x "$RUNNER" ] || { echo "build the runner first: make build"; exit 1; }
POLICY="${POLICY:-safe}"
CFG=$(python3 -c 'import json;print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))')
TOPIC="/muster/1/infratest-$(date +%s)/proto"
D=$(mktemp -d)
EFFECT='{"to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":1,"nonce":0}'
echo "topic: $TOPIC  policy: $POLICY"
MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" \
MUSTER_AUTOPROPOSE="$EFFECT" MUSTER_AUTOPOLICY="$POLICY" MUSTER_AUTODISCLOSE=1 LOGOS_INSTANCE_ID=infratest QT_QPA_PLATFORM=offscreen \
  setsid "$RUNNER" --user-dir "$D/A" >"$D/A.log" 2>&1 &
echo "runner launched offscreen; waiting for join → propose (up to 40s)..."
for i in $(seq 1 8); do
  sleep 5
  [ "$(grep -ac 'MUSTER-LP connectivity' "$D/A.log" 2>/dev/null)" -ge 2 ] && break
done
ok=1
lines=$(grep -a 'MUSTER-LP connectivity' "$D/A.log" | sed 's/.*MUSTER-LP connectivity //')
[ -n "$lines" ] || { echo "FAIL: no connectivity payload"; ok=0; }
echo "── on join (before any proposal) ──"
first=$(echo "$lines" | head -1); echo "$first"
echo "$first" | python3 -c 'import sys,json; r=json.load(sys.stdin)["rows"]; assert [x["key"] for x in r]==["delivery"], r' \
  || { echo "FAIL: a fresh room shows more than its delivery node"; ok=0; }
echo "── after the $POLICY proposal ──"
last=$(echo "$lines" | tail -1); echo "$last"
if [ "$POLICY" = safe ]; then
  echo "$last" | python3 -c 'import sys,json; r={x["key"]:x for x in json.load(sys.stdin)["rows"]}; assert "rpc" in r, r; assert r["rpc"]["introducedBy"] and r["rpc"]["introducedBy"][0]["policy"].split("@")[0]=="safe", r["rpc"]' \
    || { echo "FAIL: the Safe proposal did not introduce the RPC"; ok=0; }
else
  echo "$last" | python3 -c 'import sys,json; r=[x["key"] for x in json.load(sys.stdin)["rows"]]; assert "rpc" not in r, r' \
    || { echo "FAIL: a $POLICY proposal introduced an RPC"; ok=0; }
fi
echo "── QML load ──"
if grep -aiE 'qrc:/.*(error|TypeError|ReferenceError)|QQmlApplicationEngine failed|is not a type' "$D/A.log"; then echo "QML ERRORS ABOVE"; ok=0; else echo "no QML errors"; fi
[ "$ok" = 1 ] && echo "SUCCESS: infrastructure follows the drivers ($POLICY)." || echo "FAILED — see $D/A.log"
pkill -9 -f "user-dir $D" 2>/dev/null; pkill -9 -f logos_host_qt 2>/dev/null
[ "$ok" = 1 ] && rm -rf "$D"
exit $((1-ok))
