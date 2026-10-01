#!/usr/bin/env bash
# Offscreen proof that the keystore row reaches muster through the UI path in the
# standalone runner (exo-149.1 K1): the UI's MUSTER_KEYSTORE_PROBE hook calls
# muster_module.keystore_status, muster_module reads keystore_module over lp_*, and the
# row comes back graded. One runner, no room, no fleet. MUSTER_LP_DEBUG=1 makes
# muster_module log each answer ("MUSTER-LP keystore {…}"; the UI host's own qInfo lines
# do not reach the runner's log).
#
# It does NOT gate attribution. The runner's host and capability_module predate caller
# naming, so keystore_module reads every caller there as "unknown" (seen 2026-10-01,
# docs/labbook/keystore-caller-attribution.md) and would refuse muster's signing
# requests. scripts/keystore-logoscore-test.sh is the attribution gate, under the
# current runtime. This test prints what the runner attributes, and passes when the
# keystore answered and the row is graded.
#   scripts/keystore-self-test.sh
#   KEEP_LOGS=1 scripts/keystore-self-test.sh      # keep the runner's log on success too
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
D=$(mktemp -d)
WAIT_S="${KEYSTORE_WAIT_S:-60}"
ui_launch "$D/A" "$D/A.log" MUSTER_LP_DEBUG=1 MUSTER_KEYSTORE_PROBE=1 LOGOS_INSTANCE_ID=kstest
echo "runner launched offscreen; waiting for keystore_module to answer (up to ${WAIT_S}s)..."

# the last keystore row the UI logged that carries an identity, as one line of JSON
last_row() {
  grep -a 'MUSTER-LP keystore ' "$D/A.log" 2>/dev/null | sed 's/.*MUSTER-LP keystore //' \
    | python3 -c 'import sys,json
rows=[]
for l in sys.stdin:
  try: rows.append(json.loads(l))
  except Exception: pass
withid=[r for r in rows if r.get("identity")]
print(json.dumps((withid or rows or [{}])[-1]))' 2>/dev/null
}
row="{}"
for i in $(seq 1 $((WAIT_S / 2))); do
  sleep 2
  row=$(last_row)
  echo "$row" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("identity") else 1)' 2>/dev/null && break
done

ok=1
echo "── the keystore row ──"
echo "$row"
echo "$row" | python3 -c '
import sys,json
r=json.load(sys.stdin)
assert r.get("key")=="keystore", "no keystore row: %r" % r
idn=r.get("identity") or {}
assert idn, "keystore_module never answered caller_identity: %r" % r
assert "evm_signer_ui" in r.get("approvers",[]), "no default approver: %r" % r
assert r.get("level") in ("ok","warn","down") and r.get("detail"), "ungraded row: %r" % r
if idn.get("kind")=="module" and idn.get("identity")=="muster_module":
  print("attested as module muster_module ·", r["level"], "·", r["detail"])
else:
  print("the runner attributes muster as %s %r (its host predates caller naming; the gate is keystore-logoscore-test.sh) · row %s" % (idn.get("kind"), idn.get("identity"), r["level"]))' \
  || ok=0
grep -a -m1 'Module loaded: keystore_module' "$D/A.log" || echo "keystore_module never loaded"

if [ "$ok" = 1 ]; then
  echo "PASS: the keystore row reaches muster through the UI path, graded"
  [ -n "${KEEP_LOGS:-}" ] && echo "log: $D/A.log" || rm -rf "$D"
  exit 0
fi
echo "FAIL — log kept at $D/A.log"
exit 1
