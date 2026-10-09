#!/usr/bin/env bash
# A member names a room and leaves it (exo-dcc.25, exo-dcc.28) — offscreen, no GUI.
# Launch 1 joins a fresh topic (MUSTER_AUTOJOIN_TOPIC) and names it (MUSTER_AUTOTITLE,
# the room's Rename): the module must list the room with that name, and keep the name
# beside the joined rooms (room_titles.json). Launch 2, on the same user dir, re-enters
# the room and leaves it (MUSTER_AUTOLEAVE, the room's Leave): the room must leave the
# list, the joined rooms and the names. Launch 3 must re-enter no room at all.
# Exits non-zero otherwise, keeping the logs.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
TOPIC="/muster/1/leave-$(date +%s)/proto"
NAME="Dinner at Ana's"
D=$(mktemp -d)
fail() { echo "FAIL: $1; logs kept in $D"; exit 1; }
echo "topic: $TOPIC"

ui_launch "$D/A" "$D/A1.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" \
  MUSTER_AUTOTITLE="$NAME" LOGOS_INSTANCE_ID=leaveA
# (the UI's own log lines do not reach this log, so the module's files are the witness)
ok=0
for i in $(seq 1 60); do
  sleep 1
  titles=$(find "$D/A" -name room_titles.json 2>/dev/null | head -1)
  [ -n "$titles" ] && grep -qF "$NAME" "$titles" && { ok=1; break; }
done
[ "$ok" = 1 ] || fail "launch 1 never kept the name \"$NAME\""
sleep 2
ui_cleanup
rooms=$(find "$D/A" -name joined_rooms.json | head -1)
grep -qF "$TOPIC" "$rooms" 2>/dev/null || fail "the room was not remembered ($rooms)"
grep -qF "$TOPIC" "$titles" || fail "the name is not keyed by the room's topic ($titles)"
echo "1. joined and named \"$NAME\"; both kept beside the keystore"

sleep 2
ui_launch "$D/A" "$D/A2.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOLEAVE="$TOPIC" LOGOS_INSTANCE_ID=leaveA
ok=0
for i in $(seq 1 60); do
  sleep 1
  grep -qF "$TOPIC" "$rooms" || { ok=1; break; }
done
[ "$ok" = 1 ] || fail "launch 2 never left the room"
grep -aqF "rooms restored=1 topics=@[\"$TOPIC\"]" "$D/A2.log" || fail "launch 2 did not re-enter the room before leaving it"
sleep 2
ui_cleanup
grep -qF "$TOPIC" "$rooms" && fail "the left room is still in the joined rooms"
grep -qF "$TOPIC" "$titles" && fail "the left room's name is still kept"
echo "2. relaunched, re-entered, left: no longer listed, remembered or named"

sleep 2
ui_launch "$D/A" "$D/A3.log" MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" LOGOS_INSTANCE_ID=leaveA
ok=0
for i in $(seq 1 60); do
  sleep 1
  grep -aq 'rooms restored=' "$D/A3.log" 2>/dev/null && { ok=1; break; }
done
ui_cleanup
[ "$ok" = 1 ] || fail "launch 3 never reported the rooms it re-entered"
grep -aqF "rooms restored=0" "$D/A3.log" || fail "launch 3 re-entered a room it had left ($(grep -ao 'rooms restored=[^"]*' "$D/A3.log" | tail -1))"
echo "3. the next launch re-enters no room"
echo "SUCCESS: a room is named, kept by name across a relaunch, and once left, gone."
rm -rf "$D"
