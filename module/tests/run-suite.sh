#!/usr/bin/env bash
# Run module/tests in one command: every unit test and invariant probe, in parallel,
# with one flag set that satisfies all of them (the union of $SECP, $STINT, the web3
# closure, the SDK and libsodium from tests/README.md — extra --path entries are
# harmless to a pure-Nim test). The Nim closure is cloned at the exact revs
# module/metadata.json pins (codegen.nim.packages), so a local run builds against the
# same sources the .lgx does.
#
#   module/tests/run-suite.sh                 # unit tests + probes (no chains needed)
#   module/tests/run-suite.sh unit            # unit tests only
#   module/tests/run-suite.sh probes          # invariant probes only
#   module/tests/run-suite.sh e2e <name>...   # a named chain-bound test; bring its chain up first
#   module/tests/run-suite.sh all dcbor frost # any group, filtered by substring
#
# Env: MUSTER_NIMPKGS (closure dir, default ~/.cache/muster/nimpkgs; tools/nim-closure.sh
# fills it on first run), MUSTER_SODIUM (libsodium prefix, default nixpkgs#libsodium), JOBS (default 8),
# TEST_TIMEOUT (seconds per test, default 900), OUT (log dir, default a fresh mktemp).
# TEST_ARGS (appended to each selected test's command line — an e2e test's own
# arguments, e.g. TEST_ARGS="$SAFE" for coordinate_submit_anvil; see tests/README.md).
set -uo pipefail

MODULE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MODULE"

GROUP="${1:-default}"; [ $# -gt 0 ] && shift
FILTERS=("$@")
# Chain-bound tests share their chain's state (a Safe nonce, a regtest UTXO set): one at a time.
if [ "$GROUP" = e2e ]; then JOBS="${JOBS:-1}"; else JOBS="${JOBS:-8}"; fi
TEST_TIMEOUT="${TEST_TIMEOUT:-900}"
OUT="${OUT:-$(mktemp -d -t muster-suite.XXXXXX)}"
mkdir -p "$OUT"

# Tests that need a live chain (see tests/README.md): never in the default run.
E2E=(safe_anvil_e2e safe_real_anvil_e2e coordinate_submit_anvil btc_regtest_e2e
     phase_d_exit_test lez_multisig_live_e2e lez_frost_account_e2e lez_frost_room_e2e)

# 1. The closure, at the pinned revs (fetched on a miss).
NIMPKGS="$(tools/nim-closure.sh)" || exit 1

SODIUM="${MUSTER_SODIUM:-$(nix build nixpkgs#libsodium --no-link --print-out-paths 2>/dev/null | tail -1)}"
[ -f "$SODIUM/lib/libsodium.so" ] || { echo "libsodium not found (set MUSTER_SODIUM)"; exit 1; }
# probe_return_marshalling_host links the module into a C++ harness against a system
# libsecp256k1; supply nixpkgs' unless the caller already pointed it somewhere.
if [ -z "${MUSTER_SECP256K1_LIB:-}" ] && ! pkg-config --exists libsecp256k1 2>/dev/null; then
  SECPLIB="$(nix build nixpkgs#secp256k1 --no-link --print-out-paths 2>/dev/null | tail -1)"
  [ -d "$SECPLIB/lib" ] && export MUSTER_SECP256K1_LIB="-L$SECPLIB/lib -lsecp256k1 -Wl,-rpath,$SECPLIB/lib"
fi
export MUSTER_SODIUM_LIB="${MUSTER_SODIUM_LIB:--L$SODIUM/lib -lsodium -Wl,-rpath,$SODIUM/lib}"
# ...and compiles that harness with g++; borrow nixpkgs' when the host has none.
if ! command -v g++ >/dev/null; then
  GCC="$(nix build nixpkgs#gcc --no-link --print-out-paths 2>/dev/null | tail -1)"
  [ -x "$GCC/bin/g++" ] && export PATH="$GCC/bin:$PATH"
fi
# The same probe's inner `nim c` reads the closure from here (metadata.json's pins).
export MUSTER_NIMPKGS="$NIMPKGS"

P="$NIMPKGS"
FLAGS=(-d:release --threads:on --hints:off
  --path:"$P/nim-secp256k1" --path:"$P/nim-stew" --path:"$P/nim-results" --path:"$P/nimcrypto"
  --path:"$P/nim-stint" --path:"$P/nim-intops/src" --path:"$P/nim-eth"
  --path:"$P/nim-web3" --path:"$P/nim-chronos" --path:"$P/nim-chronicles" --path:"$P/nim-bearssl"
  --path:"$P/nim-faststreams" --path:"$P/nim-json-rpc" --path:"$P/nim-serialization"
  --path:"$P/nim-json-serialization" --path:"$P/nim-http-utils" --path:"$P/logos-nim-sdk/src"
  --passL:"$SODIUM/lib/libsodium.so" --passL:"-Wl,-rpath,$SODIUM/lib")

# 2. Select.
is_e2e() { local n; for n in "${E2E[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }
unit=(); probes=(); e2e=()
for f in tests/*.nim; do
  n=$(basename "$f" .nim)
  if is_e2e "$n"; then e2e+=("$f"); else unit+=("$f"); fi
done
for f in tests/probes/probe_*.nim; do probes+=("$f"); done
case "$GROUP" in
  default) sel=("${unit[@]}" "${probes[@]}") ;;
  unit)    sel=("${unit[@]}") ;;
  probes)  sel=("${probes[@]}") ;;
  e2e)     sel=("${e2e[@]}"); [ ${#FILTERS[@]} -gt 0 ] || { echo "e2e needs a test name: ${E2E[*]}"; exit 2; } ;;
  all)     sel=("${unit[@]}" "${probes[@]}" "${e2e[@]}") ;;
  *)       FILTERS=("$GROUP" "${FILTERS[@]}"); sel=("${unit[@]}" "${probes[@]}") ;;
esac
if [ ${#FILTERS[@]} -gt 0 ]; then
  keep=()
  for f in "${sel[@]}"; do for q in "${FILTERS[@]}"; do [[ "$f" == *"$q"* ]] && { keep+=("$f"); break; }; done; done
  sel=("${keep[@]}")
fi
[ ${#sel[@]} -gt 0 ] || { echo "no tests match"; exit 2; }

# 3. Run. Each test gets its own log and a PASS/FAIL line; the summary reads those.
run_one() {
  local f="$1" n; n=$(basename "$f" .nim)
  local t0=$SECONDS
  # shellcheck disable=SC2086  # TEST_ARGS is deliberately word-split
  if timeout "$TEST_TIMEOUT" nim r "${FLAGS[@]}" "$f" ${TEST_ARGS:-} >"$OUT/$n.log" 2>&1; then
    echo "PASS $n $((SECONDS - t0))s" | tee -a "$OUT/results"
  else
    echo "FAIL $n $((SECONDS - t0))s  ($OUT/$n.log)" | tee -a "$OUT/results"
  fi
}
export -f run_one; export OUT TEST_TIMEOUT TEST_ARGS="${TEST_ARGS:-}"
export FLAGS_STR; FLAGS_STR=$(printf '%q ' "${FLAGS[@]}")
run_one_q() { eval "FLAGS=($FLAGS_STR)"; run_one "$1"; }
export -f run_one_q
: >"$OUT/results"
echo "running ${#sel[@]} tests, $JOBS at a time; logs in $OUT"
printf '%s\n' "${sel[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one_q "$1"' _ {}

pass=$(grep -c '^PASS' "$OUT/results"); fail=$(grep -c '^FAIL' "$OUT/results")
echo
echo "── $pass passed, $fail failed (of ${#sel[@]}) ──"
grep '^FAIL' "$OUT/results" | sort
[ "$fail" -eq 0 ]
