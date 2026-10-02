#!/usr/bin/env bash
# Headless proof, under the CURRENT runtime, that keystore_module sees muster's calls as
# muster_module's (exo-149.1 K1). keystore_module admits a signing request only from a
# caller the runtime attributes as a plain module. The standalone runner cannot answer
# this: its host and capability_module predate caller naming, so every caller reads as
# "unknown" there (docs/labbook/keystore-caller-attribution.md). logoscore 0.3.1, the
# runtime released beside Basecamp 0.3.1, does name callers.
#
# One logoscore daemon over the runner's own (dev) modules, minus its old
# capability_module, so logoscore's current one serves the tokens:
#   control: the CLI calling keystore_module.caller_identity reads as "host";
#   the test: muster_module.keystore_status must read identity {module, muster_module}.
# A fresh keystore has no accounts, so "warn: no accounts yet" is the expected pass.
#   scripts/keystore-logoscore-test.sh                 # needs `make build` (the runner's modules)
#   LOGOSCORE_REV=0.3.1 KEEP_LOGS=1 scripts/keystore-logoscore-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CACHE=(--accept-flake-config --extra-substituters https://cache.nix.logos.co/public
       --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=)
REV="${LOGOSCORE_REV:-0.3.1}"

[ -e .run/runner ] || { echo "build the runner first: make build"; exit 1; }
MODS=$(nix-store -qR "$(readlink -f .run/runner)" | grep -- '-plugin-dir-modules$' | head -1)
[ -n "$MODS" ] || { echo "no bundled modules dir in the runner's closure"; exit 1; }
echo "logoscore $REV (github:logos-co/logos-logoscore-cli)…"
LC=$(nix build "github:logos-co/logos-logoscore-cli/$REV" --no-link --print-out-paths "${CACHE[@]}" 2>/dev/null | tail -1)
L="$LC/bin/logoscore"
[ -x "$L" ] || { echo "could not build logoscore $REV"; exit 1; }

D=$(mktemp -d); mkdir -p "$D/mods" "$D/cfg"
for m in "$MODS"/*/; do
  n=$(basename "$m"); [ "$n" = capability_module ] && continue   # logoscore brings its own
  cp -rL --no-preserve=mode "$m" "$D/mods/"
done
lc() { timeout 60 "$L" --config-dir "$D/cfg" "$@" 2>&1; }

MUSTER_LP_DEBUG=1 setsid "$L" --config-dir "$D/cfg" daemon -m "$D/mods" --persistence-path "$D/cfg/data" >"$D/daemon.log" 2>&1 &
DPID=$!
cleanup() { lc stop >/dev/null; kill -9 -"$DPID" 2>/dev/null; kill -9 "$DPID" 2>/dev/null; }
trap cleanup EXIT
for _ in $(seq 1 20); do lc status >/dev/null && break; sleep 1; done

ok=1
echo "── load muster_module"; lc load-module muster_module | tail -1
ctl=$(lc call keystore_module caller_identity | tail -1)
echo "── control: the CLI calling keystore_module.caller_identity"; echo "$ctl"
row="{}"
for _ in $(seq 1 10); do
  row=$(lc call muster_module keystore_status | tail -1 | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])' 2>/dev/null)
  echo "$row" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("identity") else 1)' 2>/dev/null && break
  sleep 2
done
echo "── muster_module.keystore_status"; echo "$row"

echo "$ctl" | python3 -c '
import sys,json
r=json.loads(json.load(sys.stdin)["result"])
assert r["kind"]=="host", "control: the CLI should read as host, got %r" % r
print("control: the CLI reads as host — this runtime attributes callers")' || ok=0
echo "$row" | python3 -c '
import sys,json
r=json.load(sys.stdin)
idn=r.get("identity") or {}
assert idn, "keystore_module never answered caller_identity: %r" % r
assert idn.get("kind")=="module" and idn.get("identity")=="muster_module", \
  "keystore_module attributes muster as %s %r, not module muster_module" % (idn.get("kind"), idn.get("identity"))
assert "evm_signer_ui" in r.get("approvers",[]), "no default approver: %r" % r
assert r.get("level") in ("ok","warn"), "level %r: %r" % (r.get("level"), r)
print("attested as", idn["kind"], idn["identity"], "·", r["level"], "·", r["detail"])' || ok=0

if [ "$ok" = 1 ]; then
  echo "PASS: under logoscore $REV, keystore_module attributes muster's calls to muster_module"
  [ -n "${KEEP_LOGS:-}" ] && echo "logs: $D" || rm -rf "$D"
  exit 0
fi
echo "FAIL — logs kept at $D"
exit 1
