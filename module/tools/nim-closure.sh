#!/usr/bin/env bash
# Materialize the module's Nim closure — every package module/metadata.json pins in
# codegen.nim.packages, at exactly that rev (with submodules where it says so) — and
# print the directory. The .lgx build fetches the same pins; this puts them where a
# local `nim r`/`nim c` can reach them. Re-checks each rev on every call and fetches
# only on a miss, so it is cheap to call before every run.
#
#   P=$(module/tools/nim-closure.sh)        # default ~/.cache/muster/nimpkgs
#   MUSTER_NIMPKGS=/elsewhere module/tools/nim-closure.sh
#
# Each package's import root is $P/<repo>[/<subdir>]: nim-intops/src and
# logos-nim-sdk/src carry a subdir, the rest are the repo root.
set -euo pipefail
META="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/metadata.json"
NIMPKGS="${MUSTER_NIMPKGS:-${XDG_CACHE_HOME:-$HOME/.cache}/muster/nimpkgs}"
mkdir -p "$NIMPKGS"
python3 - "$META" "$NIMPKGS" <<'PY'
import json, os, subprocess, sys
meta, root = sys.argv[1], sys.argv[2]
def git(*a): return subprocess.run(["git", *a], capture_output=True, text=True)
bad = 0
for p in json.load(open(meta))["codegen"]["nim"]["packages"]:
    d = os.path.join(root, p["repo"])
    if not os.path.isdir(d):
        git("init", "-q", d)
        git("-C", d, "remote", "add", "origin", f"https://github.com/{p['owner']}/{p['repo']}")
    if git("-C", d, "rev-parse", "HEAD").stdout.strip() != p["rev"]:
        print(f"fetching {p['repo']} @ {p['rev'][:10]}", file=sys.stderr)
        git("-C", d, "fetch", "-q", "--depth", "1", "origin", p["rev"])
        git("-C", d, "checkout", "-q", "FETCH_HEAD")
        if p.get("submodules"):
            git("-C", d, "submodule", "update", "-q", "--init", "--recursive", "--depth", "1")
    if git("-C", d, "rev-parse", "HEAD").stdout.strip() != p["rev"]:
        print(f"nim-closure: {p['repo']} is not at {p['rev']}", file=sys.stderr); bad = 1
sys.exit(bad)
PY
echo "$NIMPKGS"
