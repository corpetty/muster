#!/usr/bin/env bash
# Grade muster's typed specs with exophial's real acceptance oracle.
#
# This is the loop exophial exists for: contracts/specs/derived-exo-*.spec.json
# are graded by `spec_oracle.run_spec`, the SAME in-process entrypoint the
# reducer's completion gate calls at a merge boundary. Probes emit observations;
# the oracle owns judgment.
#
#   scripts/grade-specs.sh            # every spec
#   scripts/grade-specs.sh exo-3a1    # one
#
# Requires exophial installed (see docs/exophial-usage-gaps.md) and rtamt on a
# Python <= 3.12. exophial 0.2.0+dc69cd1d ships on Python 3.14, where its own
# vendored rtamt cannot import: rtamt pins antlr4-python3-runtime==4.7, which
# does `from typing.io import TextIO`, and typing.io was removed in 3.13. This
# script provisions a 3.12 venv once and points the oracle's documented escape
# hatch ($SPEC_ORACLE_RTAMT_PYTHON) at it. Tracked as exo-6c5.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXO_PY="$HOME/.local/share/uv/tools/exophial/bin/python"
VENV="${MUSTER_RTAMT_VENV:-$REPO/.rtamt-venv}"

[ -x "$EXO_PY" ] || { echo "exophial not installed at $EXO_PY" >&2; exit 1; }

if [ ! -x "$VENV/bin/python" ]; then
  echo "provisioning rtamt venv at $VENV (one-off)..." >&2
  uv venv --python 3.12 "$VENV" >&2
  uv pip install --python "$VENV/bin/python" rtamt >&2
fi
export SPEC_ORACLE_RTAMT_PYTHON="$VENV/bin/python"

# The probes' Nim closure, reachable from inside the tree (exo-a7b). The oracle runs each
# probe in an allowlisted env (a scratch HOME, no MUSTER_* vars), so the pinned packages
# and libsodium are linked under module/.probe-env, where tests/probes/config.nims finds
# them. Refreshed every run: the closure re-checks its pins, the link follows nixpkgs.
PROBE_ENV="$REPO/module/.probe-env"
mkdir -p "$PROBE_ENV"
# Gone when the grader exits (exo-dcc.22): left behind, tests/probes/config.nims and the
# audit verifier's build pick up its compiler, and audit-download-self-test.sh then fails.
# KEEP_PROBE_ENV=1 keeps it, to rerun a probe by hand.
trap '[ -n "${KEEP_PROBE_ENV:-}" ] || rm -rf "$PROBE_ENV"' EXIT
ln -sfn "$("$REPO/module/tools/nim-closure.sh")" "$PROBE_ENV/nimpkgs"
# libsodium, and the gcc that links against it, from one nixpkgs (exo-56a; run-suite.sh does
# the same, exo-844). The oracle's PATH holds the host's gcc, and a probe it links loads the
# host's glibc, which may be older than the one nixpkgs' libsodium needs ("GLIBC_ABI_GNU2_TLS
# not found"), so that gcc is linked as .probe-env/cc, where config.nims compiles with it.
# MUSTER_SODIUM (a host libsodium) keeps the host's compiler.
# libopus (voice notes; exo-526's host probe builds the whole module, which links it) is the
# one the .lgx ships, as in run-suite.sh: nixpkgs#libopus at the builder's pin
# (module/tools/builder-nixpkgs.sh, read off a lock; 1.5.2 at e9f00bd), not nixpkgs' current
# one (1.6.1 on 2026-10-23), which this took until PR 340's review. It runs under the gcc
# above for the reason run-suite.sh gives: it was built on an older glibc than that gcc's,
# and the probe loads the gcc's libc and libm itself. It is a build of its own, so a libopus
# that fails to fetch or build costs exo-526 alone, never the libsodium and gcc every other
# probe needs. A host MUSTER_SODIUM needs MUSTER_OPUS beside it, as in run-suite.sh.
NIXGCC=""; OPUS="${MUSTER_OPUS:-}"
if [ -n "${MUSTER_SODIUM:-}" ]; then
  SODIUM="$MUSTER_SODIUM"
else
  { read -r SODIUM; read -r NIXGCC; } < <(nix build nixpkgs#libsodium.out nixpkgs#gcc.out --no-link --print-out-paths 2>/dev/null) || true
  if [ -z "$OPUS" ]; then
    PIN="$("$REPO/module/tools/builder-nixpkgs.sh" 2>/dev/null)" || PIN=""
    if [ -n "$PIN" ]; then
      OPUS="$(nix build "$PIN#libopus.out" --no-link --print-out-paths 2>/dev/null | tail -1)" || true
    else
      echo "warning: the builder's nixpkgs pin could not be read (module/flake.lock, or the builder's own lock)" >&2
    fi
  fi
fi
[ -f "$SODIUM/lib/libsodium.so" ] && ln -sfn "$SODIUM/lib" "$PROBE_ENV/sodium" \
  || echo "warning: libsodium not found (set MUSTER_SODIUM); probes that need it will not build" >&2
[ -f "$OPUS/lib/libopus.so" ] && ln -sfn "$OPUS/lib" "$PROBE_ENV/opus" \
  || echo "warning: libopus not found (set MUSTER_OPUS); exo-526's host probe will not build" >&2
if [ -n "$NIXGCC" ] && [ -x "$NIXGCC/bin/gcc" ]; then ln -sfn "$NIXGCC/bin" "$PROBE_ENV/cc"; else rm -f "$PROBE_ENV/cc"; fi
# exo-526's host harness was C++ and needed a g++ here; it is Nim since exo-607 T7, built
# by the probe's own nim with the cc above.
rm -f "$PROBE_ENV/g++"

cd "$REPO"
"$EXO_PY" - "${1:-}" <<'PY'
import glob, json, pathlib, sys
from exophial import spec_oracle
from exophial.spec_model import Spec

filt = sys.argv[1] if len(sys.argv) > 1 else ""
total = passed = 0
failed_specs = []
for path in sorted(glob.glob("contracts/specs/derived-exo-*.spec.json")):
    name = path.split("derived-")[1].replace(".spec.json", "")
    if filt and filt not in name:
        continue
    verdict = spec_oracle.run_spec(Spec.from_dict(json.load(open(path))), pathlib.Path("."))
    n = len(verdict.checks)
    k = sum(1 for c in verdict.checks if c.passed)
    total += n
    passed += k
    print(f"{'PASS' if verdict.ok else 'FAIL'}  {name:16} {k}/{n}")
    if not verdict.ok:
        failed_specs.append(name)
        for c in verdict.checks:
            if not c.passed:
                print(f"        - {c.detail[:200]}")
print(f"\nTOTAL {passed}/{total} checks pass")
sys.exit(1 if failed_specs else 0)
PY
