#!/usr/bin/env bash
# The zone's FUNDER (exo-eb6.4.5): one wallet of LEZ's own CLI per zone, whose single public
# account someone holding native LEZ funds once. Every live run draws from it — LEZ v0.3.0
# has no faucet, so this is the one account to ask the Logos team to fund. muster never sees
# its key: it stays in the CLI's wallet home.
#
#   infra/lez/funder.sh [--zone Z] account             the account to fund (base58 and hex),
#                                                      made on first use
#   infra/lez/funder.sh [--zone Z] balance             what it holds, in base units
#   infra/lez/funder.sh [--zone Z] fund <id> <amount>  send native LEZ (id: hex or base58)
#   infra/lez/funder.sh [--zone Z] deploy <prog.bin>   deploy a v0.3 program through
#                                                      program_loader, the funder paying;
#                                                      prints "program account: <b58> (hex <hex>)"
#
# Zones (--zone, or MUSTER_LEZ_ZONE; default local):
#   local    infra/lez/localnet.sh's zone at http://127.0.0.1:3040, whose funder genesis
#            funds (its wallet home is the local checkout's .muster-funder);
#   testnet  https://testnet.lez.logos.co, its wallet home ~/.cache/muster/lez-funder-testnet;
#   <url>    any other v0.3 sequencer, its wallet home ~/.cache/muster/lez-funder-<host>.
# MUSTER_LEZ_FUNDER_HOME overrides the wallet home. The CLI is the one localnet.sh builds
# (`infra/lez/localnet.sh build`). The wallet's password is MUSTER_LEZ_FUNDER_PASSWORD
# (default "muster-funder"): it guards the key file in the home, which is the user's own.
#
# What a live run costs, from the local zone at genesis' base fee (8, the testnet's too on
# 2026-10-02), so an ask can name an amount: a public transfer pays 2 968; deploying the
# multisig port 3 459 264; a multisig create ~218 000, a vote ~456 000, a refused transaction
# its whole gas limit (~16 000 000); private transactions (shield, private transfer) pay
# nothing. 1 LEZ = 10^9 base units. The e2e tests send what MUSTER_LEZ_E2E_FUND says to
# each account they make (default 1 LEZ on the local zone; a key they drop keeps it).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ZONE="${MUSTER_LEZ_ZONE:-local}"
if [ "${1:-}" = "--zone" ]; then ZONE="$2"; shift 2; fi
case "${ZONE%/}" in                     # the two zones by their URLs too
  http://127.0.0.1:3040|http://localhost:3040) ZONE=local ;;
  https://testnet.lez.logos.co) ZONE=testnet ;;
esac
DIR="${MUSTER_LEZ_DIR:-$HOME/.cache/muster/lez-v0.3.0}"
WALLET="$DIR/target/release/wallet"
PASSWORD="${MUSTER_LEZ_FUNDER_PASSWORD:-muster-funder}"
case "$ZONE" in
  local)   URL="http://127.0.0.1:3040"; HOMEDIR="${MUSTER_LEZ_FUNDER_HOME:-$DIR/.muster-funder}" ;;
  testnet) URL="https://testnet.lez.logos.co"; HOMEDIR="${MUSTER_LEZ_FUNDER_HOME:-$HOME/.cache/muster/lez-funder-testnet}" ;;
  http://*|https://*)
           URL="$ZONE"; host="${ZONE#*://}"; host="${host%%/*}"; host="${host//[^A-Za-z0-9.-]/_}"
           HOMEDIR="${MUSTER_LEZ_FUNDER_HOME:-$HOME/.cache/muster/lez-funder-$host}" ;;
  *) echo "a zone is local, testnet or a sequencer URL, not '$ZONE'" >&2; exit 2 ;;
esac
[ -x "$WALLET" ] || { echo "no LEZ wallet CLI at $WALLET: run 'infra/lez/localnet.sh build' first" >&2; exit 1; }
w() { LEE_WALLET_HOME_DIR="$HOMEDIR" "$WALLET" "$@"; }

answers() {  # the sequencer answers JSON-RPC
  curl -s -m 15 -X POST "$URL" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getLastBlockId","params":[]}' | grep -q '"result"'
}
b58() {  # a public account id, hex or base58 → base58
  python3 - "$1" <<'EOF'
import sys
s = sys.argv[1].removeprefix("Public/").removeprefix("0x")
if len(s) == 64 and all(c in "0123456789abcdefABCDEF" for c in s):
    raw = bytes.fromhex(s); n = int.from_bytes(raw, "big"); out = ""
    a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    while n: n, r = divmod(n, 58); out = a[r] + out
    s = "1" * (len(raw) - len(raw.lstrip(b"\0"))) + out
print(s)
EOF
}
hex() {  # base58 → hex (32 bytes)
  python3 -c '
import sys
a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; n = 0
for c in sys.argv[1]: n = n * 58 + a.index(c)
print(n.to_bytes(32, "big").hex())' "$1"
}

funder_id() {  # the funder's public account (base58), made on first use
  [ -s "$HOMEDIR/funder.id" ] && { cat "$HOMEDIR/funder.id"; return; }
  if [ "$ZONE" = local ]; then
    echo "the local zone's funder is made by its genesis: run 'infra/lez/localnet.sh' first" >&2; exit 1
  fi
  answers || { echo "$URL does not answer: the CLI checks in with the sequencer before any command" >&2; exit 1; }
  mkdir -p "$HOMEDIR"; chmod 700 "$HOMEDIR"
  python3 - "$DIR/lez/wallet/configs/debug/wallet_config.json" "$HOMEDIR/wallet_config.json" "$URL" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1])); c["sequencers"] = [{"sequencer_addr": sys.argv[3]}]
json.dump(c, open(sys.argv[2], "w"), indent=2)
EOF
  local out id
  # the first command sets the wallet up: it asks for a password on stdin
  out=$(printf '%s\n' "$PASSWORD" | w account new public 2>&1) || true
  id=$(echo "$out" | grep -oE 'Public/[1-9A-HJ-NP-Za-km-z]{32,44}' | head -1 | sed 's|Public/||')
  [ -n "$id" ] || { echo "could not read the funder's account from: $out" >&2; exit 1; }
  echo "$id" > "$HOMEDIR/funder.id"
  echo "$id"
}

balance() {  # the funder's native balance, base units ("0" when it holds nothing)
  curl -s -m 15 -X POST "$URL" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountBalance\",\"params\":[\"$(funder_id)\"]}" |
    python3 -c 'import json,sys; r=json.load(sys.stdin).get("result"); print(r if r is not None else "unknown")'
}

case "${1:-account}" in
  account)
    id=$(funder_id)
    echo "funder on $URL: Public/$id (hex $(hex "$id")), holding $(balance)" ;;
  balance) balance ;;
  fund)
    [ $# -eq 3 ] || { echo "usage: $0 [--zone Z] fund <public account id, hex or base58> <amount>" >&2; exit 2; }
    answers || { echo "$URL does not answer" >&2; exit 1; }
    w auth-transfer send --amount "$3" --from "Public/$(funder_id)" --to "Public/$(b58 "$2")" ;;
  deploy)
    [ $# -eq 2 ] && [ -f "$2" ] || { echo "usage: $0 [--zone Z] deploy <program.bin (risc0's R0BF)>" >&2; exit 2; }
    answers || { echo "$URL does not answer" >&2; exit 1; }
    # program_loader writes the user ELF in 96 KiB segments, one fresh account each, then a
    # header pointing at them; the header's id is the program's account id
    n=$(python3 - "$2" <<'EOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"R0BF", "not a risc0 program binary (R0BF)"
hlen = struct.unpack_from("<I", b, 8)[0]
ulen = struct.unpack_from("<I", b, 12 + hlen)[0]
print(-(-ulen // (96 * 1024)))
EOF
) || exit 1
    payer=$(funder_id)
    newacct() { w account new public 2>&1 | grep -oE 'Public/[1-9A-HJ-NP-Za-km-z]{32,44}' | head -1; }
    header=$(newacct); segs=()
    for _ in $(seq 1 "$n"); do segs+=("$(newacct)"); done
    [ -n "$header" ] && [ ${#segs[@]} -eq "$n" ] || { echo "could not make the deploy accounts" >&2; exit 1; }
    w program-loader deploy --elf "$2" --header "$header" --segments "${segs[@]}" --payer "Public/$payer" >&2 || exit 1
    id="${header#Public/}"
    echo "program account: $id (hex $(hex "$id"))" ;;
  *) echo "usage: $0 [--zone local|testnet|<url>] account | balance | fund <id> <amount> | deploy <program.bin>" >&2; exit 2 ;;
esac
