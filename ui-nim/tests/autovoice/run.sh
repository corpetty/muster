#!/usr/bin/env bash
# The Nim backend's voice autopilot (docs/design/voice-notes.md S9), without Qt or a runner:
# ui-nim/app/backend.nim compiled whole against stubs made from muster_ui.rep and
# muster.lidl and a fake muster_module (gen.py, fake_module.nim), its timers run in real
# time. It runs where ui-nim's flake does not build (a Mac) as well as on Linux. It checks the
# autopilot's decisions only; scripts/voice-self-test.sh checks a note between two runners.
#   recorder (MUSTER_AUTOVOICE=1): Start, Stop about a second after the first voice_status
#     that says recording (the fake starts the device for 1.5 s, as the module answers Start
#     at once and starts it on a thread of its own), Send, each once, each answer logged as
#     VOICE-RESULT, and the thread showing the sent note as one's own;
#   player (MUSTER_AUTOVOICEPLAY=1), over a thread holding an arriving note, one's own
#     complete note, two complete notes from another member, a message whose body claims a
#     note and a note whose Play is always refused: Play for the two, one at a time, each
#     once, never the arriving note, one's own or the claimed one, and the refused Play
#     tried five times, no more; voice_status logged as VOICE, each note playing then not.
#
#   ui-nim/tests/autovoice/run.sh                    # the tree's backend
#   ui-nim/tests/autovoice/run.sh <dir>/backend.nim  # another (its sched.nim beside it)
# nim: the one on PATH, else ui-nim's own nixpkgs pin's (read off ui-nim/flake.lock, never by
# evaluating that flake). KEEP=1 keeps the build and the logs.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
BACKEND="${1:-ui-nim/app/backend.nim}"
[ -f "$BACKEND" ] || { echo "no backend at $BACKEND"; exit 2; }
BACKEND="$(cd "$(dirname "$BACKEND")" && pwd)/$(basename "$BACKEND")"
for v in $(env | grep -o '^MUSTER_[A-Z0-9_]*'); do unset "$v"; done   # only what each role sets

if ! command -v nim >/dev/null 2>&1; then
  pin=$(python3 -c 'import json; n = json.load(open("ui-nim/flake.lock"))["nodes"]["upstream"]["locked"]
print("github:%s/%s/%s" % (n["owner"], n["repo"], n["rev"]))') || exit 1
  NIM=$(nix build "$pin#nim" --no-link --print-out-paths 2>/dev/null | tail -1)
  [ -x "$NIM/bin/nim" ] || { echo "no nim on PATH, and $pin#nim did not build"; exit 1; }
  export PATH="$NIM/bin:$PATH"
fi
OUT=$(mktemp -d)
python3 ui-nim/tests/autovoice/gen.py . "$OUT" "$BACKEND" || exit 1
# the app's own memory and thread settings (ui-nim/nix/seaqt-app.nix)
nim c --mm:orc --threads:on --hints:off --warnings:off --nimcache:"$OUT/cache" --path:"$OUT" \
  -o:"$OUT/h" "$OUT/harness.nim" >"$OUT/build.log" 2>&1 \
  || { cat "$OUT/build.log"; echo "FAIL: the harness did not build ($OUT)"; exit 1; }
echo "built $(nim --version 2>/dev/null | head -1) against $BACKEND"

row() {  # row <id> <note> <state> <self>: a thread row carrying a note, as threadRows gives it
  printf '{"id":"%s","author":"%s","ts":1,"body":"","alias":"","self":%s,"voice":{"v":1,"note":"%s","durationMs":3000,"state":"%s"}}' \
    "$1" "$([ "$4" = true ] && echo aa || echo bb)" "$4" "$2" "$3"
}
FORGED='{"id":"e11","author":"bb","ts":1,"alias":"","self":false,"body":"{\"kind\":\"voice-note\",\"v\":1,\"note\":\"n11\",\"durationMs\":3000,\"state\":\"complete\"}"}'
ROWS="[$(row e7 n7 arriving false),$(row e8 n8 complete true),$(row e9 n9 complete false),$(row e10 n10 complete false),$FORGED,$(row e12 n12 complete false)]"

# contextReady autojoins after 5 s, and the room's tick runs each second from then on
MUSTER_AUTOJOIN_TOPIC=/muster/1/t/proto MUSTER_AUTOVOICE=1 HARNESS_SECS=13 \
  "$OUT/h" >"$OUT/recorder.out" 2>"$OUT/recorder.err"
MUSTER_AUTOJOIN_TOPIC=/muster/1/t/proto MUSTER_AUTOVOICEPLAY=1 HARNESS_SECS=24 \
  HARNESS_ROWS="$ROWS" HARNESS_REFUSE=n12 "$OUT/h" >"$OUT/player.out" 2>"$OUT/player.err"

python3 - "$OUT" <<'EOF'
import json, sys
out = sys.argv[1]
def run(role):
    o = open("%s/%s.out" % (out, role)).read().splitlines()
    calls = json.loads([l for l in o if l.startswith("HARNESS-CALLS ")][-1].split(" ", 1)[1])
    gaps = json.loads([l for l in o if l.startswith("HARNESS-GAPS-MS ")][-1].split(" ", 1)[1])
    rec = [int(l.split(" ", 1)[1]) for l in o if l.startswith("HARNESS-RECORDING-AFTER-MS ")]
    if role == "recorder": gaps = gaps + [rec[-1] if rec else -1]
    log = [l.split("] ", 1)[1] for l in open("%s/%s.err" % (out, role)) if l.startswith("[muster_ui] ")]
    return calls, gaps, log
def tagged(log, tag): return [l[len(tag) + 1:] for l in log if l.startswith(tag + " ")]
errs = []

calls, gaps, log = run("recorder")
want = ["voice_record_start()", "voice_record_stop()", "voice_draft_send()"]
if calls != want: errs.append("recorder: calls %s, not %s" % (calls, want))
elif gaps[-1] < 1500: errs.append("recorder: the fake never said recording (%d ms)" % gaps[-1])
elif not 900 <= gaps[0] - gaps[-1] <= 2500:
    errs.append("recorder: Stop %d ms after the device started (%d ms after Start), not about 1000"
                % (gaps[0] - gaps[-1], gaps[0]))
res = [l for l in log if l.startswith("VOICE-RESULT ")]
wantres = ['VOICE-RESULT start {"ok":true}', 'VOICE-RESULT stop {"draft":', 'VOICE-RESULT send {"note":"n1"}']
if len(res) != 3 or any(not r.startswith(w) for r, w in zip(res, wantres)):
    errs.append("recorder: VOICE-RESULT lines %s" % res)
after = log[next((i for i, l in enumerate(log) if l.startswith("VOICE-RESULT send ")), len(log)):]
mine = [n for l in tagged(after, "VOICE-NOTES") for n in json.loads(l) if n.get("note") == "n1"]
if not mine or not all(n.get("self") is True and n.get("state") == "complete" for n in mine):
    errs.append("recorder: the thread after the Send does not show n1 as one's own: %s" % mine)
print("recorder: %s, recording %s ms after Start, Stop %s ms after Start" % (calls, gaps[-1] if gaps else "-", gaps[0] if gaps else "-"))

calls, gaps, log = run("player")
want = ["voice_play(n9)", "voice_play(n10)"] + ["voice_play(n12)"] * 5
if calls != want: errs.append("player: calls %s, not %s" % (calls, want))
seq = []   # the playing note of each voice_status, consecutive repeats folded
for l in tagged(log, "VOICE"):
    p = json.loads(l).get("playing")
    k = p.get("note") if p else None
    if not seq or seq[-1] != k: seq.append(k)
if seq[:5] != [None, "n9", None, "n10", None] or len(seq) != 5:
    errs.append("player: voice_status showed %s, not nothing, n9, nothing, n10, nothing" % seq)
refused = [l for l in log if l.startswith('VOICE-RESULT play n12 {"error":"unknown-note"}')]
if len(refused) != 5: errs.append("player: %d refused Plays of n12 logged, not 5" % len(refused))
if not tagged(log, "VOICE-NOTES"): errs.append("player: no VOICE-NOTES line")
elif any("n11" in l for l in tagged(log, "VOICE-NOTES")):
    errs.append("player: the message whose body claims n11 reached the notes")
print("player: %s · playing %s" % (calls, seq))

if errs:
    print("FAIL:\n  " + "\n  ".join(errs)); sys.exit(1)
print("SUCCESS: the recorder's Start, Stop and Send once each; the player's Plays only of complete notes from another member, one at a time, each once, a refused one five times")
EOF
rc=$?
[ "$rc" = 0 ] && [ "${KEEP:-0}" != 1 ] && rm -rf "$OUT"
[ "$rc" = 0 ] || echo "logs: $OUT"
exit $rc
