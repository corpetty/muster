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
# fills it on first run), MUSTER_SODIUM (libsodium prefix; unset: nixpkgs' libsodium, built
# with nixpkgs' gcc), JOBS (default 8),
# TEST_TIMEOUT (seconds per test, default 900), OUT (log dir, default a fresh mktemp).
# TEST_ARGS (appended to each selected test's command line — an e2e test's own
# arguments, e.g. TEST_ARGS="$SAFE" for coordinate_submit_anvil; see tests/README.md).
#
# macOS (Darwin): nixpkgs' libsodium.dylib, no nixpkgs gcc; with no nim on PATH, the nim and
# the clang the .lgx compiles with (the builder's nixpkgs, as a lock pins it); with no
# timeout(1), nixpkgs coreutils'. The stock /bin/bash 3.2 runs it.
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
E2E=(lez_msig_live_e2e lez_msig_private_e2e safe_anvil_e2e safe_real_anvil_e2e coordinate_submit_anvil btc_regtest_e2e split_btc_regtest_e2e
     phase_d_exit_test lez_multisig_live_e2e lez_frost_account_e2e lez_frost_room_e2e
     split_anvil_e2e split_erc20_anvil_e2e settle_up_btc_regtest_e2e settle_up_erc20_anvil_e2e
     settle_up_across_anvil_e2e xmr_msig_regtest_e2e xmr_msig_setup_regtest_e2e xmr_msig_spend_regtest_e2e
     xmr_msig_stagenet_live)

# 1. The closure, at the pinned revs (fetched on a miss).
NIMPKGS="$(tools/nim-closure.sh)" || exit 1

# libsodium from nixpkgs, and the gcc that links against it from the same nixpkgs (one
# build, one resolution). A nix-built library needs the glibc it was built against, and
# nixpkgs-unstable's is newer than many hosts' — 2.44 against Ubuntu 24.04's 2.39 fails
# every test at run time ("GLIBC_ABI_GNU2_TLS not found") — so a run that borrows
# nixpkgs' libsodium compiles with nixpkgs' gcc, whose wrapper links its own glibc.
# MUSTER_SODIUM (a host libsodium) keeps the host's compiler.
# macOS has no glibc to drift from: a nix-built dylib links libSystem and names itself by
# its store path, so whichever clang nim drives links nixpkgs' libsodium as is.
# HOST_OS, not OS: a caller's exported OS would carry our value into every test.
HOST_OS="$(uname -s)"
SOEXT=so; [ "$HOST_OS" = Darwin ] && SOEXT=dylib
if [ -n "${MUSTER_SODIUM:-}" ]; then
  SODIUM="$MUSTER_SODIUM"
elif [ "$HOST_OS" = Darwin ]; then
  SODIUM="$(nix build nixpkgs#libsodium.out --no-link --print-out-paths 2>/dev/null | tail -1)"
else
  { read -r SODIUM; read -r NIXGCC; } < <(nix build nixpkgs#libsodium.out nixpkgs#gcc.out --no-link --print-out-paths 2>/dev/null)
  [ -n "${NIXGCC:-}" ] && [ -x "$NIXGCC/bin/gcc" ] || { echo "nixpkgs#gcc not found (set MUSTER_SODIUM to use the host's compiler)"; exit 1; }
  export PATH="$NIXGCC/bin:$PATH"
fi
[ -f "$SODIUM/lib/libsodium.$SOEXT" ] || { echo "libsodium not found (set MUSTER_SODIUM)"; exit 1; }
# macOS with no nim on PATH: the nim and the clang the .lgx compiles with. Its
# libmuster_module is lib/mkLogosModule.nix's codegen.nim, `nim c` under the builder's own
# pkgs.nim (2.2.4 at c10a94c, the store path the darwin .lgx used) in that nixpkgs' stdenv.
# On aarch64-darwin nixpkgs' nim wrapper sets no NIM_CONFIG_PATH, so the CC it exports goes
# unread: nim takes `clang` off PATH — stdenv.cc in the build (the .lgx's objects say sdk
# 11.3), Apple's here (sdk 26) — so stdenv.cc goes first, as nixpkgs' gcc does on Linux.
# The pin is read off a lock, never by evaluating the flake (>7 GB, CLAUDE.md): this
# directory's flake.lock when there is one, else, since flake.lock is gitignored and a fresh
# clone has none, the builder's own lock (flake.nix overrides none of the builder's
# nixpkgs), which `nix flake metadata` fetches without evaluating.
if [ "$HOST_OS" = Darwin ] && ! command -v nim >/dev/null 2>&1; then
  # A function, not $(python3 <<'PY' …): bash 3.2 matches quotes inside a heredoc in $(…).
  builder_nixpkgs() {
    if [ -f flake.lock ]; then cat flake.lock
    else nix flake metadata "$(grep -o 'github:corpetty/logos-module-builder/[0-9a-f]\{40\}' flake.nix | head -1)" --json 2>/dev/null
    fi | python3 -c '
import json, sys
d = json.load(sys.stdin); lock = d.get("locks", d); nodes = lock["nodes"]
def node(ref):   # an input is a node name, or a follows path walked from the root
    if isinstance(ref, str): return ref
    n = lock["root"]
    for k in ref: n = node(nodes[n]["inputs"][k])
    return n
# the root of flake.lock is this flake, the root of the metadata the builder itself
lmb = lock["root"] if "locks" in d else node(nodes[lock["root"]]["inputs"]["logos-module-builder"])
k = nodes[node(nodes[lmb]["inputs"]["nixpkgs"])]["locked"]
print("github:%s/%s/%s" % (k["owner"], k["repo"], k["rev"]))'
  }
  NIXPKGS_PIN="$(builder_nixpkgs)"
  NIMDIR="$(nix build "$NIXPKGS_PIN#nim" --no-link --print-out-paths 2>/dev/null | tail -1)"
  NIXCC="$(nix build "$NIXPKGS_PIN#stdenv.cc" --no-link --print-out-paths 2>/dev/null | tail -1)"
  [ -x "$NIMDIR/bin/nim" ] && [ -x "$NIXCC/bin/clang" ] || { echo "no nim on PATH, and the builder's nixpkgs#nim or #stdenv.cc ($NIXPKGS_PIN) did not build"; exit 1; }
  export PATH="$NIMDIR/bin:$NIXCC/bin:$PATH"
fi
# macOS ships no timeout(1): take GNU coreutils' from nixpkgs, the one Linux runs. Last on
# PATH, so it supplies only what the host lacks (timeout) and shadows none of its tools.
if [ "$HOST_OS" = Darwin ] && ! command -v timeout >/dev/null 2>&1; then
  CU="$(nix build nixpkgs#coreutils --no-link --print-out-paths 2>/dev/null | tail -1)"
  [ -x "$CU/bin/timeout" ] || { echo "no timeout(1) on PATH, and nixpkgs#coreutils did not build"; exit 1; }
  export PATH="$PATH:$CU/bin"
fi
# probe_return_marshalling_host builds the module into a host harness against a system
# libsecp256k1; supply nixpkgs' unless the caller already pointed it somewhere.
if [ -z "${MUSTER_SECP256K1_LIB:-}" ] && ! pkg-config --exists libsecp256k1 2>/dev/null; then
  SECPLIB="$(nix build nixpkgs#secp256k1 --no-link --print-out-paths 2>/dev/null | tail -1)"
  [ -d "$SECPLIB/lib" ] && export MUSTER_SECP256K1_LIB="-L$SECPLIB/lib -lsecp256k1 -Wl,-rpath,$SECPLIB/lib"
fi
export MUSTER_SODIUM_LIB="${MUSTER_SODIUM_LIB:--L$SODIUM/lib -lsodium -Wl,-rpath,$SODIUM/lib}"
# The same probe's inner `nim c` reads the closure from here (metadata.json's pins).
export MUSTER_NIMPKGS="$NIMPKGS"

P="$NIMPKGS"
FLAGS=(-d:release --threads:on --hints:off
  --path:"$P/nim-secp256k1" --path:"$P/nim-stew" --path:"$P/nim-results" --path:"$P/nimcrypto"
  --path:"$P/nim-stint" --path:"$P/nim-intops/src" --path:"$P/nim-eth"
  --path:"$P/nim-web3" --path:"$P/nim-chronos" --path:"$P/nim-chronicles" --path:"$P/nim-bearssl"
  --path:"$P/nim-faststreams" --path:"$P/nim-json-rpc" --path:"$P/nim-serialization"
  --path:"$P/nim-json-serialization" --path:"$P/nim-http-utils" --path:"$P/logos-nim-sdk/src"
  --passL:"$SODIUM/lib/libsodium.$SOEXT" --passL:"-Wl,-rpath,$SODIUM/lib")

# 2. Select.
E2E+=(lez_frost_v030_e2e lez_frost_room_v030_e2e)    # on a local LEZ v0.3 zone (exo-eb6.4 L3)
E2E+=(lez_multisig_live_v030_e2e)                    # the v0.3 multisig port, deployed on that zone (exo-eb6.4.4)
E2E+=(quest_room_v030_e2e)                          # quests in the room: the multisig port and programs/lez-quest on that zone (exo-267.8)
E2E+=(circle_rounds_v030_e2e)                       # a circle's rounds from the pot: the multisig port on that zone, pay-ins read back (exo-267.3)
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
  # ${a[@]+"${a[@]}"}: bash < 4.4 (macOS's /bin/bash is 3.2) calls an empty array unbound under set -u
  *)       FILTERS=("$GROUP" ${FILTERS[@]+"${FILTERS[@]}"}); sel=("${unit[@]}" "${probes[@]}") ;;
esac
if [ ${#FILTERS[@]} -gt 0 ]; then
  keep=()
  for f in "${sel[@]}"; do for q in "${FILTERS[@]}"; do [[ "$f" == *"$q"* ]] && { keep+=("$f"); break; }; done; done
  sel=(${keep[@]+"${keep[@]}"})
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
