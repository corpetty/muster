#!/usr/bin/env python3
"""The voice self-test's reading of a runner's log, with no runner (voice-notes.md S9).

    python3 scripts/tests/voice-self-test-replay.py [path/to/scripts/voice-self-test.sh]

On Linux CI (run 39836679442, at bbae7d8) scripts/voice-self-test.sh ran on two real
runners and failed both legs, "B never played A's note (sent: 48410f05…, played: 0)", while
B had played it: its sink held exactly the note's samples, the 1 kHz tone at 0.99 of the
source's power. The script misread the logs, where the C++ UI's lines arrive through
ui-host's relay, quoted, several to a line and now and then cut (scripts/lib/ui_log.py).
fixtures/voice-relay/ holds lines cut verbatim from that run's logs. This checks:

1. scripts/lib/ui_log.py on relayed lines cut each way it undoes (fixtures/voice-relay/
   splits/): each of the UI's lines comes out whole, as the UI wrote it.
2. The script's own verdict, VOICE_REPLAY on those logs: SUCCESS on the run as it was; the
   same with B's lines cut as ui-host cuts them; FAIL, saying why, for a run that did not
   pass (B never logs nothing playing, a send refused, one frame accepted, the sink a
   millisecond short, A's Send refused, a Stop the script cannot read), and a NOTE for a
   line it cannot read; C's silent refusal and its failures; and the same logs written bare,
   as the Nim UI writes them. The sink is the WAV's own tone cut to the note's length, not
   the run's sink: the audio check itself is held by its own red runs (voice-notes.md §15).

The fixtures, line for line from run 39836679442's voice-self-test-logs artifact (the
logos.dev leg is tmp.uvKCdhedqd, the local one tmp.zoXZQb1EaY):
  A.log      logos.dev A.log 1445 (a send before the Stop), 1641 (Stop), 1657 (Send), 1673, 1674
  B.log      logos.dev B.log 987 (before the note), 1413 (the note), 1419 (Play), 1472 and 1473
             (playing at 990 ms), 1553 and 1554 (1,990 ms), 1636 and 1637 (nothing playing)
  splits/    local A.log 2293-2294, 7876-7877, 12899-12901; logos.dev B.log 238-239, 454, 10359

Exit 0 when every check holds, 1 otherwise. Launches nothing and touches no device.
"""
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures", "voice-relay")
SCRIPT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "..", "voice-self-test.sh")
DECODER = os.path.join(os.path.dirname(SCRIPT), "lib", "ui_log.py")
NID = "48410f05599e54b38ffd8b515ba4017e"      # the note A sent and B played, in that run
DRAFT_MS = 2985
RELAY = b'ui-host [ "muster_ui" ]: "'
# a line another process wrote to B's log in that run, between two of B's ticks
OTHER = (b'[2026-10-22 19:22:07.976] [info] [logos] [muster_module] ModuleProxy: '
         b'callRemoteMethod "voice_status" args: 0')
failures = []


def check(what, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok or not detail else "\n     " + detail))
    if not ok:
        failures.append(what)


def decode(path):
    r = subprocess.run([sys.executable, "-I", DECODER, path], capture_output=True)
    return r.returncode, r.stdout.decode("utf-8", "replace").split("\n")


def qdebug(chunk):
    """A chunk as ui-host relays it: QDebug's quoting of a byte string, in quotes."""
    out, hexed = bytearray(b'"'), False
    for c in chunk:
        if hexed and chr(c) in "0123456789abcdefABCDEF":
            out += b'""'
        hexed = False
        if c in b'"\\':
            out += b"\\" + bytes([c])
        elif c in b"\b\f\n\r\t":
            out += b"\\" + {8: b"b", 12: b"f", 10: b"n", 13: b"r", 9: b"t"}[c]
        elif 0x20 <= c < 0x7F:
            out.append(c)
        else:
            out += b"\\x%02X" % c; hexed = True
    return bytes(out + b'"')


def relayed(chunk):
    return RELAY[:-1] + qdebug(chunk)      # RELAY ends with the chunk's opening quote


# ---- 1. the decoder on relayed lines cut verbatim from the run --------------------------
VOICE_IDLE = ('[muster_ui] VOICE {"ready":{"capture":"ok","playback":"unknown","codec":"libopus 1.5.2",'
              '"note":""},"recording":{"state":"idle","elapsedMs":0,"capMs":60000,"peak":0,"capped":false,'
              '"silent":false,"error":""},"playing":null}')
SPLITS = [
    ("another process's line inside a VOICE line", "line-inside-voice.log",
     ["[2026-10-22 19:26:28.980] [info] [logos] [keystore_module] QMetaObject::invokeMethod: "
      "No such method LogosAPI::currentCallerJson()", VOICE_IDLE]),
    ("a VOICE line across two of ui-host's chunks", "voice-across-chunks.log", [VOICE_IDLE]),
    ("a VOICE line across two chunks, another process's line between", "voice-across-chunks-line-between.log",
     ["[2026-10-22 19:29:38.988] [info] [logos] [muster_module] ModuleProxy: callRemoteMethod "
      '"voice_status" args: 0', VOICE_IDLE,
      '[muster_ui] VOICE-NOTES [{"durationMs":2984,"note":"442b7dba55606d2511c39fb207d65405",'
      '"self":true,"state":"complete","v":1}]']),
    ("another process's line inside an escape (\\ | n)", "line-inside-escape.log",
     ["[2026-10-22 19:21:53.548] [info] [logos] [liblogos_rln_module] RemoteTransportConnection: Registry "
      'connect attempt started (no peer contact yet): "local:logos_capability_module_voiceB"',
      'RemoteTransportConnection: Successfully connected to registry: "local:logos_keystore_module_voiceB"',
      'RemoteTransportConnection: Connected to registry at "19:21:53.549"']),
    ("UTF-8 as \\xHH, and quotes, in a chunk of two lines", "utf8.log",
     ['[muster_ui] muster_module.health() -> "ok"',
      "[muster_ui] module answered — re-running the startup reads"]),
]
for what, name, want in SPLITS:
    rc, got = decode(os.path.join(FIX, "splits", name))
    got = [l for l in got if l]
    check("ui_log: " + what, rc == 0 and got[:len(want)] == want,
          "want %r\n     got  %r" % (want, [l[:200] for l in got[:len(want) + 1]]))
rc, got = decode(os.path.join(FIX, "splits", "utf8-hex-digit-after.log"))
check('ui_log: "" between a \\xHH and a hex digit', rc == 0 and "ETH → 0x1111…1111" in got[0],
      repr(got[0][:120]) if got else "nothing")
# the quoting ui-host does, as this test does it below: each whole relayed line re-quoted
whole = [l for f in ("A.log", "B.log") for l in open(os.path.join(FIX, f), "rb").read().split(b"\n")
         if l.startswith(RELAY) and l.endswith(b'"')]
rc_ok = True
for l in whole:
    body = l[len(RELAY):-1]
    raw = re.sub(rb'\\(["\\nt])|\\x([0-9A-F]{2})|""',
                 lambda m: (bytes([int(m.group(2), 16)]) if m.group(2) else
                            {b'"': b'"', b"\\": b"\\", b"n": b"\n", b"t": b"\t"}[m.group(1)] if m.group(1) else b""), body)
    rc_ok &= relayed(raw) == l
check("this test quotes a chunk as ui-host did, for all %d whole relayed lines of A and B" % len(whole), rc_ok and len(whole) == 11)


# ---- 2. the script's verdict on those logs ------------------------------------------------
def tone(n):
    return [int(16383 * math.sin(2 * math.pi * 1000 * i / 48000)) for i in range(n)]


def make_case(root, name, a, b, c=None, sink_ms=DRAFT_MS):
    d = os.path.join(root, name)
    os.makedirs(d)
    for f, data in (("A.log", a), ("B.log", b), ("C.log", c)):
        if data is not None:
            open(os.path.join(d, f), "wb").write(b"\n".join(data) + b"\n")
    w = wave.open(os.path.join(d, "tone.wav"), "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(b"".join(struct.pack("<h", v) for v in tone(3 * 48000)))
    w.close()
    open(os.path.join(d, "B.pcm"), "wb").write(b"".join(struct.pack("<h", v) for v in tone(sink_ms * 48)))
    return d


def replay(d, os_name="Linux"):
    env = dict(os.environ, VOICE_REPLAY=d, VOICE_OS=os_name)
    env.pop("VOICE_SILENT", None)
    r = subprocess.run(["bash", SCRIPT], env=env, capture_output=True, timeout=120)
    return r.returncode, r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def expect(what, d, rc_want, *texts, os_name="Linux"):
    rc, out = replay(d, os_name)
    missing = [t for t in texts if t not in out]
    check(what, rc == rc_want and not missing,
          "exit %d (want %d), missing %r; the script said:\n     %s" % (rc, rc_want, missing,
                                                                     out.strip().replace("\n", "\n     ")))


def lines(name):
    return open(os.path.join(FIX, name), "rb").read().split(b"\n")[:-1]


A, B = lines("A.log"), lines("B.log")   # A: 1445 1641 1657 1673 1674 · B: 987 1413 1419 1472 1473 1553 1554 1636 1637
A_STOP, A_SEND, B_990, B_1990, B_NULL = 1, 2, 3, 5, 7


def unrelay(ls):
    """The lines as the UI wrote them, through ui_log."""
    p = os.path.join(tmp, "unrelay.log")
    open(p, "wb").write(b"\n".join(ls) + b"\n")
    return [x.encode() for x in decode(p)[1] if x]


def cut_inside(l, at):
    """ui-host's line cut at byte `at` (a whole number of 128), another process's line there."""
    return [l[:at] + OTHER, l[at:]]


def across_chunks(l, at):
    """The plugin's line in two of ui-host's chunks, cut `at` bytes into it."""
    chunk = b"\n".join(unrelay([l]))
    return [relayed(chunk[:at]), OTHER, relayed(chunk[at:])]


SUCCESS = "SUCCESS: B played A's voice note (%s), exactly its samples, the 1 kHz tone intact" % NID
tmp = tempfile.mkdtemp(prefix="voice-replay-")
try:
    expect("the run as it was: SUCCESS", make_case(tmp, "as-it-was", A, B), 0, SUCCESS,
           "B's sink: ok 143280 samples (2985 ms)", "A's sends from its Stop on: 2 accepted, 0 refused")
    for k in (B_990, B_1990, B_NULL):
        check("B's line %d is one chunk of ui-host's, past 256 bytes" % k,
              B[k].startswith(RELAY) and B[k].endswith(b'"') and len(B[k]) > 256)
    cut = B[:B_990] + cut_inside(B[B_990], 128) + B[B_990 + 1:B_1990] + across_chunks(B[B_1990], 128) \
        + B[B_1990 + 1:B_NULL] + cut_inside(B[B_NULL], 256) + B[B_NULL + 1:]
    expect("B's playing and idle lines cut as ui-host cuts them: SUCCESS",
           make_case(tmp, "cut", A, cut), 0, SUCCESS)
    expect("B never logs nothing playing: FAIL", make_case(tmp, "no-null", A, B[:B_NULL]), 1,
           "FAIL: B never played A's note (sent: %s, played: 1)" % NID)
    refused = A[4].replace(b"ok=1", b"ok=0").replace(b'"error":null,"success":true', b'"error":"refused","success":false')
    expect("a send refused after A's Stop: FAIL", make_case(tmp, "refused", A + [refused], B), 1,
           "A's sends from its Stop on: 2 accepted, 1 refused",
           "FAIL: delivery must accept at least the note's two frames and refuse none")
    expect("one frame accepted after A's Stop: FAIL", make_case(tmp, "one-frame", A[:4], B), 1,
           "A's sends from its Stop on: 1 accepted, 0 refused")
    expect("the sink a millisecond short: FAIL", make_case(tmp, "short", A, B, sink_ms=DRAFT_MS - 1), 1,
           "B's sink: bad 143232 samples (2984 ms)", "not the draft's 2985 ms x 48 = 143280")
    refused_send = relayed(b'[muster_ui] VOICE-RESULT send {"error":"busy","detail":""}')
    expect("A's Send refused: FAIL at once, naming it",
           make_case(tmp, "send-refused", A[:A_SEND] + [refused_send] + A[A_SEND + 1:], B), 1,
           'FAIL: A\'s Send names no note: {"error":"busy","detail":""}')
    # what HEAD's reading made of A's Send: its JSON and the chunk's closing quote
    bad_send = relayed(b'[muster_ui] VOICE-RESULT send {"note":"%s"}"' % NID.encode())
    expect("A's Send the script cannot read: FAIL, naming it as the script's",
           make_case(tmp, "bad-send", A[:A_SEND] + [bad_send] + A[A_SEND + 1:], B), 1,
           "FAIL: the script could not read A's Send (its reading of the log, not A's): "
           '{"note":"%s"}"' % NID)
    bad_stop = relayed(b'[muster_ui] VOICE-RESULT stop {"draft":{"durationMs":2985,"silent":false,')
    expect("A's Stop the script cannot read: FAIL, naming it as the script's",
           make_case(tmp, "bad-stop", A[:A_STOP] + [bad_stop] + A[A_STOP + 1:], B), 1,
           "bad: the script could not read A's Stop: {\"draft\":{\"durationMs\":2985,\"silent\":false,")
    bad_voice = relayed(b"[muster_ui] VOICE {\"ready\":{\"capture\":\"unknown\"")
    expect("a VOICE line the script cannot read: a NOTE saying so, the verdict from the rest",
           make_case(tmp, "note", A, B[:B_990] + [bad_voice] + B[B_990 + 1:]), 0, SUCCESS,
           "NOTE: 1 of B's VOICE lines did not read as JSON (the script's reading of the log, not B's)")

    def c_log(stop, send, notes):
        return [relayed(b"[muster_ui] VOICE-RESULT start {\"ok\":true}"),
                relayed(b"[muster_ui] VOICE-RESULT stop " + stop),
                relayed(b"[muster_ui] VOICE-RESULT send " + send),
                relayed(b"[muster_ui] VOICE {\"playing\":null}\n[muster_ui] VOICE-NOTES " + notes)]
    silent = c_log(b'{"draft":{"durationMs":3010,"silent":true,"peak":0}}', b'{"error":"silent","detail":""}', b"[]")
    expect("C's zeros refused as silent: SUCCESS", make_case(tmp, "c-silent", A, B, silent), 0,
           SUCCESS + "; the null device's zeros were refused as silent.")
    sent = c_log(b'{"draft":{"durationMs":3010,"silent":false,"peak":9}}', b'{"note":"%s"}' % (b"c" * 32),
                 b'[{"durationMs":3010,"note":"%s","self":true,"state":"complete","v":1}]' % (b"c" * 32))
    expect("C's note not refused: FAIL", make_case(tmp, "c-sent", A, B, sent), 1,
           "FAIL: C's Stop did not call its draft silent", "FAIL: C's Send was not refused as silent",
           "FAIL: C's thread holds a note of its own")
    expect("C's refusal with no detail, on macOS: FAIL", make_case(tmp, "c-darwin", A, B, silent), 1,
           "FAIL: C's refusal has no detail on macOS", os_name="Darwin")
    two = relayed(b'[muster_ui] VOICE-NOTES [{"durationMs":2985,"note":"%s","self":false,"state":"complete",'
                  b'"v":1},{"durationMs":3010,"note":"%s","self":false,"state":"complete","v":1}]'
                  % (NID.encode(), b"c" * 32))
    expect("a second note in B's thread after C's Send: FAIL", make_case(tmp, "c-reached-b", A, B + [two], silent),
           1, "FAIL: B's thread does not hold exactly one note, A's")
    half = B[-1][:120]                        # B's last VOICE-NOTES, half written when read
    expect("B's last line half written: SUCCESS, from the lines before it",
           make_case(tmp, "half", A, B + [half], silent), 0,
           SUCCESS + "; the null device's zeros were refused as silent.")

    # The same run written bare, as the Nim UI writes its lines: ui_log leaves them as they are
    bare_a, bare_b, bare_c = unrelay(A), unrelay(B), unrelay(silent)
    for who, bare in (("A's", bare_a), ("B's", bare_b), ("C's", bare_c)):
        check("ui_log leaves %s lines, written bare, as they are" % who,
              unrelay(bare) == bare and not any(x.startswith(RELAY) for x in bare))
    check("the bare logs hold A's Stop and Send, and B's Play, as the UI wrote them",
          b'[muster_ui] VOICE-RESULT stop {"draft":{"durationMs":2985,"silent":false,"peak":16383}}' in bare_a
          and b'[muster_ui] VOICE-RESULT send {"note":"%s"}' % NID.encode() in bare_a
          and b'[muster_ui] VOICE-RESULT play %s {"ok":true}' % NID.encode() in bare_b)
    expect("the same run, bare: SUCCESS", make_case(tmp, "bare", bare_a, bare_b, bare_c), 0,
           SUCCESS + "; the null device's zeros were refused as silent.")
    idle = [l for l in bare_b if not (l.startswith(b"[muster_ui] VOICE {") and l.endswith(b'"playing":null}'))]
    expect("bare, B never logs nothing playing: FAIL", make_case(tmp, "bare-no-null", bare_a, idle), 1,
           "FAIL: B never played A's note (sent: %s, played: 1)" % NID)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("── %d failed ──" % len(failures) if failures else "── all passed ──")
sys.exit(1 if failures else 0)
