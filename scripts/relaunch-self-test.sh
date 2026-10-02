#!/usr/bin/env bash
# A relaunched member re-enters the rooms it had joined (exo-ecbe) — offscreen, no GUI.
# One runner joins a fresh topic (MUSTER_AUTOJOIN_TOPIC), which the module remembers
# beside the keystore (joined_rooms.json); it is then killed and relaunched on the SAME
# user dir with no join of any kind, and passes when the module reports re-entering that
# room at startup ("MUSTER-LP rooms restored=1 topics=@[<topic>]", from
# coordinate_start_inbox). Before exo-ecbe the joined set lived only in memory, so a
# relaunch listed no room on Home and the only way back was typing the topic.
# Exits non-zero otherwise, keeping the logs.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
TOPIC="/muster/1/relaunch-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC"

ui_launch "$D/A" "$D/A1.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=relaunchA
joined=0
for i in $(seq 1 60); do
  sleep 1
  grep -aqE 'members=1' "$D/A1.log" 2>/dev/null && { joined=1; break; }
done
[ "$joined" = 1 ] || { echo "FAIL: the first launch never joined $TOPIC in 60s; logs kept in $D"; exit 1; }
f=$(find "$D/A" -name joined_rooms.json 2>/dev/null | head -1)
echo "first launch joined after ~${i}s; remembered: ${f:-none}$( [ -n "$f" ] && echo " → $(cat "$f")")"

ui_cleanup
sleep 2
ui_launch "$D/A" "$D/A2.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" LOGOS_INSTANCE_ID=relaunchA
echo "relaunched with no join; watching for the room to be re-entered (up to 60s)..."
ok=0
for i in $(seq 1 60); do
  sleep 1
  grep -aqF "rooms restored=1 topics=@[\"$TOPIC\"]" "$D/A2.log" 2>/dev/null && { ok=1; break; }
done
ui_cleanup
if [ "$ok" = 1 ]; then
  echo "SUCCESS: the relaunch re-entered $TOPIC after ~${i}s, with no join."
  rm -rf "$D"
else
  echo "FAIL: the relaunch did not re-enter $TOPIC in 60s ($(grep -aoE 'rooms restored=[^"]*' "$D/A2.log" | tail -1 || true)); logs kept in $D"
  exit 1
fi
