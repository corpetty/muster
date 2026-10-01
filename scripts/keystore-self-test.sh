#!/usr/bin/env bash
# Offscreen proof that keystore_module sees muster's calls as muster_module's
# (exo-149.1 K1) — the question every later step of exo-149 rests on. keystore_module
# admits a signing request only from a caller the runtime attributes as a plain module;
# muster_module calls it over lp_* (protocol-0.2 Nim glue calling a protocol-0.9 Rust
# module), and nothing had checked what the keystore sees. One runner, no room, no
# fleet: MUSTER_KEYSTORE_PROBE=1 makes the UI read keystore_status every 2 s, and
# MUSTER_LP_DEBUG=1 makes muster_module log each answer ("MUSTER-LP keystore {…}"; the
# UI host's own qInfo lines do not reach the runner's log).
#
# Pass: the row's identity is {kind: module, identity: muster_module}, it names the
# keystore's default approver (evm_signer_ui), and its level is not down. A fresh
# keystore has no accounts, so "warn: no accounts yet" is the expected pass; with
# accounts it reads ok.
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
assert idn.get("kind")=="module" and idn.get("identity")=="muster_module", \
  "keystore_module attributes muster as %s %r, not module muster_module: every request would be refused" % (idn.get("kind"), idn.get("identity"))
assert "evm_signer_ui" in r.get("approvers",[]), "no default approver: %r" % r
assert r.get("level") in ("ok","warn"), "level %r: %r" % (r.get("level"), r)
print("attested as", idn["kind"], idn["identity"], "· approvers", r["approvers"], "·", len(r.get("accounts",[])), "accounts ·", r["level"], "·", r["detail"])' \
  || ok=0
grep -a -m1 'Module loaded: keystore_module' "$D/A.log" || echo "keystore_module never loaded"

if [ "$ok" = 1 ]; then
  echo "PASS: keystore_module attributes muster's calls to muster_module"
  [ -n "${KEEP_LOGS:-}" ] && echo "log: $D/A.log" || rm -rf "$D"
  exit 0
fi
echo "FAIL — log kept at $D/A.log"
exit 1
