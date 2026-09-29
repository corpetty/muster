#!/usr/bin/env bash
# Proof that a room invite crosses the Logos fleet — no GUI, no manual steps. A (seeded
# as Alice) joins a fresh room and invites the contact "Bob", exactly as the composer's
# "Open the room with them" does; B (seeded as Bob, so his chat id is the one Alice's
# contact names) sits on Home, where the inbox is polled. Passes when B's module can open
# an invite for that room. Exits non-zero otherwise, keeping both logs.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(python3 -c 'import json;print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))')
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
ROOM="muster.room.invite$(date +%s)"
TOPIC="/muster/1/$ROOM/proto"
D=$(mktemp -d)
echo "room: $TOPIC"
ui_launch "$D/B" "$D/B.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DEV_SECP_KEY=$KEY1 MUSTER_DELIVERY_CONFIG="$CFG" LOGOS_INSTANCE_ID=inviteB
sleep 3
ui_launch "$D/A" "$D/A.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DEV_SECP_KEY=$KEY0 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$ROOM" MUSTER_AUTOINVITE=Bob LOGOS_INSTANCE_ID=inviteA
echo "two instances launched; watching Bob's inbox for the invite (up to 90s)..."
ok=0
for i in $(seq 1 90); do
  sleep 1
  grep -a 'MUSTER-LP invites=' "$D/B.log" 2>/dev/null | grep -aqF "$ROOM" && { ok=1; break; }
done
ui_cleanup
echo "B polled its inbox: $(grep -ac 'MUSTER-LP invites=' "$D/B.log") times · last: $(grep -a 'MUSTER-LP invites=' "$D/B.log" | tail -1)"
if [ "$ok" = 1 ]; then
  echo "SUCCESS: Bob's inbox opened the invite after ~${i}s — it crossed the fleet."
  rm -rf "$D"
else
  echo "FAIL: no invite in Bob's inbox in 90s; logs kept in $D"
  exit 1
fi
