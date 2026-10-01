#!/usr/bin/env bash
# A local LEZ standalone sequencer on 127.0.0.1:3040 — by default v0.3.0, the line the
# public testnet runs since 2026-09-30 (exo-eb6.4).
#
#   infra/lez/localnet.sh                   build if needed (first run: ~15 min), then start
#   infra/lez/localnet.sh build             build only
#   infra/lez/localnet.sh fund <id> <amt>   send native LEZ from the genesis funder (v0.3)
#   infra/lez/localnet.sh status            the chain's height, the funder and its balance
#   infra/lez/localnet.sh stop              stop it
#
# A FRESH chain each start (the database is wiped). 15s blocks, RISC0_DEV_MODE=1.
#
# Funding on v0.3. LEZ v0.3.0 has no faucet: native LEZ reaches an account at genesis,
# over the bridge, or by a transfer from an account that holds some. So this script keeps
# a FUNDER: a wallet of LEZ's own CLI (`wallet`, in $DIR/.muster-funder) whose public
# account the genesis it writes funds. `fund` sends from it, exactly as a person holding
# native LEZ would; muster's wallet never sees the funder's keys. <id> is a public account
# id, hex (as lez_core prints it) or base58.
#
# MUSTER_LEZ_VERSION=v0.2.4 runs the old line, for the LEZ multisig and FROST e2e tests
# until they move to v0.3 (exo-b87, exo-9ed): it starts from LEZ's debug config, and
# has no funder. Then deploy the multisig program and run the live test in one go:
#   MUSTER_LEZ_MULTISIG_BIN=<lez-multisig>/target/riscv32im-risc0-zkvm-elf/docker/multisig.bin \
#     nim r … module/tests/lez_multisig_live_e2e.nim http://127.0.0.1:3040 15
# Build that guest with `make build` in logos-co/lez-multisig (PR #45 or later): it
# reproduces ImageID 2ced3d30…d4c7, the program deployed on the v0.2.4 testnet.
#
# System needs, the traps found the expensive way (docs/labbook/lez-multisig-versions.md):
#   - libclang: RocksDB's bindgen. LIBCLANG_PATH, else nixpkgs#libclang.lib is used.
#   - r0vm 3.0.5 (both lines): genesis runs in risc0's executor, and without it the start
#     panics with a bare "No such file or directory". On PATH, or in
#     ~/.cache/muster/risc0/bin; get it with `rzup install r0vm 3.0.5`, or
#     `cargo install risc0-r0vm --version 3.0.5 --locked --root <dir>`.
#   - Rust: the LEZ repo's rust-toolchain.toml pins it (v0.3.0: 1.98.1; v0.2.4: 1.94.0),
#     and rustup fetches it.
#   - A C++ compiler: RocksDB and risc0's circuit kernels compile C++. With no system g++,
#     nixpkgs#gcc is put first on PATH. Its wrapper stamps nix glibc's loader on the
#     binaries, which does not search /lib64, so they would fail with "libstdc++.so.6:
#     cannot open shared object file": the script adds nixpkgs#gcc.cc.lib to their rpath.
# The v0.2.4 build was verified from scratch on a second machine 2026-09-25.
set -euo pipefail
VERSION="${MUSTER_LEZ_VERSION:-v0.3.0}"
DIR="${MUSTER_LEZ_DIR:-$HOME/.cache/muster/lez-$VERSION}"
RUN="$DIR/.muster-run"            # the generated config, the database, the log, the pid
FUNDER="$DIR/.muster-funder"      # the funder's wallet home (v0.3)
PIDFILE="$RUN/sequencer.pid"
LOG="$RUN/sequencer.log"
URL="http://127.0.0.1:3040"
SEQ="$DIR/target/release/sequencer_service"
WALLET="$DIR/target/release/wallet"
GENESIS_BALANCE="${MUSTER_LEZ_GENESIS:-1000000000000000}"
[ "$VERSION" = v0.2.4 ] && { RUN="$DIR/lez/sequencer/service"; PIDFILE="$DIR/.sequencer.pid"; LOG="$DIR/sequencer.log"; }

rpc() {  # method [params-json] → the JSON-RPC result
  curl -s -m 10 -X POST "$URL" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-{\}}}" |
    python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("result")))'
}
running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
funder_wallet() { LEE_WALLET_HOME_DIR="$FUNDER" "$WALLET" "$@"; }
b58() {  # a public account id, hex or base58 → base58 (32 bytes, leading zeros as '1')
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

toolchain() {
  if ! command -v g++ >/dev/null; then
    export PATH="$(nix build --no-link --print-out-paths nixpkgs#gcc)/bin:$PATH"
    GCCLIB="$(nix build --no-link --print-out-paths nixpkgs#gcc.cc.lib)/lib"
  fi
  [ -n "${LIBCLANG_PATH:-}" ] || export LIBCLANG_PATH="$(nix build --no-link --print-out-paths nixpkgs#libclang.lib)/lib"
}
r0vm_on_path() {
  command -v r0vm >/dev/null && return 0
  [ -x "$HOME/.cache/muster/risc0/bin/r0vm" ] && { export PATH="$HOME/.cache/muster/risc0/bin:$PATH"; return 0; }
  echo "r0vm 3.0.5 is not on PATH (rzup install r0vm 3.0.5)" >&2; exit 1
}

build() {
  if [ ! -d "$DIR/.git" ]; then
    mkdir -p "$(dirname "$DIR")"
    git clone -q --depth 1 --branch "$VERSION" https://github.com/logos-blockchain/logos-execution-zone "$DIR"
  fi
  local pkgs=(-p sequencer_service); [ "$VERSION" = v0.2.4 ] || pkgs+=(-p wallet)
  if [ ! -x "$SEQ" ] || { [ "$VERSION" != v0.2.4 ] && [ ! -x "$WALLET" ]; }; then
    echo "building the $VERSION standalone sequencer$([ "$VERSION" = v0.2.4 ] || echo " and wallet CLI") (first run: ~15 min)…"
    toolchain
    (cd "$DIR" && cargo build --release --features standalone "${pkgs[@]}")
    if [ -n "${GCCLIB:-}" ]; then
      for b in "$SEQ" "$WALLET"; do
        [ -x "$b" ] && nix shell nixpkgs#patchelf -c patchelf --add-rpath "$GCCLIB" "$b"
      done
    fi
  fi
}

funder_id() {  # the funder's public account (base58), made once per checkout
  [ -s "$FUNDER/funder.id" ] && { cat "$FUNDER/funder.id"; return; }
  mkdir -p "$FUNDER"
  python3 - "$DIR/lez/wallet/configs/debug/wallet_config.json" "$FUNDER/wallet_config.json" "$URL" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1])); c["sequencers"] = [{"sequencer_addr": sys.argv[3]}]
json.dump(c, open(sys.argv[2], "w"), indent=2)
EOF
  local out id
  out=$(funder_wallet account new public 2>&1) || { echo "$out" >&2; exit 1; }
  id=$(echo "$out" | grep -oE 'Public/[1-9A-HJ-NP-Za-km-z]{32,44}' | head -1 | sed 's|Public/||')
  [ -n "$id" ] || { echo "could not read the funder's account from: $out" >&2; exit 1; }
  echo "$id" > "$FUNDER/funder.id"
  echo "$id"
}

start() {
  r0vm_on_path
  build
  if running; then echo "already running (pid $(cat "$PIDFILE")); '$0 stop' first for a fresh chain"; exit 0; fi
  local cfg
  if [ "$VERSION" = v0.2.4 ]; then
    cd "$RUN"; rm -rf rocksdb; cfg=configs/debug/sequencer_config.json
  else
    local fid; fid=$(funder_id)
    rm -rf "$RUN"; mkdir -p "$RUN"; cfg="$RUN/sequencer_config.json"
    # LEZ's debug config, with ONE genesis supply account: the funder's
    python3 - "$DIR/lez/sequencer/service/configs/debug/sequencer_config.json" "$cfg" "$RUN" "$fid" "$GENESIS_BALANCE" <<'EOF'
import json, sys
src, dst, home, fid, bal = sys.argv[1:6]
c = json.load(open(src))
c["home"] = home
c["genesis"] = [{"supply_account": {"account_id": fid, "balance": int(bal)}}]
json.dump(c, open(dst, "w"), indent=2)
EOF
    cd "$RUN"
  fi
  RISC0_DEV_MODE=1 RUST_LOG=info nohup "$SEQ" "$cfg" > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 90); do
    if grep -q "RPC server started" "$LOG" 2>/dev/null; then
      echo "LEZ $VERSION sequencer on $URL (log: $LOG)"
      [ "$VERSION" = v0.2.4 ] || echo "funder: Public/$(cat "$FUNDER/funder.id"), $GENESIS_BALANCE at genesis — '$0 fund <id> <amount>'"
      exit 0
    fi
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null || break
    sleep 1
  done
  echo "the sequencer did not start; see $LOG" >&2
  exit 1
}

case "${1:-up}" in
  stop)
    if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then echo "stopped"; else echo "not running"; fi
    rm -f "$PIDFILE" ;;
  build) build ;;
  status)
    running || { echo "not running"; exit 1; }
    echo "LEZ $VERSION on $URL, block $(rpc getLastBlockId)"
    [ -s "$FUNDER/funder.id" ] && echo "funder Public/$(cat "$FUNDER/funder.id"): $(funder_wallet account get --account-id "Public/$(cat "$FUNDER/funder.id")" 2>/dev/null | tail -1)" ;;
  fund)
    [ "$VERSION" = v0.2.4 ] && { echo "v0.2.4 has no funder here: it has the pinata faucet" >&2; exit 2; }
    [ $# -eq 3 ] || { echo "usage: $0 fund <public account id, hex or base58> <amount>" >&2; exit 2; }
    running || { echo "not running: '$0' first" >&2; exit 1; }
    to=$(b58 "$2")
    funder_wallet auth-transfer send --amount "$3" --from "Public/$(cat "$FUNDER/funder.id")" --to "Public/$to" ;;
  up) start ;;
  *) echo "usage: $0 [up | build | fund <id> <amount> | status | stop]" >&2; exit 2 ;;
esac
