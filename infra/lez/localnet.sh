#!/usr/bin/env bash
# A local LEZ v0.2.4 standalone sequencer: the chain line the public testnet runs, for the
# LEZ multisig live test (module/tests/lez_multisig_live_e2e.nim, exo-3c9).
#
#   infra/lez/localnet.sh          build (first run: ~15 min) and start on 127.0.0.1:3040
#   infra/lez/localnet.sh stop     stop it
#
# A FRESH chain each start (the rocksdb is wiped). 15s blocks, RISC0_DEV_MODE=1. Then deploy
# the multisig program and run the live test in one go:
#   MUSTER_LEZ_MULTISIG_BIN=<lez-multisig>/target/riscv32im-risc0-zkvm-elf/docker/multisig.bin \
#     nim r … module/tests/lez_multisig_live_e2e.nim http://127.0.0.1:3040 15
# Build that guest with `make build` in logos-co/lez-multisig (PR #45 or later): it
# reproduces ImageID 2ced3d30…d4c7, the program deployed on the testnet.
#
# System needs, the traps found the expensive way (docs/labbook/lez-multisig-versions.md):
#   - libclang: RocksDB's bindgen. Set LIBCLANG_PATH, e.g. to `nix build --print-out-paths
#     nixpkgs#libclang.lib`/lib.
#   - r0vm 3.0.5 on PATH: genesis runs in risc0's executor, and without it the start panics
#     with a bare "No such file or directory". Get it with `rzup install r0vm 3.0.5`.
#   - Rust 1.94.0: the LEZ repo's rust-toolchain.toml pins it, and rustup fetches it.
set -euo pipefail
DIR="${MUSTER_LEZ_DIR:-$HOME/.cache/muster/lez-v0.2.4}"
PIDFILE="$DIR/.sequencer.pid"
LOG="$DIR/sequencer.log"

if [ "${1:-}" = "stop" ]; then
  if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then echo "stopped"; else echo "not running"; fi
  rm -f "$PIDFILE"
  exit 0
fi

command -v r0vm >/dev/null || { echo "r0vm 3.0.5 is not on PATH (rzup install r0vm 3.0.5)" >&2; exit 1; }
if [ ! -d "$DIR/.git" ]; then
  mkdir -p "$(dirname "$DIR")"
  git clone -q --depth 1 --branch v0.2.4 https://github.com/logos-blockchain/logos-execution-zone "$DIR"
fi
if [ ! -x "$DIR/target/release/sequencer_service" ]; then
  echo "building the v0.2.4 standalone sequencer (first run: ~15 min)…"
  (cd "$DIR" && cargo build --release --features standalone -p sequencer_service)
fi
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "already running (pid $(cat "$PIDFILE")); '$0 stop' first for a fresh chain"; exit 0
fi
cd "$DIR/lez/sequencer/service"
rm -rf rocksdb
RISC0_DEV_MODE=1 RUST_LOG=info nohup "$DIR/target/release/sequencer_service" \
  configs/debug/sequencer_config.json > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 60); do
  grep -q "RPC server started" "$LOG" 2>/dev/null && { echo "LEZ v0.2.4 sequencer on http://127.0.0.1:3040 (log: $LOG)"; exit 0; }
  sleep 1
done
echo "the sequencer did not start; see $LOG" >&2
exit 1
