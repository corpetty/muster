#!/usr/bin/env bash
# A relaunched member re-enters the rooms it had joined (exo-ecbe) — offscreen, no GUI.
# One runner joins a fresh topic (MUSTER_AUTOJOIN_TOPIC), which the module remembers
# beside the keystore (joined_rooms.json); it is then killed and relaunched on the SAME
# user dir with no join of any kind, and passes when the module reports re-entering that
# room at startup ("MUSTER-LP rooms restored=1 topics=@[<topic>]", from
# coordinate_start_inbox). Before exo-ecbe the joined set lived only in memory, so a
# relaunch listed no room on Home and the only way back was typing the topic.
#
# Both launches also check that no store node refused a query for its time range
# (exo-dcc.12). A delivery v0.3 store refuses a range whose ends are more than 24 h apart
# ("BAD_REQUEST: time range exceeds 24h", logos-delivery#4349). Delivery v0.3.0's own
# startup catch-up asks for [start - 24 h, now) on a first launch, and from its last
# moment online to now on a relaunch, so it was refused on every first launch, and on any
# relaunch after a day offline. Muster's own queries never name a range (store_catchup.nim).
# The node logs those refusals at DEBUG, so this test runs it at DEBUG, and gives each
# launch HOLD_S seconds for its catch-up to run. On a network with no store node
# (MUSTER_FLEET=local) nothing is asked, and the check passes vacuously.
# Exits non-zero otherwise, keeping the logs.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
TOPIC="/muster/1/relaunch-$(date +%s)/proto"
HOLD_S="${HOLD_S:-15}"
D=$(mktemp -d)
echo "topic: $TOPIC"

ui_launch "$D/A" "$D/A1.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_LOG=DEBUG MUSTER_DELIVERY_CONFIG="$CFG" \
  MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=relaunchA
joined=0
for i in $(seq 1 60); do
  sleep 1
  grep -aqE 'members=1' "$D/A1.log" 2>/dev/null && { joined=1; break; }
done
[ "$joined" = 1 ] || { echo "FAIL: the first launch never joined $TOPIC in 60s; logs kept in $D"; exit 1; }
f=$(find "$D/A" -name joined_rooms.json 2>/dev/null | head -1)
echo "first launch joined after ~${i}s; remembered: ${f:-none}$( [ -n "$f" ] && echo " → $(cat "$f")")"
sleep "$HOLD_S"            # the node's own startup catch-up runs over the subscribed topics

ui_cleanup
sleep 2
ui_launch "$D/A" "$D/A2.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_LOG=DEBUG MUSTER_DELIVERY_CONFIG="$CFG" LOGOS_INSTANCE_ID=relaunchA
echo "relaunched with no join; watching for the room to be re-entered (up to 60s)..."
ok=0
for i in $(seq 1 60); do
  sleep 1
  grep -aqF "rooms restored=1 topics=@[\"$TOPIC\"]" "$D/A2.log" 2>/dev/null && { ok=1; break; }
done
[ "$ok" = 1 ] && sleep "$HOLD_S"
ui_cleanup

node=$(grep -aoE 'Running nwaku node .*version=[^ ]+' "$D/A1.log" | grep -oE 'version=[^ ]+' | head -1)
refused=$(cat "$D/A1.log" "$D/A2.log" | grep -ac 'time range exceeds 24h')
if [ "$ok" != 1 ]; then
  echo "FAIL: the relaunch did not re-enter $TOPIC in 60s ($(grep -aoE 'rooms restored=[^"]*' "$D/A2.log" | tail -1 || true)); logs kept in $D"
  exit 1
fi
echo "the relaunch re-entered $TOPIC after ~${i}s, with no join."
if [ "$refused" -gt 0 ]; then
  echo "FAIL: store nodes refused $refused queries as 'time range exceeds 24h' (delivery node ${node:-version unknown}):"
  cat "$D/A1.log" "$D/A2.log" | grep -a 'time range exceeds 24h' | grep -aoE 'topics="[^"]*"' | sort | uniq -c
  echo "logs kept in $D"
  exit 1
fi
echo "SUCCESS: re-entered, and no store query was refused for its time range (delivery node ${node:-version unknown})."
rm -rf "$D"
