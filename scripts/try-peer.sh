#!/usr/bin/env bash
# Launch one peer for the two-instance tour (docs/runbooks/client-tour.md), seeded for
# everything scripts/try-infra.sh brought up. Run one per terminal:
#
#   scripts/try-peer.sh alice [--fresh] [--lez]
#   scripts/try-peer.sh bob   [--fresh] [--lez | --lez-fund]
#   scripts/try-peer.sh carol [--fresh]           a third member, if a step wants one
#
#   --fresh   wipe this peer first (its identity, saved Settings, contacts and audit
#             files) so the seeding below applies. Seeding is honoured only when an
#             identity is first minted, and a saved Settings value beats the
#             environment. Use it the first time, and whenever the infra is new.
#   --lez     use the real LEZ wallet (lez_core) on the public testnet, kept in
#             .run/try/<peer>-lez. clean-peer and --fresh leave it alone, so a funded
#             wallet survives. Without it, LEZ runs on the in-process fake chain.
#   --lez-fund  --lez, and fund that wallet's private balance as a person would: one
#             claim from the testnet faucet into its public account, then a shield of
#             all of it to its own key node (a proof of minutes). Watch for
#             "LEZFUND funded" in the log. Once per wallet is enough.
#
# Seeds: anvil key 0/1/2 as the peer's own key (a Safe owner; its Bitcoin key pays from
# the funded wpkh address; its chat id is deterministic, so Alice, Bob and Carol already
# know each other), the RPC and Bitcoin node from .run/try/env, the live Logos fleet
# (logos.test; TRY_FLEET=logos.dev for the other), the audit folder
# .run/try/<peer>-audit, and invites only from the last ten minutes.
# The module's MUSTER-LP lines and the UI's own log go to .run/try/<peer>.log.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
STATE=$ROOT/.run/try
PEER=${1:-}; shift || true
FRESH=0; LEZ=0; FUND=0
for a in "$@"; do
  case "$a" in --fresh) FRESH=1 ;; --lez) LEZ=1 ;; --lez-fund) LEZ=1; FUND=1 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac
done
case "$PEER" in
  alice) KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 ;;
  bob)   KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d ;;
  carol) KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a ;;
  *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

RUNNER=.run/runner/bin/muster-ui
[ -x "$RUNNER" ] || { echo "build the runner first: make build"; exit 1; }
[ -f "$STATE/env" ] || { echo "no infra yet: scripts/try-infra.sh up (or continue without chains)"; }
# shellcheck disable=SC1091
[ -f "$STATE/env" ] && . "$STATE/env"

DIR=$ROOT/.run/$PEER
if [ $FRESH = 1 ]; then
  echo "→ fresh $PEER: removing .run/$PEER and its audit folder"
  rm -rf "$DIR" "$STATE/$PEER-audit"
elif compgen -G "$DIR/module_data/muster_module/*/settings.json" >/dev/null; then
  echo "note: $PEER has saved Settings, which beat the seeding here; use --fresh to reset"
fi
mkdir -p "$DIR" "$STATE/$PEER-audit"

FLEET=infra/fleets/${TRY_FLEET:-logos.test}.json
[ -f "$FLEET" ] || { echo "no fleet config $FLEET (infra/fleets/refresh.sh)"; exit 1; }
CFG=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["delivery_createNode_config"]))' "$FLEET")
LEZ_ENV=()
if [ $LEZ = 1 ]; then
  mkdir -p "$STATE/$PEER-lez"
  LEZ_ENV=(MUSTER_LEZ_REAL=1 "MUSTER_DATA_DIR=$STATE/$PEER-lez")
  [ $FUND = 1 ] && LEZ_ENV+=(MUSTER_AUTOLEZFUND=1)
fi

echo "→ $PEER: user dir .run/$PEER · RPC ${TRY_RPC:-http://127.0.0.1:8545} · Bitcoin node ${TRY_BTC_RPC:-none}$([ $LEZ = 1 ] && echo " · real LEZ wallet")$([ $FUND = 1 ] && echo ", funding it")"
echo "  log: .run/try/$PEER.log"
exec env \
  MUSTER_DEV_SECP_KEY="$KEY" \
  MUSTER_RPC="${TRY_RPC:-http://127.0.0.1:8545}" \
  ${TRY_BTC_RPC:+MUSTER_BTC_RPC="$TRY_BTC_RPC"} \
  MUSTER_DELIVERY_CONFIG="$CFG" \
  MUSTER_AUDIT_DIR="$STATE/$PEER-audit" \
  MUSTER_INVITES_SINCE=$(( $(date +%s) - 600 )) \
  MUSTER_LP_DEBUG=1 \
  QT_FORCE_STDERR_LOGGING=1 \
  LOGOS_INSTANCE_ID="try$PEER" \
  "${LEZ_ENV[@]}" \
  "$RUNNER" --user-dir "$DIR" >>"$STATE/$PEER.log" 2>&1
