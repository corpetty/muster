#!/usr/bin/env bash
# Muster's own Basecamp catalogue (exo-dcc.3, docs/design/catalogue-install.md §3 step 2).
# Builds muster_module and muster_ui as .#lgx-portable from the COMMITTED tree and writes
# the catalogue's two files with logos-modules-release-tool's index.py (`add --with-local`),
# the way the Logos Forum catalogue (edenbd1/logos-forum-catalog) does it: a committed
# index.json, the .lgx files as GitHub release assets.
#
#   scripts/catalog-release.sh                       # a release: catalog/ + .run/catalog-release/<tag>/,
#                                                    # every platform, from CI's build of HEAD (exo-04f)
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
#   --here             build muster_module and muster_ui here, for this host's platform only,
#                      instead of taking every platform from CI (the default for a release)
#   --from-run ID      take the packages from a successful run of the `lgx variants` workflow
#                      (.github/workflows/lgx-variants.yml) instead of building here: one .lgx
#                      per package holding every variant it builds (linux-amd64, linux-arm64,
#                      darwin-arm64). The run must have built exactly HEAD. Assets are then
#                      named <package>-<version>.lgx, as the official catalogue names its own.
#
# A release ships every platform by default (exo-04f): muster_module and muster_ui come from
# the `lgx variants` run that built HEAD, and when there is none the workflow is dispatched on
# HEAD's branch (which must be pushed, at HEAD) and waited for. With --here, or with --local,
# the packages are built here for this host's platform (scripts/lib/portable.sh): a release
# built that way still must carry linux-amd64; --local is open to every platform, e.g. for a
# Mac to test its own build.
#
# The catalogue publishes muster_module and muster_ui, and the private lez-msig's two provers
# (exo-e77, exo-cc7): lez_msig_module (programs/lez-msig) for a LEZ v0.3 zone and
# lez_msig_v04_module (programs/lez-msig/lez04) for a v0.4 one, OPTIONAL dependencies of
# muster_module, built for linux-amd64 only and versioned on their own. Every other
# dependency resolves from the
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
. scripts/lib/portable.sh

# Pins. index.py is one stdlib-only Python file; the hash is of that file at TOOL_REV.
TOOL_REV=94462e6633f2b536424c10ceda3c371f7ec8e09d
TOOL_SHA256=ef608d0ce5a22a1339d9a53043cdcd056c027db406e1c2fcac2e3ad17ea98c34
# index.py needs `lgx` (with `semver`) on PATH to read and order packages; logos-package
# master as of 2026-10-01, the rev logos-basecamp 0.3.2 also locks.
LGX_FLAKE=github:logos-co/logos-package/c25a1167578aef5cbd9a9b6f822ffe2ae4fd6a89#lgx

REPO_URL=https://raw.githubusercontent.com/corpetty/muster/main/catalog/logos-repo.json
INDEX_URL=https://raw.githubusercontent.com/corpetty/muster/main/catalog/index.json
RELEASES=https://github.com/corpetty/muster/releases/download
SUB=(--extra-substituters https://cache.nix.logos.co)

TAG=""; URL_BASE=""; LOCAL=""; BASE_URL=""; ALLOW_DIRTY=0; FROM_RUN=""; HERE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=${2:?--tag needs a value}; shift ;;
    --url-base) URL_BASE=${2:?--url-base needs a URL}; shift ;;
    --local) LOCAL=${2:?--local needs a directory}; shift ;;
    --base-url) BASE_URL=${2:?--base-url needs a URL}; shift ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --from-run) FROM_RUN=${2:?--from-run needs a workflow run id}; shift ;;
    --here) HERE=1 ;;
    -h|--help) awk 'NR > 1 { if (/^set -euo/) exit; print }' "$0"; exit 0 ;;
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
# A release takes every platform from CI's build of HEAD, unless asked to build here.
if [ -z "$FROM_RUN" ] && [ -z "$LOCAL" ] && [ $HERE = 0 ]; then
  HEAD_SHA=$(git rev-parse HEAD)
  FROM_RUN=$(gh run list --repo corpetty/muster --workflow "lgx variants" --commit "$HEAD_SHA" --status success \
               --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
  if [ -z "$FROM_RUN" ]; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git fetch -q origin "$BRANCH" 2>/dev/null || true
    [ "$(git rev-parse "origin/$BRANCH" 2>/dev/null)" = "$HEAD_SHA" ] || {
      echo "no lgx variants run built $HEAD_SHA, and origin/$BRANCH is not HEAD: push it, or build here with --here" >&2; exit 1; }
    echo "no lgx variants run built ${HEAD_SHA:0:8}: dispatching one on $BRANCH and waiting (every platform, about 20 minutes)"
    gh workflow run lgx-variants.yml --repo corpetty/muster --ref "$BRANCH"
    for _ in $(seq 30); do
      sleep 10
      FROM_RUN=$(gh run list --repo corpetty/muster --workflow "lgx variants" --commit "$HEAD_SHA" --event workflow_dispatch \
                   --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
      [ -n "$FROM_RUN" ] && break
    done
    [ -n "$FROM_RUN" ] || { echo "the dispatched lgx variants run did not appear" >&2; exit 1; }
    gh run watch "$FROM_RUN" --repo corpetty/muster --exit-status >/dev/null \
      || { echo "lgx variants run $FROM_RUN failed: gh run view $FROM_RUN --repo corpetty/muster --log-failed" >&2; exit 1; }
  fi
  echo "every platform from lgx variants run $FROM_RUN (commit ${HEAD_SHA:0:8})"
fi
# The variants each package must carry: every one the workflow builds, or this host's.
if [ -n "$FROM_RUN" ]; then PLATFORMS="linux-amd64 linux-arm64 darwin-arm64"; else PLATFORMS=$(lgx_variant); fi
if [ -z "$LOCAL" ]; then
  case " $PLATFORMS " in
    *" linux-amd64 "*) ;;
    *) echo "a release carries linux-amd64, as every published muster version does; one built here would carry only $PLATFORMS." >&2
       echo "Release from the lgx variants workflow (--from-run), or build here with --local to test." >&2
       exit 1 ;;
  esac
fi
# one platform: <package>-<version>-<platform>.lgx (every release before 0.3.1); several: the
# official catalogue's <package>-<version>.lgx. The prover is linux-amd64 only, at its own version.
MSIG_VERSION=$(ver programs/lez-msig/metadata.json)
MSIG04_VERSION=$(ver programs/lez-msig/lez04/metadata.json)
asset() {
  if [ "$1" = lez_msig_module ]; then echo "$1-$MSIG_VERSION-linux-amd64.lgx"
  elif [ "$1" = lez_msig_v04_module ]; then echo "$1-$MSIG04_VERSION-linux-amd64.lgx"
  elif [ "$PLATFORMS" = "${PLATFORMS%% *}" ]; then echo "$1-$VERSION-$PLATFORMS.lgx"; else echo "$1-$VERSION.lgx"; fi; }
PACKAGES="muster_module muster_ui lez_msig_module lez_msig_v04_module"

# The committed tree, never a working copy.
if [ $ALLOW_DIRTY = 0 ] && [ -n "$(git status --porcelain -- module ui programs/lez-msig)" ]; then  # lez04 included
  echo "module/, ui/ or programs/lez-msig/ has uncommitted changes; commit them (the build reads the committed tree)" >&2
  git status --short -- module ui programs/lez-msig >&2; exit 1
fi
COMMIT=$(git rev-parse HEAD)

WORK=$ROOT/.run/catalog-release
mkdir -p "$WORK/tool"

# index.py at its pinned rev, checked. (Not `echo … | sha256sum -c --quiet`: Darwin's -c reads
# stdin only when given `-`, and older macOS has no sha256sum.)
TOOL=$WORK/tool/index-$TOOL_REV.py
if [ "$(sha256_of "$TOOL" 2>/dev/null)" != "$TOOL_SHA256" ]; then
  curl -sSfL -o "$TOOL" "https://raw.githubusercontent.com/logos-co/logos-modules-release-tool/$TOOL_REV/index.py"
  [ "$(sha256_of "$TOOL")" = "$TOOL_SHA256" ] \
    || { echo "$TOOL: sha256 $(sha256_of "$TOOL"), expected $TOOL_SHA256" >&2; exit 1; }
fi
# index.py annotates with `str | None`, which Python 3.9 (macOS's /usr/bin/python3) cannot
# even import; say so now, not after the build.
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
  || { echo "index.py needs python3 >= 3.10; $(command -v python3) is $(python3 -V 2>&1)" >&2; exit 1; }
LGX=$(nix build "$LGX_FLAKE" "${SUB[@]}" --no-link --print-out-paths 2>/dev/null | tail -1)/bin
[ -x "$LGX/lgx" ] || { echo "could not build lgx ($LGX_FLAKE)" >&2; exit 1; }
export PATH="$LGX:$PATH"

# 1. The packages, as scripts/basecamp-profile.sh builds them (.#lgx-portable: the release
#    accepts only the portable variant), with muster_module overridden to this clone's
#    absolute git+file path and the eval cache off, as `make build` does (exo-fb7). Or, with
#    --from-run, the merged packages that workflow run built from this same commit.
if [ -n "$FROM_RUN" ]; then
  run=$(gh run view "$FROM_RUN" --repo corpetty/muster --json headSha,conclusion,workflowName \
          --jq '"\(.workflowName)|\(.conclusion)|\(.headSha)"') \
    || { echo "cannot read workflow run $FROM_RUN" >&2; exit 1; }
  IFS='|' read -r wf concl sha <<<"$run"
  [ "$wf" = "lgx variants" ] || { echo "run $FROM_RUN is '$wf', not 'lgx variants'" >&2; exit 1; }
  [ "$concl" = "success" ] || { echo "run $FROM_RUN did not succeed ($concl)" >&2; exit 1; }
  [ "$sha" = "$COMMIT" ] || { echo "run $FROM_RUN built $sha; HEAD is $COMMIT" >&2; exit 1; }
  RUNDIR=$WORK/run-$FROM_RUN
  rm -rf "$RUNDIR"; mkdir -p "$RUNDIR/module" "$RUNDIR/ui"
  gh run download "$FROM_RUN" --repo corpetty/muster -n lgx-merged -D "$RUNDIR/dl"
  mv "$RUNDIR/dl/muster_module.lgx" "$RUNDIR/module/"; mv "$RUNDIR/dl/muster_ui.lgx" "$RUNDIR/ui/"
  MOD=$RUNDIR/module; UI=$RUNDIR/ui
  echo "muster_module and muster_ui $VERSION from run $FROM_RUN (commit $COMMIT)"
else
echo "building muster_module and muster_ui $VERSION from $COMMIT"
MOD=$(nix build "git+file://$ROOT?dir=module#lgx-portable" "${SUB[@]}" --no-eval-cache \
        --no-link --print-out-paths 2>"$WORK/build-module.log" | tail -1) \
  || { echo "module build failed; see $WORK/build-module.log" >&2; exit 1; }
UI=$(nix build "git+file://$ROOT?dir=ui#lgx-portable" "${SUB[@]}" --no-eval-cache \
        --override-input muster_module "git+file://$ROOT?dir=module" \
        --override-input lez_msig_module "git+file://$ROOT?dir=programs/lez-msig" \
        --override-input lez_msig_v04_module "git+file://$ROOT?dir=programs/lez-msig/lez04" \
        --no-link --print-out-paths 2>"$WORK/build-ui.log" | tail -1) \
  || { echo "ui build failed; see $WORK/build-ui.log" >&2; exit 1; }
fi
# The provers, here in every mode: the workflow does not build them, and they build only on
# linux-amd64 (a --local test elsewhere goes without them).
MSIG=""; MSIG04=""
if [ "$(lgx_variant)" = linux-amd64 ]; then
  echo "building lez_msig_module $MSIG_VERSION from $COMMIT"
  MSIG=$(nix build "git+file://$ROOT?dir=programs/lez-msig#lgx-portable" "${SUB[@]}" --no-eval-cache \
          --no-link --print-out-paths 2>"$WORK/build-msig.log" | tail -1) \
    || { echo "lez_msig_module build failed; see $WORK/build-msig.log" >&2; exit 1; }
  echo "building lez_msig_v04_module $MSIG04_VERSION from $COMMIT"
  MSIG04=$(nix build "git+file://$ROOT?dir=programs/lez-msig/lez04#lgx-portable" "${SUB[@]}" --no-eval-cache \
          --no-link --print-out-paths 2>"$WORK/build-msig04.log" | tail -1) \
    || { echo "lez_msig_v04_module build failed; see $WORK/build-msig04.log" >&2; exit 1; }
elif [ -z "$LOCAL" ]; then
  echo "a release carries the lez-msig provers, which build on linux-amd64 only; release from a linux-amd64 host" >&2; exit 1
else
  PACKAGES="muster_module muster_ui"
fi

# Each package's embedded manifest must carry the name and version the catalogue claims.
for pair in "muster_module:$MOD" "muster_ui:$UI" ${MSIG:+"lez_msig_module:$MSIG"} ${MSIG04:+"lez_msig_v04_module:$MSIG04"}; do
  pkg=${pair%%:*}; f=$(ls "${pair#*:}"/*.lgx | head -1)
  lgx verify "$f" >/dev/null
  got=$(lgx manifest "$f" --json | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["name"], m["version"], " ".join(sorted(m.get("main", {}))))')
  if [ "$pkg" = lez_msig_module ]; then want="$pkg $MSIG_VERSION linux-amd64"
  elif [ "$pkg" = lez_msig_v04_module ]; then want="$pkg $MSIG04_VERSION linux-amd64"
  else want="$pkg $VERSION $(tr ' ' '\n' <<<"$PLATFORMS" | sort | paste -sd' ' -)"; fi
  [ "$got" = "$want" ] || { echo "$f: manifest says '$got', expected '$want'" >&2; exit 1; }
  # No `declare -A` (bash 3.2 on macOS): a variable per package.
  case $pkg in muster_module) SRC_MOD=$f ;; muster_ui) SRC_UI=$f ;; lez_msig_module) SRC_MSIG=$f ;; lez_msig_v04_module) SRC_MSIG04=$f ;; esac
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
for pkg in $PACKAGES; do
  case $pkg in muster_module) src=$SRC_MOD ;; muster_ui) src=$SRC_UI ;; lez_msig_module) src=$SRC_MSIG ;; lez_msig_v04_module) src=$SRC_MSIG04 ;; esac
  install -m 0644 "$src" "$ASSETS/$(asset "$pkg")"
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
                   "then settle it. Publishes muster_module and muster_ui, and the private multisig's "
                   "provers, lez_msig_module (LEZ v0.3) and lez_msig_v04_module (LEZ v0.4), optional, "
                   "linux-amd64; every other dependency comes "
                   "from the official Logos catalogue. Unsigned.",
    "homepage": "https://github.com/corpetty/muster/tree/main/catalog",
    "indexUrl": index_url,
    "trustedSigners": [],
}
open(path, "w").write(json.dumps(card, indent=2) + "\n")
EOF
python3 "$TOOL" validate-repo "$OUT/logos-repo.json" >/dev/null

# 4. The index: add this release's packages (a release keeps every earlier version;
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
for pkg in $PACKAGES; do
  PAIRS+=(--with-local "$URL_BASE/$(asset "$pkg")" "$ASSETS/$(asset "$pkg")")
done
python3 "$TOOL" add "$OUT/index.json" --fetch none "${PAIRS[@]}"
python3 "$TOOL" validate "$OUT/index.json"
python3 "$TOOL" list "$OUT/index.json"

# The catalogue must name only our packages: a catalogue can shadow any name it lists.
python3 - "$OUT/index.json" <<'EOF'
import json, sys
names = {p["name"] for p in json.load(open(sys.argv[1]))["packages"]}
extra = names - {"muster_module", "muster_ui", "lez_msig_module", "lez_msig_v04_module"}
if extra:
    sys.exit(f"index lists packages that are not ours: {sorted(extra)}")
EOF

echo
echo "commit $COMMIT, version $VERSION"
for pkg in $PACKAGES; do
  echo "  $(sha256_of "$ASSETS/$(asset "$pkg")")  $ASSETS/$(asset "$pkg")"
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
       --title "Muster $VERSION" --notes "Muster $VERSION for Basecamp (${PLATFORMS// /, }). Install: docs/runbooks/install-from-catalogue.md" \\
       $(for p in $PACKAGES; do printf '%s ' "$ASSETS/$(asset "$p")"; done)
  2. check each asset downloads:  curl -sSfLI $URL_BASE/$(asset muster_ui) | head -1
  3. git add catalog/index.json catalog/icons && git commit (Tested-Behavior trailer), PR to main.
Basecamp reads $REPO_URL from main.
EOF
