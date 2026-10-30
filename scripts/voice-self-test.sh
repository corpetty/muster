#!/usr/bin/env bash
# Voice notes end to end through the real UI binary (docs/design/voice-notes.md, S9): no GUI,
# no clicks, no microphone and no speaker. Two offscreen runners in one room on the delivery
# fleet (MUSTER_FLEET, as every self-test), each with its own scratch HOME:
#   A founds the room, admits B, and once B is in records VOICE_SECS seconds (3 by default; a
#     whole number from 1 to 60, the module's cap, as the autopilot reads it; past 3 s the
#     WAV is silence) from a 3 s, 1 kHz WAV this script
#     writes (MUSTER_VOICE_SOURCE, the module's FileAudioIo), then sends the draft: the mic's
#     Start, Stop and Send (MUSTER_AUTOVOICE);
#   B sees the note in its thread and plays it (MUSTER_AUTOVOICEPLAY, the card's Play) into a
#     raw PCM file (MUSTER_VOICE_SINK).
# Passes when
#   * A logs the note its Send sent, and from A's Stop on the delivery node accepted at least
#     two of A's sends (a note is two frames, one send each) and refused none. The count starts
#     at the Stop, not the Send: a send's result comes back on delivery's thread whenever it
#     does, and both UIs log the Send's answer only after re-reading voice_status;
#   * B's thread holds that note, complete, and B logs it playing (a voice_status naming it,
#     or its Play's own answer, ok: a note of a second can end before B's next tick reads
#     voice_status), then nothing playing;
#   * B's file holds exactly the note's samples (its length at 48 samples a millisecond, s16)
#     and the WAV's 1 kHz tone, found by a Goertzel filter over the tone's part of the note
#     (from 0.25 s to 0.25 s before the shorter of the note and the WAV): at least half the
#     source's power at 1 kHz there, and over 100 times the power at 500 Hz, 1.5 kHz and
#     3.1 kHz;
#   * no log has a QML TypeError or ReferenceError. That holds the voice QML only where the
#     view loads: MUSTER_UI=nim (the Nim app loads Main.qml offscreen) or MUSTER_QPA=xcb. The
#     default C++ runner never instantiates the QML view offscreen
#     (docs/labbook/qml-errors-are-invisible-to-nix-build.md), so there a clean log says
#     nothing of RoomVoiceNote, CardVoiceNote or Room's voice polls: the autopilot drives the
#     backend's slots, and the gallery fixtures hold the QML.
# Then a third runner, C, joins on MUSTER_VOICE_BACKEND=null (miniaudio's null device: all
# zeros) and records and sends too. Its Stop must say the draft is silent, its Send must be
# refused as silent (on macOS with a detail, the module's microphone note), its own thread
# must hold no note of its own after the Send (a sender's fold shows its note at once, §8),
# and B must never see a second note. VOICE_SILENT=0 skips C.
#
# The audio never leaves the module: the runners' UIs only trigger and poll voice_status
# (§8). The WAV and the PCM live in the scratch dir, never in the tree.
#
# The logs are read through ui_log (scripts/lib/ui_log.py): the C++ UI's lines reach them
# through ui-host's relay, QDebug-quoted, several to a line and now and then cut. A line the
# script cannot read as JSON is reported as the script's error, never as what B did.
#
# VOICE_REPLAY=<dir> launches nothing: it gives the verdict on a finished run's files
# (KEEP_LOGS=1's, or a CI artifact's: A.log, B.log, tone.wav, B.pcm, and C.log when C ran;
# C's checks run when C.log is there, unless VOICE_SILENT says otherwise), and deletes
# nothing. VOICE_OS names the OS the runners ran on (default: this one's).
# scripts/tests/voice-self-test-replay.py holds the verdict that way, on lines cut from a
# Linux CI run.
#
#   make build && scripts/voice-self-test.sh       # KEEP_LOGS=1 keeps the logs and the audio
set -uo pipefail
REPLAY="${VOICE_REPLAY:-}"
case "$REPLAY" in ''|/*) ;; *) REPLAY="$PWD/$REPLAY" ;; esac   # named from where it was run
cd "$(dirname "$0")/.."
SECS="${VOICE_SECS:-3}"
SILENT_LEG="${VOICE_SILENT:-1}"
HOST_OS="${VOICE_OS:-$(uname -s)}"
# Both backends read MUSTER_AUTOVOICE as a whole number, and anything else as 0, which
# records nothing; the module refuses a draft under 500 ms.
# Over 60 the module stops at its cap while the Stop still waits VOICE_SECS, and the wait
# below (Stop, then B's playback of up to 60 s, in 240 s) no longer fits.
case "$SECS" in
  ''|*[!0-9]*) echo "VOICE_SECS must be a whole number of seconds from 1 to 60, not '$SECS'"; exit 2 ;;
esac
[ "$SECS" -ge 1 ] && [ "$SECS" -le 60 ] \
  || { echo "VOICE_SECS must be a whole number of seconds from 1 to 60, not '$SECS'"; exit 2; }
. scripts/lib/ui-build.sh
# a runner's log with the UI's own lines as it wrote them, one to a line
lg() { ui_log "$1"; }
# the JSON after the last "[muster_ui] <tag> " line of a log
last() { lg "$2" | grep -a "\[muster_ui\] $1 " | tail -1 | sed "s/.*\[muster_ui\] $1 //"; }
# the last line on stdin that reads as JSON, or nothing: a runner still writes its log, so
# the last line can be half written
readable() { python3 -c '
import json, sys
good = ""
for line in sys.stdin:
    line = line.rstrip("\n")
    try: json.loads(line); good = line
    except ValueError: pass
print(good)'; }
# the JSON after the last "[muster_ui] <tag> " line of a log that reads as JSON, for a line
# the UI logs every tick
last_json() { lg "$2" | grep -a "\[muster_ui\] $1 " | sed "s/.*\[muster_ui\] $1 //" | readable; }
# pause <seconds>: give the runners time; a replay has none to give
pause() { [ -n "$REPLAY" ] || sleep "$1"; }

if [ -n "$REPLAY" ]; then
  D="$REPLAY"
  for f in A.log B.log tone.wav; do
    [ -f "$D/$f" ] || { echo "VOICE_REPLAY: no $D/$f"; exit 2; }
  done
  [ -n "${VOICE_SILENT:-}" ] || [ -f "$D/C.log" ] || SILENT_LEG=0
  WAIT=1 WAIT_C=1
  echo "replaying the run in $D (launching nothing)"
else
  ui_require_runner
  trap ui_cleanup EXIT
  D=$(mktemp -d)
  TOPIC="/muster/1/voice-$(date +%s)/proto"
  CFG=$(ui_fleet_config)
  WAIT=240 WAIT_C=120
  mkdir -p "$D/A-home" "$D/B-home" "$D/C-home"

  # 3 s of 1 kHz at half scale, 48 kHz mono s16: what A's "microphone" hears, then silence
  python3 - "$D/tone.wav" <<'EOF'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"".join(struct.pack("<h", int(16383 * math.sin(2 * math.pi * 1000 * i / 48000)))
                       for i in range(3 * 48000)))
w.close()
EOF
  echo "topic: $TOPIC · recording: ${SECS}s of a 3 s 1 kHz tone · logs: $D"

  ui_launch "$D/A" "$D/A.log" HOME="$D/A-home" QT_FORCE_STDERR_LOGGING=1 MUSTER_LP_DEBUG=1 \
    MUSTER_AUTOADMIT=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=voiceA \
    MUSTER_VOICE_SOURCE="$D/tone.wav" MUSTER_AUTOVOICE="$SECS"
  CFG_B=$(ui_peer_config "$D/A.log") || exit 1
  ui_launch "$D/B" "$D/B.log" HOME="$D/B-home" QT_FORCE_STDERR_LOGGING=1 \
    MUSTER_DELIVERY_CONFIG="$CFG_B" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=voiceB \
    MUSTER_VOICE_SINK="$D/B.pcm" MUSTER_AUTOVOICEPLAY=1
  echo "waiting for A to send a note and B to play it (up to ${WAIT}s)..."
fi

ok=0 NID="" played=0 unread=0 firstunread="" asend="" sendreads=0
for i in $(seq 1 "$WAIT"); do
  pause 1
  if [ -z "$NID" ]; then
    asend=$(last 'VOICE-RESULT send' "$D/A.log")
    [ -n "$asend" ] || continue
    sent=$(printf '%s' "$asend" | python3 -c '
import json, sys
try: r = json.loads(sys.stdin.read())
except ValueError: print("unread"); sys.exit()
n = r.get("note") if isinstance(r, dict) else None
print("note " + n if isinstance(n, str) and n else "none")')
    case "$sent" in
      "note "*) NID="${sent#note }" ;;
      none)    # refused: no note left A, so there is nothing to wait for
        echo "FAIL: A's Send names no note: $(printf '%s' "$asend" | cut -c1-400) — logs kept in $D"; exit 1 ;;
      *)       # not JSON: half written, or the script misreads the log; three reads decide
        sendreads=$((sendreads + 1))
        if [ -n "$REPLAY" ] || [ "$sendreads" -ge 3 ]; then
          echo "FAIL: the script could not read A's Send (its reading of the log, not A's): $(printf '%s' "$asend" | cut -c1-400) — logs kept in $D"
          exit 1
        fi
        continue ;;
    esac
  fi
  # B played it: a voice_status naming it playing, or its Play's own answer ok, then a
  # voice_status with nothing playing. Both autopilots log voice_status once a tick, before
  # they decide to Play, and not the re-read after it, so a short note can end unseen.
  # It prints that stage (0, 1 or 2) and how many of those lines were not JSON, then the
  # first of them.
  read_b=$(lg "$D/B.log" | grep -aE '\[muster_ui\] VOICE( \{|-RESULT play )' | sed 's/.*\[muster_ui\] VOICE//' | python3 -c '
import json, sys
nid, seen, unread, first = sys.argv[1], 0, 0, ""
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("-RESULT play "):
        parts = line[len("-RESULT play "):].split(" ", 1)
        try: r = json.loads(parts[1]) if len(parts) == 2 else None
        except ValueError: r = None
        if not isinstance(r, dict):
            unread += 1; first = first or "VOICE" + line
        elif parts[0] == nid and r.get("ok") is True and "error" not in r: seen = max(seen, 1)
        continue
    try: v = json.loads(line[1:])
    except ValueError: v = None
    if not isinstance(v, dict):
        unread += 1; first = first or "VOICE" + line
        continue
    p = v.get("playing")
    if isinstance(p, dict) and p.get("note") == nid: seen = max(seen, 1)
    elif p is None and seen: seen = 2
print(seen, unread)
print(first[:400])' "$NID")
  played=$(printf '%s\n' "$read_b" | sed -n 1p | cut -d' ' -f1)
  unread=$(printf '%s\n' "$read_b" | sed -n 1p | cut -d' ' -f2)
  firstunread=$(printf '%s\n' "$read_b" | sed -n 2p)
  [ "$played" = 2 ] && { ok=1; break; }
done
echo "A's Start: $(last 'VOICE-RESULT start' "$D/A.log") · Stop: $(last 'VOICE-RESULT stop' "$D/A.log") · Send: $(last 'VOICE-RESULT send' "$D/A.log")"
echo "B's Play: $(last 'VOICE-RESULT play' "$D/B.log") · after ~${i}s"
# a tagged line that is not JSON is the script misreading the log, whatever B did
[ "${unread:-0}" = 0 ] || echo "NOTE: $unread of B's VOICE lines did not read as JSON (the script's reading of the log, not B's), the first: $firstunread"
[ "$ok" = 1 ] || { echo "FAIL: B never played A's note (sent: ${NID:-none}, played: $played) — logs kept in $D"; \
  echo "B's last voice_status: $(last VOICE "$D/B.log" | cut -c1-400)"; \
  echo "B's thread's notes: $(last VOICE-NOTES "$D/B.log" | cut -c1-400)"; exit 1; }

# The audio: the exact length, and the tone
check=$(python3 - "$D/tone.wav" "$D/B.pcm" "$NID" "$(last 'VOICE-RESULT stop' "$D/A.log")" "$(last_json VOICE-NOTES "$D/B.log")" <<'EOF'
import json, math, struct, sys, wave
src_path, sink_path, nid, stop, notes = sys.argv[1:6]
def read(what, text, ok):       # a line it cannot read is the script's error, not B's
    try:
        v = json.loads(text)
    except ValueError:
        v = None
    if v is None or not ok(v):
        print("bad: the script could not read %s: %s" % (what, text[:400] or "(no line)"))
        sys.exit(0)
    return v
draft_ms = read("A's Stop", stop, lambda v: isinstance(v, dict) and isinstance(v.get("draft"), dict)
                and type(v["draft"].get("durationMs")) is int)["draft"]["durationMs"]
rows = read("B's thread's notes", notes, lambda v: isinstance(v, list) and all(isinstance(n, dict) for n in v))
w = wave.open(src_path, "rb"); src = struct.unpack("<%dh" % w.getnframes(), w.readframes(w.getnframes()))
try:
    raw = open(sink_path, "rb").read()
except OSError:
    raw = b""
sink = struct.unpack("<%dh" % (len(raw) // 2), raw[: len(raw) // 2 * 2])
row = [n for n in rows if n.get("note") == nid]
row_ms = row[0]["durationMs"] if row else -1
state = row[0]["state"] if row else "absent"
def power(x, f, a, n):        # Goertzel: |X(f)|^2 over x[a:a+n], normalised by n^2
    k = 2 * math.cos(2 * math.pi * f / 48000); s1 = s2 = 0.0
    for v in x[a:a + n]: s1, s2 = v + k * s1 - s2, s1
    return (s1 * s1 + s2 * s2 - k * s1 * s2) / (n * n)
# From 0.25 s (past the codec's start) to 0.25 s before the tone ends, which is the note's end
# or the WAV's, whichever comes first; n a whole number of 500 Hz periods (96 samples), so
# 500 Hz, 1 kHz and 1.5 kHz each fit whole cycles and do not leak into one another.
a = 12000
n = (min(draft_ms * 48, len(src)) - 12000 - a) // 96 * 96
ref = power(src, 1000, a, n) if n > 0 else 0
p = {f: power(sink, f, a, n) for f in (1000, 500, 1500, 3100)} if n > 0 and len(sink) >= a + n else {}
errs = []
if len(raw) % 2: errs.append("an odd number of bytes")
if len(sink) != draft_ms * 48: errs.append("%d samples, not the draft's %d ms x 48 = %d" % (len(sink), draft_ms, draft_ms * 48))
if row_ms != draft_ms: errs.append("B's row says %d ms, A's draft %d ms" % (row_ms, draft_ms))
if state != "complete": errs.append("B's row is %s" % state)
if not p: errs.append("too short for the window")
elif p[1000] < 0.5 * ref: errs.append("1 kHz power %.0f, under half the source's %.0f" % (p[1000], ref))
elif max(p[500], p[1500], p[3100]) * 100 > p[1000]: errs.append("1 kHz is not the peak: %r" % p)
print(("ok " if not errs else "bad ") + "%d samples (%d ms) · from %.2f s to %.2f s, 1 kHz power %.0f of the source's %.0f · 500 Hz %.1f, 1.5 kHz %.1f, 3.1 kHz %.1f%s" % (
    len(sink), len(sink) // 48, a / 48000, (a + max(n, 0)) / 48000, p.get(1000, 0), ref,
    p.get(500, 0), p.get(1500, 0), p.get(3100, 0), "" if not errs else " · " + "; ".join(errs)))
EOF
)
echo "B's sink: $check"
case "$check" in ok*) ;; *) ok=0 ;; esac

# The delivery node took both of the note's frames (each is one send) and refused none of A's
# sends. Counted from A's Stop, which both UIs log before they call voice_draft_send: a send's
# result comes back on delivery's thread whenever it does, often before the Send's own line.
refused=$(lg "$D/A.log" | sed -n '/\[muster_ui\] VOICE-RESULT stop /,$p' | grep -ac 'MUSTER-LP send/sub-result ok=0')
accepted=$(lg "$D/A.log" | sed -n '/\[muster_ui\] VOICE-RESULT stop /,$p' | grep -ac 'MUSTER-LP send/sub-result ok=1')
echo "A's sends from its Stop on: $accepted accepted, $refused refused"
[ "$accepted" -ge 2 ] && [ "$refused" = 0 ] \
  || { echo "FAIL: delivery must accept at least the note's two frames and refuse none"; ok=0; }

if [ "$ok" = 1 ] && [ "$SILENT_LEG" = 1 ]; then
  # C: the null device's zeros, refused at Send; nothing reaches B
  if [ -z "$REPLAY" ]; then
    CFG_C=$(ui_peer_config "$D/A.log") || exit 1
    ui_launch "$D/C" "$D/C.log" HOME="$D/C-home" QT_FORCE_STDERR_LOGGING=1 \
      MUSTER_DELIVERY_CONFIG="$CFG_C" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=voiceC \
      MUSTER_VOICE_BACKEND=null MUSTER_AUTOVOICE="$SECS"
    echo "C joins on the null device; waiting for its Send's answer (up to ${WAIT_C}s)..."
  fi
  csend=""
  for _ in $(seq 1 "$WAIT_C"); do
    pause 1
    csend=$(last_json 'VOICE-RESULT send' "$D/C.log")
    [ -n "$csend" ] && break
  done
  pause 5      # C's and B's ticks, after C's Send
  cstop=$(last_json 'VOICE-RESULT stop' "$D/C.log")
  notes=$(last_json VOICE-NOTES "$D/B.log")
  # C's own thread after its Send: a note it had sent would be there at once, since the session
  # logs each part before the transport sees it (voice-notes.md §8), however slow the fleet
  cnotes=$(lg "$D/C.log" | sed -n '/\[muster_ui\] VOICE-RESULT send /,$p' | grep -a '\[muster_ui\] VOICE-NOTES ' \
    | sed 's/.*\[muster_ui\] VOICE-NOTES //' | readable)
  echo "C's Stop: ${cstop:-none} · Send: ${csend:-none} · C's thread's notes after it: ${cnotes:-none} · B's thread's notes: ${notes:-none}"
  # on macOS the refusal carries the module's microphone note (platformNote, §11); elsewhere none
  cfail=$(python3 - "$cstop" "$csend" "$cnotes" "$notes" "$NID" "$HOST_OS" <<'EOF'
import json, sys
def read(t):
    try: return json.loads(t)
    except ValueError: return None
stop, send, cnotes, notes = (read(t) for t in sys.argv[1:5])
nid, host = sys.argv[5:7]
draft = stop.get("draft") if isinstance(stop, dict) else None
if not (isinstance(draft, dict) and draft.get("silent") is True):
    print("FAIL: C's Stop did not call its draft silent")
if not (isinstance(send, dict) and send.get("error") == "silent"):
    print("FAIL: C's Send was not refused as silent")
elif host == "Darwin" and not send.get("detail"):
    print("FAIL: C's refusal has no detail on macOS")
if not isinstance(cnotes, list):
    print("FAIL: C logged no thread after its Send")
elif any(isinstance(n, dict) and n.get("self") is True for n in cnotes):
    print("FAIL: C's thread holds a note of its own")
if not (isinstance(notes, list) and [n.get("note") if isinstance(n, dict) else n for n in notes] == [nid]):
    print("FAIL: B's thread does not hold exactly one note, A's")
EOF
)
  [ -z "$cfail" ] || { echo "$cfail"; ok=0; }
fi
[ -n "$REPLAY" ] || ui_cleanup

qml=$(cat "$D"/*.log | grep -aE 'TypeError|ReferenceError' | head -3)
[ -z "$qml" ] || { echo "FAIL: QML errors:"; echo "$qml"; ok=0; }
if [ "${MUSTER_UI:-cpp}" = cpp ] && [ -z "${MUSTER_QPA:-}" ]; then
  echo "NOTE: offscreen, the C++ runner never loads the QML view, so no voice QML ran here (MUSTER_UI=nim or MUSTER_QPA=xcb runs it)"
fi

if [ "$ok" = 1 ]; then
  echo "SUCCESS: B played A's voice note ($NID), exactly its samples, the 1 kHz tone intact$([ "$SILENT_LEG" = 1 ] && echo '; the null device'"'"'s zeros were refused as silent')."
  [ -n "$REPLAY" ] || [ "${KEEP_LOGS:-0}" = 1 ] || rm -rf "$D"
else
  echo "FAIL: logs kept in $D"
  exit 1
fi
