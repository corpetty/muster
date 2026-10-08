#!/usr/bin/env bash
# Assemble the Pages site into one directory, as .github/workflows/pages.yml publishes it.
#
#   /            site/index.html — the landing page
#   /diagrams/   docs/diagrams/ — the figure programme, its index, the substrates
#   /atlas/      docs/design/multisig-atlas.html — the action atlas
#
# The artifact is assembled by name, not docs/ wholesale (see pages.yml). Until
# 2026-10-08 the diagrams were the site root, and posts link to their figures and
# substrates there; those files stay at the root too, so no published link breaks.
# Only the old root index.html is replaced — by the landing page, which links on.
#
# Then every relative link in the assembled HTML must resolve (scripts/check-site-links.py).
#
#   scripts/build-site.sh [out-dir]     # default: _site
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/_site}"

rm -rf "$out"
mkdir -p "$out/diagrams" "$out/atlas"

cp -r "$root/docs/diagrams/." "$out/diagrams/"
cp "$root/docs/design/multisig-atlas.html" "$out/atlas/index.html"

# The pre-2026-10-08 URLs: every figure, frame and substrate at the root.
find "$root/docs/diagrams" -maxdepth 1 -type f \
  \( -name '*.svg' -o -name '*.png' -o -name 'substrate-*.html' \) \
  -exec cp {} "$out/" \;

cp "$root/site/index.html" "$out/index.html"

python3 "$root/scripts/check-site-links.py" "$out"
