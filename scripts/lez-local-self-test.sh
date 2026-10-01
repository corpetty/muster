#!/usr/bin/env bash
# Offscreen proof that muster's real LEZ wallet works on a LEZ v0.3 zone with no faucet
# (exo-eb6.4 L2). A local v0.3.0 sequencer comes up with one genesis-funded account, the
# funder's, held by LEZ's own wallet CLI (infra/lez/localnet.sh). One runner, its wallet
# the real lez_core on that zone (MUSTER_LEZ_REAL, MUSTER_LEZ_RPC), creates its accounts
# and logs the public one as awaiting funds (MUSTER_AUTOLEZFUND). The funder sends to it,
# as a person holding native LEZ would. Passes when muster reads that exact amount back
# through lez_core.
#
#   make build && scripts/lez-local-self-test.sh       # LEZ_FUND_AMOUNT (default 1000)
#
# The sequencer is left running (infra/lez/localnet.sh stop); KEEP_LOGS=1 keeps the log.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
AMOUNT="${LEZ_FUND_AMOUNT:-1000}"
URL="http://127.0.0.1:3040"

infra/lez/localnet.sh stop >/dev/null 2>&1
infra/lez/localnet.sh || { echo "FAIL: the local LEZ v0.3 zone did not start"; exit 1; }

D=$(mktemp -d)
ui_launch "$D/A" "$D/A.log" \
  MUSTER_LP_DEBUG=1 QT_FORCE_STDERR_LOGGING=1 MUSTER_LEZ_REAL=1 MUSTER_LEZ_RPC="$URL" \
  MUSTER_DATA_DIR="$D/data" MUSTER_AUTOLEZFUND=1 MUSTER_DELIVERY_CONFIG="$(MUSTER_FLEET=local ui_local_config)" \
  LOGOS_INSTANCE_ID=lezlocal
echo "runner launched offscreen; waiting for the account it needs funded (up to 90s)..."
acct=""
for _ in $(seq 1 45); do
  acct=$(grep -aoE 'LEZFUND awaiting funds at \\?"?[0-9a-f]{64}' "$D/A.log" 2>/dev/null | head -1 | grep -oE '[0-9a-f]{64}')
  [ -n "$acct" ] && break
  sleep 2
done
ok=1
[ -n "$acct" ] || { echo "FAIL: the runner never named an account to fund"; ok=0; }
if [ "$ok" = 1 ]; then
  echo "the runner's public account: $acct"
  grep -a 'MUSTER-LP wallet_lez_setup' "$D/A.log" | tail -1 | sed 's/.*wallet_lez_setup /  wallet_lez_setup → /' | cut -c1-200
  echo "── the funder sends $AMOUNT native LEZ ──"
  infra/lez/localnet.sh fund "$acct" "$AMOUNT" 2>&1 | tail -3 | sed 's/^/  /' || ok=0
  echo "waiting for muster to read it through lez_core (up to 120s)..."
  seen=""
  for _ in $(seq 1 60); do
    seen=$(grep -aoE 'LEZFUND public balance \\?"?[0-9]+' "$D/A.log" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)
    [ "$seen" = "$AMOUNT" ] && break
    sleep 2
  done
  [ "$seen" = "$AMOUNT" ] && echo "muster reads $seen native LEZ at $acct" \
    || { echo "FAIL: muster read '${seen:-nothing}', not $AMOUNT"; ok=0; }
fi
echo "── the wallet's zone ──"
python3 -c "import json;print(json.load(open('$D/data/lez/config.json'))['sequencers'])" 2>/dev/null || echo "(no wallet config)"
echo "── QML load ──"
if grep -aiE 'qrc:/.*(error|TypeError|ReferenceError)|QQmlApplicationEngine failed|is not a type' "$D/A.log"; then echo "QML ERRORS ABOVE"; ok=0; else echo "no QML errors"; fi
[ "$ok" = 1 ] && echo "SUCCESS: on a v0.3 zone with no faucet, a funded account reads its balance through lez_core." \
  || echo "FAILED — see $D/A.log and $(infra/lez/localnet.sh status 2>&1 | head -1)"
ui_cleanup
[ "$ok" = 1 ] && { [ -n "${KEEP_LOGS:-}" ] && echo "logs kept in $D" || rm -rf "$D"; }
exit $((1-ok))
