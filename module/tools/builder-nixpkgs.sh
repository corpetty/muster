#!/usr/bin/env bash
# Print the nixpkgs the module's .lgx is built from, as a flake ref
# (github:<owner>/<repo>/<rev>): logos-module-builder's own nixpkgs input, which
# module/flake.nix overrides none of. The libopus the .lgx ships (metadata.json's
# nix.packages.runtime "libopus") comes from it, so a test that links libopus takes it from
# here: tests/run-suite.sh on both OSes (and, on macOS with no nim on PATH, the nim and clang
# the .lgx compiles with), and scripts/grade-specs.sh for exo-526's host probe.
#
#   P=$(module/tools/builder-nixpkgs.sh); nix build "$P#libopus.out" --no-link --print-out-paths
#
# The pin is read off a lock, never by evaluating the flake (>7 GB, CLAUDE.md): module/flake.lock
# when there is one, else, since flake.lock is gitignored and a fresh clone has none, the
# builder's own lock, which `nix flake metadata` fetches without evaluating. Prints nothing
# and exits non-zero when neither can be read.
# A python3 -c, not $(python3 <<'PY' …): bash 3.2 matches quotes inside a heredoc in $(…).
set -euo pipefail
MODULE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MODULE"
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
