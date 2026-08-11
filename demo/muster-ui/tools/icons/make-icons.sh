#!/usr/bin/env bash
# Rasterizes this folder's icon sources into the ones the plugin ships.
#
# The hosts' Qt carries no SVG image plugin, so the module can only load raster
# icons; the sources stay here so a glyph can be edited and re-rendered rather
# than redrawn. 64px covers a 32px control at 2x. The strokes are black and the
# alpha carries the shape, which is what both call sites need: LogosIconButton
# tints through the alpha, and the group glyph is drawn straight at low opacity.
#
# Usage: tools/icons/make-icons.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../../src/qml/ChatUi/icons"
mkdir -p "$out"

for svg in "$here"/*.svg; do
    name="$(basename "$svg" .svg)"
    magick -background none "$svg" -resize 64x64 "$out/$name.png"
    echo "$name.png"
done
