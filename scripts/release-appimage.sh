#!/usr/bin/env bash
# The download-and-run release (RELEASING.md): Basecamp's own released AppImage with Muster
# baked in. No Basecamp source build and no local bake-in edits: the official release is
# unpacked, Muster's two portable packages and the Logos Official packages they need
# (infra/basecamp/bundle-<tag>.tsv, each checked against its sha256) are installed into its
# built-in module and plugin directories with the lgpm that release links, and the result
# is repacked behind the release's own AppImage runtime. Basecamp then lists Muster as an
# installed app on first launch, with nothing to download.
#
#   scripts/release-appimage.sh                          # muster from the committed tree
#   scripts/release-appimage.sh --lgx-dir .run/catalog-release/muster-v0.3.0
#                                                        # the .lgx files of a catalogue release
#
# Options:
#   --lgx-dir DIR   use muster_module-*.lgx, muster_ui-*.lgx, lez_msig_module-*.lgx and lez_msig_v04_module-*.lgx from DIR (the files the
#                   catalogue release publishes), instead of building .#lgx-portable here
#   --out FILE      the AppImage to write (default .run/appimage/Muster-<version>-Basecamp-
#                   <tag>-linux-x86_64.AppImage)
#   --allow-dirty   build muster even if module/ or ui/ has uncommitted changes
#
# Publishes nothing. Check the AppImage on a display before shipping it (RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

. infra/basecamp/release-0.3.2.env
BUNDLE=infra/basecamp/bundle-$BASECAMP_TAG.tsv
SUB=(--extra-substituters https://cache.nix.logos.co)

LGX_DIR=""; OUT=""; ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lgx-dir) LGX_DIR=${2:?--lgx-dir needs a directory}; shift ;;
    --out) OUT=${2:?--out needs a file}; shift ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

VERSION=$(python3 -c 'import json; print(json.load(open("ui/metadata.json"))["version"])')
WORK=$ROOT/.run/appimage
OUT=${OUT:-$WORK/Muster-$VERSION-Basecamp-$BASECAMP_TAG-linux-x86_64.AppImage}
mkdir -p "$WORK/lgx"

# 1. the Basecamp release, checked
SRC=$ROOT/.run/basecamp/LogosBasecamp-$BASECAMP_TAG.AppImage
mkdir -p "$(dirname "$SRC")"
[ -f "$SRC" ] || curl -fsSL -o "$SRC" "$BASECAMP_URL"
echo "$BASECAMP_SHA256  $SRC" | sha256sum -c --quiet
chmod +x "$SRC"

# 2. muster's packages; the private lez-msig's provers too (linux-amd64 only, exo-e77, exo-cc7:
#    lez_msig_module for LEZ v0.3, lez_msig_v04_module for v0.4), so the AppImage proves a
#    private multisig on either line with nothing to install
if [ -n "$LGX_DIR" ]; then
  MOD_LGX=$(ls "$LGX_DIR"/muster_module-*.lgx | tail -1)
  UI_LGX=$(ls "$LGX_DIR"/muster_ui-*.lgx | tail -1)
  MSIG_LGX=$(ls "$LGX_DIR"/lez_msig_module-*.lgx | tail -1)
  MSIG04_LGX=$(ls "$LGX_DIR"/lez_msig_v04_module-*.lgx | tail -1)
else
  if [ $ALLOW_DIRTY = 0 ] && ! git diff --quiet HEAD -- module ui; then
    echo "module/ or ui/ has uncommitted changes; commit them (or --allow-dirty for a trial)" >&2; exit 1
  fi
  MOD_LGX=$(ls "$( (cd module && nix build .#lgx-portable "${SUB[@]}" --no-link --print-out-paths) | tail -1)"/*.lgx)
  UI_LGX=$(ls "$( (cd ui && nix build .#lgx-portable "${SUB[@]}" --no-link --print-out-paths) | tail -1)"/*.lgx)
  MSIG_LGX=$(ls "$( (cd programs/lez-msig && nix build .#lgx-portable "${SUB[@]}" --no-link --print-out-paths) | tail -1)"/*.lgx)
  MSIG04_LGX=$(ls "$( (cd programs/lez-msig/lez04 && nix build .#lgx-portable "${SUB[@]}" --no-link --print-out-paths) | tail -1)"/*.lgx)
fi
echo "muster: $(basename "$MOD_LGX"), $(basename "$UI_LGX"), $(basename "$MSIG_LGX"), $(basename "$MSIG04_LGX")"

# 3. the Logos Official packages they need, each checked
grep -v '^#' "$BUNDLE" | while IFS=$'\t' read -r pkg url sha; do
  f=$WORK/lgx/$pkg.lgx
  if ! { [ -f "$f" ] && echo "$sha  $f" | sha256sum -c --quiet 2>/dev/null; }; then
    curl -fsSL -o "$f" "$url"
    echo "$sha  $f" | sha256sum -c --quiet
  fi
done

# 4. unpack, install into the built-in directories, repack
SQ=$(nix build nixpkgs#squashfsTools --no-link --print-out-paths | tail -1)/bin
LGPM=$(nix build "$LGPM_FLAKE" "${SUB[@]}" --no-link --print-out-paths | tail -1)/bin/lgpm
OFFSET=$("$SRC" --appimage-offset)
APPDIR=$WORK/AppDir
rm -rf "$APPDIR"
"$SQ/unsquashfs" -q -n -d "$APPDIR" -o "$OFFSET" "$SRC" >/dev/null
chmod -R u+w "$APPDIR"
inst() { "$LGPM" --modules-dir "$APPDIR/usr/modules" --ui-plugins-dir "$APPDIR/usr/plugins" --allow-unsigned install --file "$1" >/dev/null; }
grep -v '^#' "$BUNDLE" | while IFS=$'\t' read -r pkg _ _; do inst "$WORK/lgx/$pkg.lgx"; done
inst "$MOD_LGX"
inst "$UI_LGX"
inst "$MSIG_LGX"
inst "$MSIG04_LGX"
for p in muster_module delivery_module lez_core lez_msig_module lez_msig_v04_module; do
  [ -f "$APPDIR/usr/modules/$p/manifest.json" ] || { echo "$p did not install into the AppDir" >&2; exit 1; }
done
[ -f "$APPDIR/usr/plugins/muster_ui/metadata.json" ] || [ -f "$APPDIR/usr/plugins/muster_ui/manifest.json" ] \
  || { echo "muster_ui did not install into the AppDir" >&2; exit 1; }

# the release's own runtime (the first OFFSET bytes), then the new squashfs, as Basecamp
# packs it: gzip, 128 KiB blocks, root-owned, a fixed time so the bytes follow the inputs
head -c "$OFFSET" "$SRC" >"$OUT.tmp"
rm -f "$WORK/fs.squashfs"
"$SQ/mksquashfs" "$APPDIR" "$WORK/fs.squashfs" -comp gzip -b 131072 -root-owned -noappend \
  -all-time 315532800 -mkfs-time 315532800 -quiet -no-progress >/dev/null
cat "$WORK/fs.squashfs" >>"$OUT.tmp"
chmod +x "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
rm -f "$WORK/fs.squashfs"

echo
echo "AppImage: $OUT"
echo "  $(du -h "$OUT" | cut -f1), sha256 $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "  Basecamp $BASECAMP_TAG + muster $VERSION + $(grep -vc '^#' "$BUNDLE") Logos Official packages"
echo "Check it on a display before shipping (RELEASING.md):"
echo "  $OUT --user-dir \$(mktemp -d)    # then Muster in the sidebar"
