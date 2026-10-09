#!/usr/bin/env bash
# Proof that a room invite crosses the Logos fleet (or, with MUSTER_FLEET=local, a
# network of their own on this host) — no GUI, no manual steps. A (seeded
# as Alice) joins a fresh room and invites the contact "Bob", exactly as the composer's
# "Open the room with them" does; B (seeded as Bob, so his chat id is the one Alice's
# contact names) sits on Home, where the inbox is polled. Passes when B's module can open
# an invite for that room, and B, joining it without a join request, is already a member
# (the invite admitted him, exo-dcc.29). Exits non-zero otherwise, keeping both logs.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
ROOM="muster.room.invite$(date +%s)"
TOPIC="/muster/1/$ROOM/proto"
D=$(mktemp -d)
echo "room: $TOPIC"
ui_launch "$D/B" "$D/B.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DEV_SECP_KEY=$KEY1 MUSTER_DELIVERY_CONFIG="$CFG" LOGOS_INSTANCE_ID=inviteB \
  MUSTER_AUTOACCEPT_INVITE="$ROOM"
CFG_A=$(ui_peer_config "$D/B.log") || exit 1
ui_launch "$D/A" "$D/A.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DEV_SECP_KEY=$KEY0 MUSTER_DELIVERY_CONFIG="$CFG_A" MUSTER_AUTOJOIN_TOPIC="$ROOM" MUSTER_AUTOINVITE=Bob LOGOS_INSTANCE_ID=inviteA
echo "two instances launched; watching Bob's inbox for the invite (up to 90s)..."
ok=0
for i in $(seq 1 90); do
  sleep 1
  grep -a 'MUSTER-LP invites=' "$D/B.log" 2>/dev/null | grep -aqF "$ROOM" && { ok=1; break; }
done
# Then Bob joins the invited room WITHOUT asking (exo-dcc.29), and nobody admits him: the
# invite alone must have made him a member, so his roster reaches two.
member=0
if [ "$ok" = 1 ]; then
  for j in $(seq 1 60); do
    sleep 1
    grep -a 'MUSTER-LP pending=' "$D/B.log" 2>/dev/null | grep -aq 'members=2' && { member=1; break; }
  done
fi
ui_cleanup
echo "B polled its inbox: $(grep -ac 'MUSTER-LP invites=' "$D/B.log") times · last: $(grep -a 'MUSTER-LP invites=' "$D/B.log" | tail -1)"
if [ "$ok" = 1 ] && [ "$member" = 1 ]; then
  echo "SUCCESS: Bob's inbox opened the invite after ~${i}s — it crossed $MUSTER_FLEET — and he joined a member, no ask, ~${j}s later."
  rm -rf "$D"
elif [ "$ok" = 1 ]; then
  echo "FAIL: the invite arrived, but joining without asking left Bob outside the room (no members=2 in 60s); logs kept in $D"
  exit 1
else
  echo "FAIL: no invite in Bob's inbox in 90s; logs kept in $D"
  exit 1
fi
