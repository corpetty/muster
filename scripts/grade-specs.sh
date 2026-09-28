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
ln -sfn "$("$REPO/module/tools/nim-closure.sh")" "$PROBE_ENV/nimpkgs"
SODIUM="${MUSTER_SODIUM:-$(nix build nixpkgs#libsodium --no-link --print-out-paths 2>/dev/null | tail -1)}"
[ -f "$SODIUM/lib/libsodium.so" ] && ln -sfn "$SODIUM/lib" "$PROBE_ENV/sodium" \
  || echo "warning: libsodium not found (set MUSTER_SODIUM); probes that need it will not build" >&2
# exo-526's probe compiles a C++ host harness; like run-suite.sh, borrow nixpkgs' g++ when
# the host has none, linked where the probe looks for it.
CXX="$(command -v g++ || true)"
if [ -z "$CXX" ]; then
  GCC="$(nix build nixpkgs#gcc --no-link --print-out-paths 2>/dev/null | tail -1)"
  [ -x "$GCC/bin/g++" ] && CXX="$GCC/bin/g++"
fi
[ -n "$CXX" ] && ln -sfn "$CXX" "$PROBE_ENV/g++" \
  || echo "warning: no g++ (nor nixpkgs#gcc); exo-526's host harness will not build" >&2

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
