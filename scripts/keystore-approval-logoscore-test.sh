#!/usr/bin/env bash
# Headless end to end, under logoscore 0.3.1 (exo-149.2 K2): an in-room Safe approval
# signed by keystore_module after a "human" approves it in evm_signer_cli. Never the
# standalone runner: its host cannot attribute muster's calls (K1 labbook).
#
#   anvil + the real Safe v1.4.1 (infra/anvil/devnet.sh, a port of its own)
#   one logoscore daemon: muster_module (this tree), its dependencies, keystore_module,
#     evm_keystore_cli (custodian) and evm_signer_cli (approver) — roles named by the
#     test with keystore_module.configure, an operator step muster never takes
#   evm_keystore_cli imports anvil owner 0's key; muster's own keystore never holds it
#   muster selects owner 0 (keystore_select, K5): one binding request, approved in the
#     signer, comes back as the account's F-14 binding ("valid")
#   muster: join a one-member room on a local node, disclose the Safe, propose a transfer,
#     contribute with NO key ref → routed through the selected account → "awaiting-approval"
#   evm_signer_cli: show the request (the SafeTx rendered by the keystore), approve
#   muster's intents tick: fetch, check each signature recovers to owner 0 over muster's
#     own hashes, publish through the same gates as an in-app approval, with the binding
#     → "collecting", and the approval reads as this member's (mine)
#
#   scripts/keystore-approval-logoscore-test.sh        # needs `make build` (the deps' modules)
#   KEEP_LOGS=1 ANVIL_PORT=18575 scripts/keystore-approval-logoscore-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh          # ui_local_config: a delivery node that needs no fleet
CACHE=(--accept-flake-config --extra-substituters https://cache.nix.logos.co/public
       --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=)
REV="${LOGOSCORE_REV:-0.3.1}"
PORT="${ANVIL_PORT:-18575}"
PW="muster-k2-test-only"           # the throwaway vault password the test types as the human
OWNER0_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil account 0
OWNER0=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
KSCLI=github:logos-co/logos-evm-keystore-cli/47554a1725fd654f0e4a19a9fa520492e28e2b2d
SIGNCLI=github:logos-co/logos-evm-signer-cli/861c2edafee23fd9322772d79c25a0ff5545e9e6

[ -e .run/runner ] || { echo "build the runner first: make build (it supplies muster's dependency modules)"; exit 1; }
DEPS=$(nix-store -qR "$(readlink -f .run/runner)" | grep -- '-plugin-dir-modules$' | head -1)
build() { nix build "$1" --no-link --print-out-paths "${CACHE[@]}" 2>/dev/null | tail -1; }
echo "building: logoscore $REV, muster_module (this tree), evm_keystore_cli, evm_signer_cli…"
L="$(build "github:logos-co/logos-logoscore-cli/$REV")/bin/logoscore"
MUSTER=$(build "./module#install")
KSI=$(build "$KSCLI#install")
SGI=$(build "$SIGNCLI#install")
for x in "$L" "$MUSTER" "$KSI" "$SGI"; do [ -e "$x" ] || { echo "build failed: $x"; exit 1; }; done

D=$(mktemp -d); mkdir -p "$D/mods" "$D/cfg" "$D/data"
for m in "$DEPS"/*/; do
  n=$(basename "$m"); case "$n" in capability_module|muster_module) continue ;; esac
  cp -rL --no-preserve=mode "$m" "$D/mods/"
done
for src in "$MUSTER" "$KSI" "$SGI"; do cp -rL --no-preserve=mode "$src"/modules/* "$D/mods/"; done

# ── anvil + the real Safe ──────────────────────────────────────────────────────────
echo "anvil + Safe v1.4.1 on :$PORT…"
ANVIL_PORT=$PORT setsid nix shell nixpkgs#foundry nixpkgs#jq -c infra/anvil/devnet.sh >"$D/devnet.log" 2>&1 &
for _ in $(seq 1 120); do grep -q 'SAFE_ADDR=' "$D/devnet.log" && break; sleep 2; done
grep -q 'SAFE_ADDR=' "$D/devnet.log" || { echo "devnet did not come up"; tail -5 "$D/devnet.log"; exit 1; }

lc() { timeout 60 "$L" --config-dir "$D/cfg" "$@" 2>&1 | tail -1; }
res() { python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"])
except Exception: print("")'; }
CFG=$(ui_local_config)
MUSTER_LP_DEBUG=1 MUSTER_KEYSTORE_BACKEND=interim MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_DATA_DIR="$D/data" \
  setsid "$L" --config-dir "$D/cfg" daemon -m "$D/mods" --persistence-path "$D/cfg/data" >"$D/daemon.log" 2>&1 &
DPID=$!
cleanup() {
  lc stop >/dev/null
  kill -9 -"$DPID" 2>/dev/null; kill -9 "$DPID" 2>/dev/null
  pkill -f "anvil .*--port $PORT" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 20); do lc status >/dev/null && break; sleep 1; done

ok=1
step() { echo "── $*"; }
step "load"; for m in muster_module evm_keystore_cli evm_signer_cli; do lc load-module "$m" | cut -c1-140; done
step "roles (operator)"; lc call keystore_module configure \
  '{"approvers":["evm_signer_ui","evm_signer_cli"],"custodians":["evm_keystore_ui","evm_keystore_cli"]}' | res
step "custodian imports owner 0"; lc call evm_keystore_cli import_private_key "$OWNER0_KEY" "$PW" | res
lc call muster_module settings >/dev/null    # loads the module's settings first: a set_setting before that saves defaults
lc call muster_module set_setting rpc "http://127.0.0.1:$PORT" >/dev/null
for _ in 1 2 3; do lc call muster_module keystore_status >/dev/null; sleep 2; done       # the probe sees the account
step "keystore_status"; lc call muster_module keystore_status | res

approve_in_signer() {   # $1 = handle: what a person does in the signer
  lc call evm_signer_cli refresh >/dev/null
  local show bid
  show=$(lc call evm_signer_cli show "$1" | res)
  echo "$show" | python3 -c 'import sys,json
s=json.load(sys.stdin); print("\n".join((s.get("text") or json.dumps(s))[:2400].splitlines()[:44]))' 2>/dev/null
  bid=$(echo "$show" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("bundle_id",""))')
  lc call evm_signer_cli approve "$1" "$bid" "$PW" | res | cut -c1-200
}

step "select owner 0 for approvals (K5)"
SEL=$(lc call muster_module keystore_select "$OWNER0" | res); echo "$SEL"
BH=$(echo "$SEL" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("handle",""))')
[ -n "$BH" ] || { echo "FAIL: no binding request"; ok=0; }
approve_in_signer "$BH"
bstate=""
for _ in $(seq 1 30); do
  lc call muster_module keystore_requests >/dev/null           # the pump runs on this read too
  bstate=$(lc call muster_module keystore_status | res | python3 -c 'import sys,json; print(json.load(sys.stdin).get("binding",""))')
  [ "$bstate" = "valid" ] && break; sleep 2
done
echo "binding: $bstate"
[ "$bstate" = "valid" ] || { echo "FAIL: the account's binding never became valid"; ok=0; }

step "room"; lc call muster_module coordinate_join "/muster/1/k2-$(date +%s)/proto" | res | cut -c1-120
ACCT=$(lc call muster_module describe | res | python3 -c 'import sys,json
s=json.load(sys.stdin); print(json.dumps({"family":s.get("family","evm.safe"),"chain":s["chain"],"address":s["safe"],
  "label":s.get("label",""),"signers":s["owners"],"threshold":s["threshold"]}))')
lc call muster_module coordinate_disclose_account "$ACCT" | res | cut -c1-120
lc call muster_module coordinate_set_policy safe | res | cut -c1-120
ID=$(lc call muster_module coordinate_propose '{"to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":1,"nonce":0}' | res)
echo "intent: $ID"

step "contribute with no key ref: routed through the selected account"
r=$(lc call muster_module coordinate_contribute "$ID" "" "" | res); echo "$r"
[ "$r" = "awaiting-approval" ] || { echo "FAIL: expected awaiting-approval"; ok=0; }
H=$(lc call muster_module keystore_requests | res | python3 -c 'import sys,json
rs=[r for r in json.load(sys.stdin)["requests"] if r.get("kind")=="approval"]; print(rs[-1]["handle"] if rs else "")')
echo "handle: $H"

step "the human, in evm_signer_cli"
approve_in_signer "$H"

step "muster's tick publishes"
pub=""
for _ in $(seq 1 30); do
  lc call muster_module coordinate_intents >/dev/null
  pub=$(lc call muster_module keystore_requests | res | python3 -c 'import sys,json
rs=json.load(sys.stdin)["requests"]; print(next((r.get("published","") for r in rs if r.get("kind")=="approval" and r.get("published")), ""))')
  [ -n "$pub" ] && break; sleep 2
done
lc call muster_module keystore_requests | res
echo "published: $pub"
[ "$pub" = "collecting" ] || { echo "FAIL: expected the approval to publish as collecting"; ok=0; }
MINE=$(lc call muster_module coordinate_intents | res | python3 -c 'import sys,json
for i in json.load(sys.stdin):
  print("intent", i.get("id","")[:12], i.get("state"), "approvals", i.get("approvals"), i.get("approvers") or "", file=sys.stderr)
  print("yes" if i.get("approvedByMe") else "no")' | tail -1)
echo "approved by me: $MINE"
[ "$MINE" = "yes" ] || { echo "FAIL: the approval does not read as this member's"; ok=0; }
grep -a -q 'intent/.*/binding/' "$D/daemon.log" 2>/dev/null || true

if [ "$ok" = 1 ]; then
  echo "PASS: selected owner 0 (binding valid); its human-approved signature published as collecting, read as mine"
  [ -n "${KEEP_LOGS:-}" ] && echo "logs: $D" || rm -rf "$D"
  exit 0
fi
echo "FAIL — logs kept at $D"; grep -a 'MUSTER-LP keystore' "$D/daemon.log" | tail -5
exit 1
