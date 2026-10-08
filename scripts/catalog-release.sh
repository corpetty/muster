#!/usr/bin/env bash
# Muster's own Basecamp catalogue (exo-dcc.3, docs/design/catalogue-install.md §3 step 2).
# Builds muster_module and muster_ui as .#lgx-portable from the COMMITTED tree and writes
# the catalogue's two files with logos-modules-release-tool's index.py (`add --with-local`),
# the way the Logos Forum catalogue (edenbd1/logos-forum-catalog) does it: a committed
# index.json, the .lgx files as GitHub release assets.
#
#   scripts/catalog-release.sh                       # a release: catalog/ + .run/catalog-release/<tag>/
#   scripts/catalog-release.sh --local DIR --base-url https://127.0.0.1:8443
#                                                    # everything under DIR, for a local server
#
# Options:
#   --tag TAG          the release tag (default muster-v<version>)
#   --url-base URL     where the .lgx files will be downloadable
#                      (default https://github.com/corpetty/muster/releases/download/<tag>)
#   --local DIR        write logos-repo.json, index.json, icons/ and the .lgx files into DIR
#                      (a fresh index each time), for a local web server
#   --base-url URL     with --local: the URL DIR is served at. Basecamp 0.3.2 accepts only
#                      https:// for a repository and its downloads (logos-package-downloader
#                      `isHttpsUrl`, "https required in v1"), so a local server must speak TLS
#                      with a certificate Basecamp trusts (SSL_CERT_FILE; see
#                      docs/runbooks/install-from-catalogue.md, "Testing a release locally").
#   --allow-dirty      build even if module/ or ui/ has uncommitted changes (never for a release)
#
# The catalogue publishes ONLY muster_module and muster_ui. Every dependency resolves from the
# official Logos catalogue, which Basecamp enables by default and searches alongside ours
# (logos-package-downloader docs/spec.md, "Dependency Resolution"). Nothing here is signed.
#
# This script publishes nothing. A release run leaves, for the operator:
#   .run/catalog-release/<tag>/*.lgx   the release assets, to upload under <tag>
#   catalog/index.json, catalog/icons/  to commit to main AFTER the assets are up
# and prints the exact commands. Basecamp reads catalog/logos-repo.json from main, whose
# indexUrl is catalog/index.json on main: an index committed before its assets exist offers
# packages that fail to download.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

# Pins. index.py is one stdlib-only Python file; the hash is of that file at TOOL_REV.
TOOL_REV=94462e6633f2b536424c10ceda3c371f7ec8e09d
TOOL_SHA256=ef608d0ce5a22a1339d9a53043cdcd056c027db406e1c2fcac2e3ad17ea98c34
# index.py needs `lgx` (with `semver`) on PATH to read and order packages; logos-package
# master as of 2026-10-01, the rev logos-basecamp 0.3.2 also locks.
LGX_FLAKE=github:logos-co/logos-package/c25a1167578aef5cbd9a9b6f822ffe2ae4fd6a89#lgx

REPO_URL=https://raw.githubusercontent.com/corpetty/muster/main/catalog/logos-repo.json
INDEX_URL=https://raw.githubusercontent.com/corpetty/muster/main/catalog/index.json
RELEASES=https://github.com/corpetty/muster/releases/download
PLATFORM=linux-amd64
SUB=(--extra-substituters https://cache.nix.logos.co)

TAG=""; URL_BASE=""; LOCAL=""; BASE_URL=""; ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=${2:?--tag needs a value}; shift ;;
    --url-base) URL_BASE=${2:?--url-base needs a URL}; shift ;;
    --local) LOCAL=${2:?--local needs a directory}; shift ;;
    --base-url) BASE_URL=${2:?--base-url needs a URL}; shift ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$LOCAL" ] && [ -z "$BASE_URL" ]; then echo "--local needs --base-url" >&2; exit 2; fi
if [ -z "$LOCAL" ] && [ -n "$BASE_URL" ]; then echo "--base-url goes with --local" >&2; exit 2; fi
case "${BASE_URL:-https://}" in
  https://*) ;;
  *) echo "warning: $BASE_URL is not https; Basecamp 0.3.2 refuses a non-https repository URL" >&2 ;;
esac

# The pair ships together: one version, both packages.
ver() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1"; }
VERSION=$(ver module/metadata.json)
[ "$(ver ui/metadata.json)" = "$VERSION" ] || {
  echo "module/metadata.json ($VERSION) and ui/metadata.json ($(ver ui/metadata.json)) disagree; bump both" >&2; exit 1; }
TAG=${TAG:-muster-v$VERSION}
URL_BASE=${URL_BASE:-$RELEASES/$TAG}
asset() { echo "$1-$VERSION-$PLATFORM.lgx"; }

# The committed tree, never a working copy.
if [ $ALLOW_DIRTY = 0 ] && [ -n "$(git status --porcelain -- module ui)" ]; then
  echo "module/ or ui/ has uncommitted changes; commit them (the build reads the committed tree)" >&2
  git status --short -- module ui >&2; exit 1
fi
COMMIT=$(git rev-parse HEAD)

WORK=$ROOT/.run/catalog-release
mkdir -p "$WORK/tool"

# index.py at its pinned rev, checked.
TOOL=$WORK/tool/index-$TOOL_REV.py
if ! echo "$TOOL_SHA256  $TOOL" | sha256sum -c --quiet >/dev/null 2>&1; then
  curl -sSfL -o "$TOOL" "https://raw.githubusercontent.com/logos-co/logos-modules-release-tool/$TOOL_REV/index.py"
  echo "$TOOL_SHA256  $TOOL" | sha256sum -c --quiet
fi
LGX=$(nix build "$LGX_FLAKE" "${SUB[@]}" --no-link --print-out-paths 2>/dev/null | tail -1)/bin
[ -x "$LGX/lgx" ] || { echo "could not build lgx ($LGX_FLAKE)" >&2; exit 1; }
export PATH="$LGX:$PATH"

# 1. The packages, as scripts/basecamp-profile.sh builds them (.#lgx-portable: the release
#    accepts only the portable variant), with muster_module overridden to this clone's
#    absolute git+file path and the eval cache off, as `make build` does (exo-fb7).
echo "building muster_module and muster_ui $VERSION from $COMMIT"
MOD=$(nix build "git+file://$ROOT?dir=module#lgx-portable" "${SUB[@]}" --no-eval-cache \
        --no-link --print-out-paths 2>"$WORK/build-module.log" | tail -1) \
  || { echo "module build failed; see $WORK/build-module.log" >&2; exit 1; }
UI=$(nix build "git+file://$ROOT?dir=ui#lgx-portable" "${SUB[@]}" --no-eval-cache \
        --override-input muster_module "git+file://$ROOT?dir=module" \
        --no-link --print-out-paths 2>"$WORK/build-ui.log" | tail -1) \
  || { echo "ui build failed; see $WORK/build-ui.log" >&2; exit 1; }

# Each package's embedded manifest must carry the name and version the catalogue claims.
declare -A SRC
for pair in "muster_module:$MOD" "muster_ui:$UI"; do
  pkg=${pair%%:*}; f=$(ls "${pair#*:}"/*.lgx | head -1)
  lgx verify "$f" >/dev/null
  got=$(lgx manifest "$f" --json | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["name"], m["version"], " ".join(sorted(m.get("main", {}))))')
  [ "$got" = "$pkg $VERSION $PLATFORM" ] || { echo "$f: manifest says '$got', expected '$pkg $VERSION $PLATFORM'" >&2; exit 1; }
  SRC[$pkg]=$f
done

# 2. Where the files go.
if [ -n "$LOCAL" ]; then
  OUT=$(mkdir -p "$LOCAL" && cd "$LOCAL" && pwd)
  ASSETS=$OUT
  BASE=${BASE_URL%/}
  URL_BASE=$BASE
  THIS_INDEX_URL=$BASE/index.json
  rm -rf "$OUT/index.json" "$OUT/icons"
else
  OUT=$ROOT/catalog
  ASSETS=$WORK/$TAG
  THIS_INDEX_URL=$INDEX_URL
  mkdir -p "$OUT"
fi
mkdir -p "$ASSETS"
for pkg in muster_module muster_ui; do
  install -m 0644 "${SRC[$pkg]}" "$ASSETS/$(asset "$pkg")"
done

# 3. The identity card. The committed one points at main; a local one at its server.
python3 - "$OUT/logos-repo.json" "$THIS_INDEX_URL" <<'EOF'
import json, sys
path, index_url = sys.argv[1], sys.argv[2]
card = {
    "schemaVersion": 1,
    "name": "muster",
    "displayName": "Muster",
    "description": "Muster: rooms where people agree on a payment, a bill split or a decision, "
                   "then settle it. Publishes only muster_module and muster_ui; every dependency "
                   "comes from the official Logos catalogue. Unsigned.",
    "homepage": "https://github.com/corpetty/muster/tree/main/catalog",
    "indexUrl": index_url,
    "trustedSigners": [],
}
open(path, "w").write(json.dumps(card, indent=2) + "\n")
EOF
python3 "$TOOL" validate-repo "$OUT/logos-repo.json" >/dev/null

# 4. The index: add this release's two packages (a release keeps every earlier version;
#    a local index starts empty). Versions dedupe on (version, rootHash), so re-running a
#    release is a no-op, and a rebuild that changed the bytes of a published version shows
#    up as a second entry for it, which `validate` reports.
if [ ! -f "$OUT/index.json" ]; then
  python3 - "$OUT/index.json" <<'EOF'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
idx = {"schemaVersion": 2, "repositoryName": "muster", "generatedAt": now, "packages": []}
open(sys.argv[1], "w").write(json.dumps(idx, indent=2) + "\n")
EOF
fi
PAIRS=()
for pkg in muster_module muster_ui; do
  PAIRS+=(--with-local "$URL_BASE/$(asset "$pkg")" "$ASSETS/$(asset "$pkg")")
done
python3 "$TOOL" add "$OUT/index.json" --fetch none "${PAIRS[@]}"
python3 "$TOOL" validate "$OUT/index.json"
python3 "$TOOL" list "$OUT/index.json"

# The catalogue must name only our packages: a catalogue can shadow any name it lists.
python3 - "$OUT/index.json" <<'EOF'
import json, sys
names = {p["name"] for p in json.load(open(sys.argv[1]))["packages"]}
extra = names - {"muster_module", "muster_ui"}
if extra:
    sys.exit(f"index lists packages that are not ours: {sorted(extra)}")
EOF

echo
echo "commit $COMMIT, version $VERSION"
for pkg in muster_module muster_ui; do
  echo "  $(sha256sum "$ASSETS/$(asset "$pkg")" | cut -c1-64)  $ASSETS/$(asset "$pkg")"
done
if [ -n "$LOCAL" ]; then
  echo
  echo "local catalogue in $OUT; serve it at $BASE and add $BASE/logos-repo.json in"
  echo "Basecamp: Settings -> Package Repositories."
  exit 0
fi
cat <<EOF

Nothing is published. To publish $TAG:
  1. gh release create $TAG --repo corpetty/muster --target $COMMIT \\
       --title "Muster $VERSION" --notes "Muster $VERSION for Basecamp (linux-amd64). Install: docs/runbooks/install-from-catalogue.md" \\
       $ASSETS/$(asset muster_module) $ASSETS/$(asset muster_ui)
  2. check each asset downloads:  curl -sSfLI $URL_BASE/$(asset muster_ui) | head -1
  3. git add catalog/index.json catalog/icons && git commit (Tested-Behavior trailer), PR to main.
Basecamp reads $REPO_URL from main.
EOF
