#!/usr/bin/env bash
# A local LEZ standalone sequencer on 127.0.0.1:3040 — by default v0.3.0, the line the
# public testnet runs since 2026-09-30 (exo-eb6.4).
#
#   infra/lez/localnet.sh                   build if needed (first run: ~15 min), then start
#   infra/lez/localnet.sh build             build only
#   infra/lez/localnet.sh fund <id> <amt>   send native LEZ from the genesis funder (v0.3)
#   infra/lez/localnet.sh deploy <prog.bin> deploy a program (risc0's .bin) through program_loader,
#                                           the funder paying; prints its program account id (v0.3)
#   (fund and deploy are infra/lez/funder.sh's, which does the same on any zone's funder)
#   infra/lez/localnet.sh status            the chain's height, the funder and its balance
#   infra/lez/localnet.sh stop              stop it
#
# A FRESH chain each start (the database is wiped). 15s blocks, RISC0_DEV_MODE=1, so the zone
# accepts dev-mode receipts only. MUSTER_LEZ_REAL_PROOFS=1 starts it without dev mode: it then
# verifies real receipts, and every private transaction sent to it must be really proved
# (minutes each; RFP-005 P.1, exo-0d3.15).
#
# Funding on v0.3. LEZ v0.3.0 has no faucet: native LEZ reaches an account at genesis,
# over the bridge, or by a transfer from an account that holds some. So this script keeps
# a FUNDER: a wallet of LEZ's own CLI (`wallet`, in $DIR/.muster-funder) whose public
# account the genesis it writes funds. `fund` sends from it, exactly as a person holding
# native LEZ would; muster's wallet never sees the funder's keys. <id> is a public account
# id, hex (as lez_core prints it) or base58.
#
# MUSTER_LEZ_VERSION=v0.4.0-rc3 runs the 0.4 line (transactional actors, roadmap M3): its
# sequencer is set up once into a home (`setup`, LEZ's networks/local.json) and then started
# (`start`), and the funder is LEZ's own published local test key, which that genesis funds; the
# funder's wallet takes its password from LEE_WALLET_PASSWORD. Deploys are --immutable.
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
#   - libpcsclite (v0.3): the wallet CLI links Keycard support. Without a system one
#     (pkg-config libpcsclite), nixpkgs#pcsclite is used and added to the rpath too.
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

rpc() {  # method [params-json] → the JSON-RPC result, "null" when there is no answer
  { curl -s -m 10 -X POST "$URL" -H 'content-type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-{\}}}" || true; } |
    python3 -c '
import json, sys
try: print(json.dumps(json.load(sys.stdin).get("result")))
except Exception: print("null")'
}
running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
funder_wallet() { LEE_WALLET_HOME_DIR="$FUNDER" LEE_WALLET_PASSWORD="${MUSTER_LEZ_FUNDER_PASSWORD:-muster-funder}" "$WALLET" "$@"; }
is04() { case "$VERSION" in v0.4*) return 0 ;; *) return 1 ;; esac; }
# v0.4: the local Bedrock's funding key (LEZ's Justfile), and LEZ's published local test key,
# which networks/local.json's genesis funds: the funder
BEDROCK_FUNDING_KEY=2e03b2eff5a45478e7e79668d2a146cf2c5c7925bce927f2b1c67f2ab4fc0d26
FUNDER04_KEY=7f273098f25b71e6c005a9519f2678da8d1c7f01f6a27778e2d9948abdf901fb
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
    # one output each (^out): nixpkgs#gcc alone also prints its man page's path
    export PATH="$(nix build --no-link --print-out-paths 'nixpkgs#gcc^out')/bin:$PATH"
    GCCLIB="$(nix build --no-link --print-out-paths 'nixpkgs#gcc.cc^lib')/lib"
  fi
  # A system libclang first: nixpkgs' needs a glibc as new as nixpkgs' own, and fails on an
  # older host with "GLIBC_ABI_GNU2_TLS not found" (Ubuntu 24.04, glibc 2.39).
  if [ -z "${LIBCLANG_PATH:-}" ]; then
    local sys; sys="$(ls -d /usr/lib/llvm-*/lib 2>/dev/null | sort -V | tail -1)"
    if [ -n "$sys" ] && ls "$sys"/libclang*.so* >/dev/null 2>&1; then export LIBCLANG_PATH="$sys"
    else export LIBCLANG_PATH="$(nix build --no-link --print-out-paths 'nixpkgs#libclang^lib')/lib"; fi
  fi
  # v0.3's wallet CLI links Keycard support (pcsc-sys): libpcsclite, found by pkg-config.
  # A host with the runtime library but not its dev package links against its own copy
  # through a generated .pc, for the same glibc reason as libclang.
  local syspcsc=/usr/lib/x86_64-linux-gnu/libpcsclite.so.1
  if [ "$VERSION" != v0.2.4 ] && ! pkg-config --exists libpcsclite 2>/dev/null && [ -e "$syspcsc" ]; then
    local pc="$DIR/.muster-pcsc"; mkdir -p "$pc"
    ln -sf "$syspcsc" "$pc/libpcsclite.so"
    printf 'Name: libpcsclite\nDescription: host PC/SC\nVersion: 2\nLibs: -L%s -lpcsclite\nCflags:\n' "$pc" > "$pc/libpcsclite.pc"
    export PKG_CONFIG_PATH="$pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi
  if [ "$VERSION" != v0.2.4 ] && ! pkg-config --exists libpcsclite 2>/dev/null; then
    export PATH="$(nix build --no-link --print-out-paths 'nixpkgs#pkg-config^out')/bin:$PATH"
    export PKG_CONFIG_PATH="$(nix build --no-link --print-out-paths 'nixpkgs#pcsclite^dev')/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    PCSCLIB="$(nix build --no-link --print-out-paths 'nixpkgs#pcsclite^lib')/lib"
  fi
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
    local rp="${GCCLIB:-}${PCSCLIB:+${GCCLIB:+:}$PCSCLIB}"
    if [ -n "$rp" ]; then
      for b in "$SEQ" "$WALLET"; do
        [ -x "$b" ] && nix shell nixpkgs#patchelf -c patchelf --add-rpath "$rp" "$b"
      done
    fi
  fi
}

# launch <config> <home> <log> <pidfile> — a sequencer in the background, from <home>;
# returns once its RPC is up, non-zero if it never comes up
launch() {
  # the subshell BECOMES the sequencer (exec), its output in the log: nothing is left
  # holding a caller's pipe open (a `$(…)` around this would otherwise never return)
  local args=("$1"); is04 && args=(start "$1")      # v0.4: <config> is the set-up home
  if [ "${MUSTER_LEZ_REAL_PROOFS:-0}" = 1 ]; then
    ( cd "$2" && unset RISC0_DEV_MODE && RUST_LOG=info exec nohup "$SEQ" "${args[@]}" ) > "$3" 2>&1 < /dev/null &
  else
    ( cd "$2" && RISC0_DEV_MODE=1 RUST_LOG=info exec nohup "$SEQ" "${args[@]}" ) > "$3" 2>&1 < /dev/null &
  fi
  echo $! > "$4"
  for _ in $(seq 1 90); do
    [ "$(rpc getLastBlockId)" != null ] && return 0     # the RPC answers: up (any version's log)
    kill -0 "$(cat "$4")" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

config_with() {  # <dst> <home> [<funder id> <balance>] — LEZ's debug config, re-homed;
  # with a funder, ONE genesis supply account: the funder's
  python3 - "$DIR/lez/sequencer/service/configs/debug/sequencer_config.json" "$@" <<'EOF'
import json, sys
src, dst, home = sys.argv[1:4]
c = json.load(open(src))
c["home"] = home
if len(sys.argv) > 5:
    c["genesis"] = [{"supply_account": {"account_id": sys.argv[4], "balance": int(sys.argv[5])}}]
json.dump(c, open(dst, "w"), indent=2)
EOF
}

funder_id() {  # the funder's public account (base58), made once per checkout
  [ -s "$FUNDER/funder.id" ] && { cat "$FUNDER/funder.id"; return; }
  # LEZ's CLI checks in with a sequencer before any command, even making an account, and
  # the genesis that funds the account must name it first: so the account is made once,
  # on a throwaway chain from LEZ's debug config, before the real one starts
  echo "making the funder's account, once (on a throwaway chain: LEZ's CLI needs a sequencer)…" >&2
  local boot="$DIR/.muster-boot"
  rm -rf "$boot" "$FUNDER"; mkdir -p "$boot" "$FUNDER"
  config_with "$boot/sequencer_config.json" "$boot"
  launch "$boot/sequencer_config.json" "$boot" "$boot/sequencer.log" "$boot/pid" \
    || { echo "the throwaway sequencer did not start; see $boot/sequencer.log" >&2; exit 1; }
  python3 - "$DIR/lez/wallet/configs/debug/wallet_config.json" "$FUNDER/wallet_config.json" "$URL" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1])); c["sequencers"] = [{"sequencer_addr": sys.argv[3]}]
json.dump(c, open(sys.argv[2], "w"), indent=2)
EOF
  local out id
  # the first command sets the wallet up: it asks for a password on stdin
  out=$(printf 'muster-localnet\n' | funder_wallet account new public 2>&1) || true
  kill "$(cat "$boot/pid")" 2>/dev/null; rm -rf "$boot"
  id=$(echo "$out" | grep -oE 'Public/[1-9A-HJ-NP-Za-km-z]{32,44}' | head -1 | sed 's|Public/||')
  [ -n "$id" ] || { echo "could not read the funder's account from: $out" >&2; exit 1; }
  echo "$id" > "$FUNDER/funder.id"
  echo "$id"
}

funder04() {  # v0.4's funder: LEZ's local test key in a wallet of its CLI, once the zone answers
  if [ ! -s "$FUNDER/funder.id" ]; then
    rm -rf "$FUNDER"; mkdir -p "$FUNDER"; chmod 700 "$FUNDER"
    cp "$DIR/lez/wallet/configs/debug/wallet_config.json" "$FUNDER/"
    local id
    id=$(funder_wallet account import public --private-key "$FUNDER04_KEY" < /dev/null 2>&1 |
         grep -oE 'Public/[1-9A-HJ-NP-Za-km-z]{32,44}' | head -1 | sed 's|Public/||')
    [ -n "$id" ] || { echo "could not import the funder's key" >&2; exit 1; }
    echo "$id" > "$FUNDER/funder.id"
  fi
}

start04() {
  rm -rf "$RUN"; mkdir -p "$RUN"
  "$SEQ" setup "$RUN/home" --config "$DIR/lez/sequencer/service/networks/local.json" \
    --funding-public-key "$BEDROCK_FUNDING_KEY" --create-channel > "$RUN/setup.log" 2>&1 \
    || { echo "setup failed; see $RUN/setup.log" >&2; exit 1; }
  launch "$RUN/home" "$RUN" "$LOG" "$PIDFILE" || { echo "the sequencer did not start; see $LOG" >&2; exit 1; }
  funder04
  echo "LEZ $VERSION sequencer on $URL (log: $LOG)"
  echo "funder: Public/$(cat "$FUNDER/funder.id"), LEZ's local test key — '$0 fund <id> <amount>'"
  exit 0
}

start() {
  r0vm_on_path
  build
  if running; then echo "already running (pid $(cat "$PIDFILE")); '$0 stop' first for a fresh chain"; exit 0; fi
  is04 && start04
  local cfg home
  if [ "$VERSION" = v0.2.4 ]; then
    home="$RUN"; rm -rf "$RUN/rocksdb"; cfg=configs/debug/sequencer_config.json
  else
    local fid; fid=$(funder_id)
    rm -rf "$RUN"; mkdir -p "$RUN"; home="$RUN"; cfg="$RUN/sequencer_config.json"
    config_with "$cfg" "$RUN" "$fid" "$GENESIS_BALANCE"
  fi
  if launch "$cfg" "$home" "$LOG" "$PIDFILE"; then
    echo "LEZ $VERSION sequencer on $URL (log: $LOG)"
    [ "$VERSION" = v0.2.4 ] || echo "funder: Public/$(cat "$FUNDER/funder.id"), $GENESIS_BALANCE at genesis — '$0 fund <id> <amount>'"
    exit 0
  fi
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
    [ -s "$FUNDER/funder.id" ] && echo "funder Public/$(cat "$FUNDER/funder.id"): $(funder_wallet account get --account-id "Public/$(cat "$FUNDER/funder.id")" 2>/dev/null < /dev/null | grep -m1 Balance)" ;;
  fund|deploy)
    [ "$VERSION" = v0.2.4 ] && { echo "v0.2.4 has no funder here (it has the pinata faucet, and deploys by transaction)" >&2; exit 2; }
    running || { echo "not running: '$0' first" >&2; exit 1; }
    # the funder's sends and deploys are infra/lez/funder.sh's, for every zone
    MUSTER_LEZ_DIR="$DIR" exec "$(dirname "$0")/funder.sh" --zone local "$@" ;;
  up) start ;;
  *) echo "usage: $0 [up | build | fund <id> <amount> | deploy <program.bin> | status | stop]" >&2; exit 2 ;;
esac
