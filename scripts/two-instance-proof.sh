#!/usr/bin/env bash
# Proof that two muster instances converge over the Logos fleet — no GUI, no manual
# steps. Launches two offscreen runners auto-joined to ONE topic (A is the founder and
# auto-admits), and passes when BOTH report members=2: B's join request crossed to A,
# A admitted it, and the re-key grant crossed back. Exits non-zero otherwise, keeping
# both logs. (A's pending=1 is only transient under auto-admit — it drops to 0 on the
# admit — so it is reported, not asserted.)
set -uo pipefail
cd "$(dirname "$0")/.."
RUNNER=".run/runner/bin/muster-ui"
[ -x "$RUNNER" ] || { echo "build the runner first: make build"; exit 1; }
CFG=$(python3 -c 'import json;print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))')
TOPIC="/muster/1/proof-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC"
MUSTER_AUTOADMIT=1 MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=proofA QT_QPA_PLATFORM=offscreen \
  setsid "$RUNNER" --user-dir "$D/A" >"$D/A.log" 2>&1 &
sleep 3
MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=proofB QT_QPA_PLATFORM=offscreen \
  setsid "$RUNNER" --user-dir "$D/B" >"$D/B.log" 2>&1 &
echo "two instances launched; watching for both to reach members=2 (up to 60s)..."
both() { grep -aqE 'members=2' "$D/A.log" 2>/dev/null && grep -aqE 'members=2' "$D/B.log" 2>/dev/null; }
ok=0
for i in $(seq 1 60); do
  sleep 1
  both && { ok=1; break; }
done
pkill -9 -f "user-dir $D" 2>/dev/null; pkill -9 -f logos_host_qt 2>/dev/null
saw() { grep -aqE "$1" "$2" 2>/dev/null && echo yes || echo no; }
echo "A saw the join request (pending=1): $(saw 'pending=1' "$D/A.log") · A members=2: $(saw 'members=2' "$D/A.log") · B members=2: $(saw 'members=2' "$D/B.log")"
if [ "$ok" = 1 ]; then
  echo "SUCCESS: both instances at members=2 after ~${i}s — the handshake crossed the fleet both ways."
  rm -rf "$D"
else
  echo "FAIL: not converged in 60s — createNode: $(grep -aoE 'createNode result=[^ ]{0,20}' "$D/A.log"|tail -1); logs kept in $D"
  exit 1
fi
