#!/usr/bin/env bash
# Offscreen proof that a node on logos.test says where its RLN membership stands
# (exo-eb6.3 R1). One runner joins a fresh room on logos.test. Its connectivity must
# carry the "rln" row, and that row must reach "awaiting funding": the RLN modules
# have provisioned the node's wallet on the registry's zone, derived a payer, read
# its native balance, and found it short. The row names the payer (64 hex), the
# zone, and the amount to send. No funds are needed; it is the step before them.
#
# It needs the RLN registry's zone (209.38.241.182:3240) to answer more than the
# fleet: a v0.3 node on logos.test runs without a membership (rlnState reads "Ready")
# but holds every send, retrying ("Failed to attach RLN proof"), which is expected
# here. The row says the node's messages wait.
#   scripts/rln-self-test.sh                       # logos.test, up to 150 s
#   RLN_WAIT_S=300 scripts/rln-self-test.sh
#   KEEP_LOGS=1 scripts/rln-self-test.sh           # keep the runner's log on success too
set -uo pipefail
cd "$(dirname "$0")/.."
export MUSTER_FLEET=logos.test
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
TOPIC="/muster/1/rlntest-$(date +%s)/proto"
D=$(mktemp -d)
WAIT_S="${RLN_WAIT_S:-150}"
echo "topic: $TOPIC  fleet: $MUSTER_FLEET"
ui_launch "$D/A" "$D/A.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=rlntest
echo "runner launched offscreen; waiting for the rln row to reach awaiting funding (up to ${WAIT_S}s)..."

# the last rln row the room's connectivity carried, as one line of JSON ("" if none)
last_rln() {
  grep -a 'MUSTER-LP connectivity' "$D/A.log" 2>/dev/null | tail -1 | sed 's/.*MUSTER-LP connectivity //' \
    | python3 -c 'import sys,json
try:
  r=[x for x in json.load(sys.stdin)["rows"] if x.get("key")=="rln"]
  print(json.dumps(r[0]) if r else "")
except Exception: print("")' 2>/dev/null
}
row=""; seen=""
for i in $(seq 1 $((WAIT_S / 5))); do
  sleep 5
  row=$(last_rln)
  detail=$(echo "$row" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("detail",""))' 2>/dev/null)
  [ -n "$detail" ] && [ "$detail" != "$seen" ] && { echo "  $((i * 5))s  $detail"; seen="$detail"; }
  case "$detail" in "awaiting funding"*|"funded"*|"active"*|"registering"*) break ;; esac
done

ok=1
echo "── the rln row ──"
echo "${row:-<none>}"
[ -n "$row" ] || { echo "FAIL: no rln row in connectivity on logos.test"; ok=0; }
echo "$row" | python3 -c '
import sys,json,re
r=json.load(sys.stdin)
assert r["level"]=="warn" and r["detail"].startswith("awaiting funding"), "not awaiting funding: %r" % r
assert "messages wait" in r["detail"], "does not say the messages wait: %r" % r
assert re.fullmatch(r"[0-9a-f]{64}", r.get("payer","")), "no payer: %r" % r
assert r["payer"] in r["remedy"] and "209.38.241.182:3240" in r["remedy"] and "200000000" in r["remedy"], "remedy: %r" % r
print("payer", r["payer"], "holds", r.get("balance"), "native LEZ")' \
  || { echo "FAIL: the row did not reach awaiting funding with the payer, the zone and the amount"; ok=0; }
echo "── what the RLN modules said ──"
grep -aE 'rln|RLN' "$D/A.log" | grep -av 'MUSTER-LP connectivity' | tail -8
echo "── QML load ──"
if grep -aiE 'qrc:/.*(error|TypeError|ReferenceError)|QQmlApplicationEngine failed|is not a type' "$D/A.log"; then echo "QML ERRORS ABOVE"; ok=0; else echo "no QML errors"; fi
[ "$ok" = 1 ] && echo "SUCCESS: on logos.test the node names its RLN payer, awaiting funding." || echo "FAILED — see $D/A.log"
ui_cleanup
[ "$ok" = 1 ] && { [ -n "${KEEP_LOGS:-}" ] && echo "logs kept in $D" || rm -rf "$D"; }
exit $((1-ok))
