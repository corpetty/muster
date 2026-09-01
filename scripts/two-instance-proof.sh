#!/usr/bin/env bash
# Proof that two muster instances converge over the Logos fleet — no GUI, no manual
# steps. Launches two offscreen runners auto-joined to ONE topic (A is the founder),
# and reports whether the founder sees the joiner's request cross-host.
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
echo "two instances launched; watching for cross-host delivery (up to 60s)..."
for i in $(seq 1 12); do
  sleep 5
  P=$(grep -aoE 'pending=[0-9]+' "$D/A.log" 2>/dev/null | tail -1)
  [ "$P" = "pending=1" ] && { echo "SUCCESS: founder sees the joiner cross-host ($P) — transport works."; break; }
done
[ "${P:-}" = "pending=1" ] || echo "NOT YET: A=$(grep -aoE 'pending=[0-9]+' "$D/A.log"|tail -1) — createNode: $(grep -aoE 'createNode result=[^ ]{0,20}' "$D/A.log"|tail -1)"
pkill -9 -f "user-dir $D" 2>/dev/null; pkill -9 -f logos_host_qt 2>/dev/null; rm -rf "$D"
