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
