#!/usr/bin/env bash
# A relaunched founder reads its founding epoch again (exo-6dc.1) — offscreen, no GUI,
# over the live fleet (its store is what a relaunch rebuilds from; MUSTER_FLEET=local runs
# no store, so this test needs a real fleet).
# A solo founder joins a fresh topic and proposes (MUSTER_AUTOPROPOSE), so the room holds
# an intent-ref card sealed under epoch 0, the epoch no grant ever carries. It is killed,
# relaunched on the SAME user dir, and re-enters the room; it passes when the card comes
# back from the store ("members=1 msgs=1"). Before exo-6dc.1 epoch 0's key was random and
# lost with the process: the store returned the room's frames and the founder could open
# none of them ("msgs=0").
# Usage: scripts/founding-relaunch-self-test.sh [runner-bin]   (default: this tree's runner)
# Exits non-zero otherwise, keeping the logs.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
[ $# -gt 0 ] && RUNNER="$1"
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
TOPIC="/muster/1/founding-relaunch-$(date +%s)-$RANDOM/proto"
EFFECT='{"to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":1,"nonce":0}'
D=$(mktemp -d)
echo "topic: $TOPIC"

ui_launch "$D/A" "$D/A1.log" MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" \
  MUSTER_AUTOJOIN_TOPIC="$TOPIC" MUSTER_AUTOPROPOSE="$EFFECT" LOGOS_INSTANCE_ID=foundingA
ok=0
for i in $(seq 1 90); do sleep 1; grep -aqE 'members=1 msgs=1' "$D/A1.log" 2>/dev/null && { ok=1; break; }; done
[ "$ok" = 1 ] || { echo "FAIL: the first launch never showed its proposal card (msgs=1) in 90s; logs kept in $D"; exit 1; }
echo "first launch: the proposal card is in the room after ~${i}s"
sleep 15            # let the sends reach the fleet's store
ui_cleanup
sleep 3

ui_launch "$D/A" "$D/A2.log" MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" \
  MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=foundingA
echo "relaunched into the room; waiting for the card from before the restart (up to 120s)..."
ok=0
for i in $(seq 1 120); do sleep 1; grep -aqE 'members=1 msgs=1' "$D/A2.log" 2>/dev/null && { ok=1; break; }; done
last=$(grep -aoE 'members=[0-9]+ msgs=[0-9]+' "$D/A2.log" | tail -1)
ui_cleanup
if [ "$ok" = 1 ]; then
  echo "SUCCESS: after the relaunch the founder reads its founding epoch again (~${i}s; $last)."
  rm -rf "$D"
else
  echo "FAIL: after 120s the relaunched founder reads ${last:-nothing}; logs kept in $D"
  exit 1
fi
