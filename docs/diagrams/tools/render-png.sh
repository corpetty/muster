#!/usr/bin/env bash
# Render every figure in docs/diagrams/ to a 2x PNG beside its SVG.
#
# SVG is the source. The PNG exists because most forum software handles PNG
# more reliably than SVG, so both are committed and the PNG is a build product
# that happens to live in the tree.
#
# Text is plain <text> with no font embedding, so whatever renders these
# substitutes a local sans. That is deliberate -- nothing depends on a
# particular face -- which also means a PNG rendered on one machine will not be
# byte-identical to one rendered on another. Do not treat a PNG diff as a
# signal; re-render when the SVG changes and leave it there.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="$here/$(basename "${BASH_SOURCE[0]}")"
cd "$here/.."

# No local librsvg -- borrow one and re-exec inside it. Uses the resolved path,
# not $0: we have already cd'd, so a relative $0 would no longer resolve.
if ! command -v rsvg-convert >/dev/null 2>&1; then
  exec nix shell nixpkgs#librsvg --command bash "$self" "$@"
fi

shopt -s nullglob
svgs=(*.svg)
if [ ${#svgs[@]} -eq 0 ]; then
  echo "no SVGs in $(pwd)" >&2
  exit 1
fi

echo "rendering ${#svgs[@]} figure(s) at 2x:"
for f in "${svgs[@]}"; do
  rsvg-convert -z 2 -o "${f%.svg}.png" "$f"
  echo "  ${f%.svg}.png"
done
