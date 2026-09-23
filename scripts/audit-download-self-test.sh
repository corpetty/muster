#!/usr/bin/env bash
# Offscreen proof of "Download audit trail" (exo-403 s8, derived-exo-403): one runner
# joins a room, picks the room-native threshold policy, proposes, approves in-app, and
# downloads the intent's audit file — through the SAME backend slot the card's button
# calls (downloadAudit). Then, with nothing but the saved file, the standalone
# verifier must accept it, and the saved report must carry the file's digest.
#
# Honest scope: the offscreen runner cannot click (the qt-mcp UI-e2e route is
# blocked), so the click is covered by asserting the button is wired to that slot;
# the slot itself — module export, file writing, verification — runs for real.
#
# stderr: the narrative. stdout: ONE JSON document, the property_test trace
# {"traces": [[{"download_verified": bool}, ...]]} — one observation per check.
# Needs: `make build` (the runner), and the probe build closure in /tmp/nimpkgs
# (tests/README.md) for the verifier.
set -uo pipefail
cd "$(dirname "$0")/.."
say() { echo "$@" >&2; }
obs=()
check() { local ok=$1; shift; say "$([ "$ok" = 1 ] && echo PASS || echo FAIL): $*"; obs+=("$ok"); }
emit() {
  local out="" sep=""
  for o in "${obs[@]}"; do out+="$sep{\"download_verified\": $([ "$o" = 1 ] && echo true || echo false)}"; sep=", "; done
  echo "{\"traces\": [[${out}]]}"
}

RUNNER=".run/runner/bin/muster-ui"
[ -x "$RUNNER" ] || { say "build the runner first: make build"; obs+=(0); emit; exit 1; }
D=$(mktemp -d)

# ── the standalone verifier (reads only the file) ─────────────────────────────
P=/tmp/nimpkgs
SODIUM=$(nix build nixpkgs#libsodium --no-link --print-out-paths 2>/dev/null | head -1)
if ! (cd module && nim c -d:release --hints:off --warnings:off --threads:on \
      --path:$P/nim-secp256k1 --path:$P/nim-stew --path:$P/nim-results --path:$P/nimcrypto \
      --path:$P/nim-stint --path:$P/nim-intops/src --passL:"$SODIUM/lib/libsodium.so" \
      -o:"$D/muster-audit-verify" tools/muster_audit_verify.nim >"$D/verify-build.log" 2>&1); then
  say "could not build the verifier — see $D/verify-build.log"; obs+=(0); emit; exit 1
fi

# ── the runner: join → threshold → propose → approve in-app → downloadAudit ───
CFG=$(python3 -c 'import json;print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))')
TOPIC="/muster/1/audittest-$(date +%s)/proto"
EFFECT='{"effect":"statement","text":"audit self-test"}'
OUT="$D/out"
say "topic: $TOPIC"
MUSTER_AUTOADMIT=1 MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" \
MUSTER_AUTOPOLICY=threshold MUSTER_AUTOPROPOSE="$EFFECT" MUSTER_AUTOAPPROVE=1 MUSTER_AUTOAUDIT=1 \
MUSTER_AUDIT_DIR="$OUT" LOGOS_INSTANCE_ID=audittest QT_QPA_PLATFORM=offscreen \
  setsid "$RUNNER" --user-dir "$D/A" >"$D/A.log" 2>&1 &
say "runner launched offscreen; waiting for the audit download (up to 60s)..."
for _ in $(seq 1 12); do
  sleep 5
  ls "$OUT"/muster-audit-*.cbor >/dev/null 2>&1 && ls "$OUT"/muster-audit-*.md >/dev/null 2>&1 && break
done
pkill -9 -f "user-dir $D" 2>/dev/null; pkill -9 -f logos_host_qt 2>/dev/null

CBOR=$(ls "$OUT"/muster-audit-*.cbor 2>/dev/null | head -1)
MD=$(ls "$OUT"/muster-audit-*.md 2>/dev/null | head -1)
check $([ -n "$CBOR" ] && [ -n "$MD" ] && echo 1 || echo 0) "both files saved ($CBOR, $MD)"
grep -a 'MUSTER-LP audit' "$D/A.log" | tail -1 | sed 's/.*MUSTER-LP audit /module: /' >&2

# ── the verifier, given only the saved file ───────────────────────────────────
VERDICT=""
[ -n "$CBOR" ] && VERDICT=$("$D/muster-audit-verify" "$CBOR" 2>/dev/null)
say "verdict: ${VERDICT:0:400}"
OK=$(echo "$VERDICT" | python3 -c 'import sys,json
try: v=json.load(sys.stdin); print(1 if v["ok"] and any(a["grade"]=="committed" for a in v["approvals"]) else 0)
except Exception: print(0)')
check "$OK" "the standalone verifier accepts the saved file (with a committed approval)"
DIGEST=$(echo "$VERDICT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["digest"])
except Exception: print("")')
check $([ -n "$DIGEST" ] && [ -n "$MD" ] && grep -q "$DIGEST" "$MD" && echo 1 || echo 0) "the saved report carries the file's digest"

# ── the button is wired to that slot ──────────────────────────────────────────
WIRED=0
grep -q 'objectName: "cardDownloadAudit"' ui/src/qml/MusterCard.qml &&
  grep -q 'onClicked: cardRoot.downloadAudit()' ui/src/qml/MusterCard.qml &&
  grep -q 'onDownloadAudit: if (room.backend && msg.liveIntent) room.backend.downloadAudit(' ui/src/qml/Room.qml &&
  grep -q 'SLOT(void downloadAudit(const QString &intentId))' ui/src/muster_ui.rep && WIRED=1
check "$WIRED" "the card's Download audit trail button calls backend.downloadAudit"

if grep -aiE 'qrc:/.*(error|TypeError|ReferenceError)|QQmlApplicationEngine failed|is not a type' "$D/A.log" >&2; then
  check 0 "QML loaded without errors"
else
  check 1 "QML loaded without errors"
fi

emit
all=1; for o in "${obs[@]}"; do [ "$o" = 1 ] || all=0; done
[ "$all" = 1 ] && { say "SUCCESS: downloaded, saved, and verified from the file alone."; rm -rf "$D"; } || say "FAILED — see $D"
exit $((1-all))
