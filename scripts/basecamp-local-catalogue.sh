#!/usr/bin/env bash
# Muster in Basecamp 0.3.2 the way a person installs it, but from THIS checkout (exo-720.1,
# docs/runbooks/ui-redesign-review.md Part B). Basecamp installs Muster from a catalogue
# served on this machine and resolves every dependency from the official Logos catalogue,
# in a profile of its own, so nothing of yours is read or changed:
#
#   scripts/basecamp-local-catalogue.sh [NAME] [--fresh] [--no-build] [--port N] [--xvfb :N]
#
#   1. Basecamp 0.3.2's AppImage (infra/basecamp/release-0.3.2.env), downloaded once, checked
#      and extracted (no FUSE needed);
#   2. the catalogue: scripts/catalog-release.sh --local, built from the COMMITTED tree (it
#      refuses uncommitted module/ or ui/ changes), capped at BUILD_MEM if set, as `make build` is;
#   3. a throwaway CA and a certificate for 127.0.0.1: Basecamp accepts only https for a
#      repository and its downloads (docs/design/catalogue-install.md §7);
#   4. an https server for the catalogue, for as long as Basecamp runs;
#   5. Basecamp, with HOME, the XDG directories and --user-dir all under
#      .run/basecamp/<NAME>/, trusting that CA through SSL_CERT_FILE.
#
#   NAME        the profile (default: review)
#   --fresh     wipe that profile first, for an install from nothing
#   --no-build  reuse the catalogue already in .run/basecamp/local-catalogue
#   --port N    the server's port (default 8743)
#   --xvfb :N   on a virtual display, for a machine with no screen (Qt's software renderer;
#               icons tinted through MultiEffect draw blank there). Screenshots:
#               import -display :N -window root shot.png
#
# It prints the repository URL to add in Basecamp; then Applications → muster → untick
# Monero Node (local) → Install → Launch (docs/runbooks/install-from-catalogue.md §2).
# Quitting Basecamp stops the server. Log: .run/basecamp/<NAME>.log (capped).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NAME=review; FRESH=0; BUILD=1; PORT=8743; XDISPLAY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    --no-build) BUILD=0 ;;
    --port) PORT=${2:?--port needs a number}; shift ;;
    --xvfb) XDISPLAY=${2:?--xvfb needs a display, e.g. :97}; shift ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) NAME=$1 ;;
  esac
  shift
done
. infra/basecamp/release-0.3.2.env
BASE=$ROOT/.run/basecamp
CAT=$BASE/local-catalogue
TLS=$BASE/tls
PROFILE=$BASE/$NAME
URL=https://127.0.0.1:$PORT
mkdir -p "$BASE"

# 1. the release
APPRUN=$BASE/squashfs-$BASECAMP_TAG/AppRun
if [ ! -x "$APPRUN" ]; then
  IMG=$BASE/LogosBasecamp-$BASECAMP_TAG.AppImage
  [ -f "$IMG" ] || { echo "downloading Basecamp $BASECAMP_TAG (about 290 MB)…"; curl -fsSL -o "$IMG" "$BASECAMP_URL"; }
  echo "$BASECAMP_SHA256  $IMG" | sha256sum -c --quiet
  chmod +x "$IMG"
  (cd "$BASE" && rm -rf squashfs-root && "$IMG" --appimage-extract >/dev/null && mv squashfs-root "squashfs-$BASECAMP_TAG")
fi

# 2. the catalogue, memory-capped like the Makefile's builds when BUILD_MEM is set
#    (uncapped by default)
if [ $BUILD = 1 ] || [ ! -f "$CAT/logos-repo.json" ]; then
  MEM=${BUILD_MEM-}
  CAP=()
  [ -n "$MEM" ] && CAP=(systemd-run --user --scope --quiet -p "MemoryMax=$MEM" -p MemorySwapMax=0 nice -n 19)
  echo "building the catalogue from $(git rev-parse --short HEAD)${MEM:+ (memory-capped at $MEM)}; the first time takes a while…"
  rc=0; "${CAP[@]}" scripts/catalog-release.sh --local "$CAT" --base-url "$URL" || rc=$?
  [ $rc = 137 ] && { echo "killed at the BUILD_MEM=$MEM cap: free memory, or build when the host is quieter"; exit 137; }
  [ $rc = 0 ] || exit $rc
fi
# a catalogue built for another port names the wrong download URLs
grep -q "\"$URL/" "$CAT/index.json" || { echo "the catalogue in $CAT was built for another port; drop --no-build"; exit 1; }

# 3. a CA of our own, and a certificate it signs for 127.0.0.1
if [ ! -f "$TLS/server.pem" ]; then
  mkdir -p "$TLS"
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$TLS/ca.key" -out "$TLS/ca.pem" \
    -subj "/CN=Muster local catalogue CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$TLS/server.key" -out "$TLS/server.csr" -subj "/CN=127.0.0.1" 2>/dev/null
  printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' >"$TLS/ext"
  openssl x509 -req -in "$TLS/server.csr" -CA "$TLS/ca.pem" -CAkey "$TLS/ca.key" -CAcreateserial \
    -days 365 -extfile "$TLS/ext" -out "$TLS/server.pem" 2>/dev/null
fi
SYSBUNDLE=""
for f in "${SSL_CERT_FILE:-}" "${NIX_SSL_CERT_FILE:-}" /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
  [ -n "$f" ] && [ -f "$f" ] && { SYSBUNDLE=$f; break; }
done
[ -n "$SYSBUNDLE" ] || { echo "no system CA bundle found (set SSL_CERT_FILE)"; exit 1; }
cat "$SYSBUNDLE" "$TLS/ca.pem" >"$TLS/bundle.pem"

# 4. the server
python3 - "$CAT" "$PORT" "$TLS/server.pem" "$TLS/server.key" >"$BASE/server.log" 2>&1 <<'EOF' &
import functools, http.server, ssl, sys
root, port, cert, key = sys.argv[1:5]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
EOF
SERVER=$!
XVFB=""
trap 'kill $SERVER 2>/dev/null; [ -n "$XVFB" ] && kill $XVFB 2>/dev/null; true' EXIT
for _ in $(seq 50); do
  curl -fsS --cacert "$TLS/ca.pem" "$URL/logos-repo.json" >/dev/null 2>&1 && break
  kill -0 $SERVER 2>/dev/null || { echo "the server did not start:"; cat "$BASE/server.log"; exit 1; }
  sleep 0.2
done
curl -fsS --cacert "$TLS/ca.pem" "$URL/logos-repo.json" >/dev/null || { echo "$URL/logos-repo.json does not answer over https"; exit 1; }

# 5. Basecamp, on a profile of its own
if pgrep -f -- "--user-dir $PROFILE/user\$" >/dev/null; then
  echo "Basecamp is already running on $PROFILE; quit it first" >&2; exit 1
fi
[ $FRESH = 1 ] && rm -rf "$PROFILE"
mkdir -p "$PROFILE/home" "$PROFILE/user"
H=$PROFILE/home
UNSET=()
ENV=(HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" XDG_CACHE_HOME="$H/.cache"
     XDG_STATE_HOME="$H/.local/state" SSL_CERT_FILE="$TLS/bundle.pem")
# the display still needs the real user's X authority once HOME moves
[ -z "${XAUTHORITY:-}" ] && [ -f "$HOME/.Xauthority" ] && ENV+=(XAUTHORITY="$HOME/.Xauthority")
if [ -n "$XDISPLAY" ]; then
  if ! [ -e "/tmp/.X11-unix/X${XDISPLAY#:}" ]; then
    XV=$(command -v Xvfb || true)
    [ -n "$XV" ] || XV=$(nix build nixpkgs#xvfb --no-link --print-out-paths | tail -1)/bin/Xvfb
    "$XV" "$XDISPLAY" -screen 0 1440x900x24 -nolisten tcp >/dev/null 2>&1 &
    XVFB=$!
    sleep 2
  fi
  ENV+=(DISPLAY="$XDISPLAY" QT_QPA_PLATFORM=xcb QT_QUICK_BACKEND=software)
  UNSET=(-u WAYLAND_DISPLAY)
fi
LOG=$BASE/$NAME.log
cat <<MSG

Basecamp $BASECAMP_TAG, profile $PROFILE
  Add this repository (Settings → Package Repositories → Add a repository):

      $URL/logos-repo.json

  then Applications → search "muster" → Muster → untick Monero Node (local) → Install → Launch.
  Log: $LOG    Quit Basecamp to stop the catalogue server.

MSG
env "${UNSET[@]}" "${ENV[@]}" "$APPRUN" --user-dir "$PROFILE/user" 2>&1 | python3 scripts/lib/caplog.py "$LOG" || true
echo "Basecamp exited; the catalogue server is stopped."
