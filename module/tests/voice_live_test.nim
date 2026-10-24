## Voice notes' hosted half (docs/design/voice-notes.md §8, §9; S7): `VoiceRecorder`, the state
## machine the six voice methods and voice_status run, over the AudioIo seam, the room's session
## and the member's keystore. Two members over LocalTransport, each with a recorder of their own
## on SyntheticAudioIo and a virtual clock (FileAudioIo in §12, miniaudio's null device in §13,
## a start held by a StartGate in §29–§31),
## so the cap, the draft, every refusal and playback are held on a clock the test owns, and
## libopus encodes and decodes for real. No seam is mocked.
##   1. Alice records 3.000 s of a 1 kHz tone and stops: a draft of 3,000 ms; she sends it: two
##      frames of 90,153 B; Bob's thread holds one complete voice row of hers, metadata only;
##      Bob plays it: his sink holds exactly the clip's samples, with a 1 kHz Goertzel peak, and
##      once the pump sees done he is idle again, the device released
##   2. the cap: a 70 s source stops at 60,000 ms with `capped`, the device released by the pump
##      alone; Stop then hands back that draft, and it sends
##   3. an all-zero source: the draft is silent, peak 0; Send refuses `silent` with the platform
##      note as its `detail` (the macOS words on macOS, `hostOS` choosing), keeps the draft, and
##      nothing reaches the log, its heads or the topic
##   4. under 500 ms: `too-short`, nothing published; 500 ms exactly sends
##   5. busy: start while recording, playing or a draft is held; play while recording or
##      playing; send with no draft is `no-draft`; stop with nothing recording `not-recording`
##   6. no room: start, send and play a note refuse `not-joined`, and nothing opens
##   7. play refusals: an unknown note `unknown-note`, an arriving one `incomplete`, a broken one
##      `broken`, and a note the fold calls complete whose packets libopus refuses `broken`
##   8. (run last, over every reply the others got) no JSON any call returns carries audio or a
##      float, in every state: no `part`, no run of base64 characters over 64, under 1 KB
##   9. encoding is incremental: after each 1 s of pumps everything captured is encoded, so after
##      59 s Stop encodes the last 0.5 s alone
##  10. discard drops the draft (and a recording in progress): later Play("draft") and Send say
##      `no-draft`
##  11. the memo: the thread's rows judge a note's clip once per pair of standing parts, then
##      serve the verdict; one memo per room
##  12. which AudioIo the module makes (MUSTER_VOICE_SOURCE / _SINK, MUSTER_VOICE_BACKEND), and
##      FileAudioIo end to end: a WAV source recorded, sent, played into a raw PCM sink; a
##      missing source refused `no-source`, which `ready.capture` then says
##  13. miniaudio's null device: a real device thread captures zeros, so Send refuses `silent`;
##      the context is released when the stream ends
##  14. close stops what runs and releases the device; it is idempotent
##  15. a Send that fails between its two parts (the delivery raising on the second) keeps the
##      draft, and its retry, at a later clock, sends the same note. The log took both parts
##      before the delivery raised, so the sender's own fold already calls the note complete
##      while the other member holds part 0 alone; the retry re-sends both parts on the held
##      path, and the other member then holds one complete note, not a stranded part beside a
##      second note. Only a transport that raises shows the failure: DeliveryTransport's send
##      is fire-and-forget (voice-notes.md §8, §15)
##  16. a recording of no samples, or of under 500 ms of zeros, is `too-short`, never `silent`,
##      and raises no microphone note: `silent` is a draft long enough to send whose samples
##      are all zero
##  17. every call decides on the device side's state now, as Stop does: a playback heard to
##      its end with no status read since is not `busy` to Play or Start, and Send finds the
##      draft the cap made
##  18. a draft belongs to the room it was recorded in: Send through another room's session is
##      `room-changed`, publishes nothing to either room and keeps the draft, which then sends
##      in its own room
##  19. Send and Discard while the draft plays stop that playback and release the device
##  20. a sink that refuses a write (FileAudioIo past a file-size limit) ends the playback:
##      `ready.playback` is `sink-write` and the stream is released
##  21. the recorder owns its AudioIo: a start the io refuses, and close, release whatever it
##      holds open, miniaudio's context included
##  22. coordinate_messages' rows (`messagesJson`): a message's row is exactly {id, author, ts,
##      body, alias, self}, a note's the same plus `voice`, with an empty body
##  23. coordinate_proof (`roomProof`) refuses `voice-notes-present` for a room holding a
##      voice note, and exports no event; a room with none exports the proof as before, and it
##      verifies; an unsigned `voice/` entry of no note's shape refuses nothing (§26)
##  24. a member who received part 0 of a Send that failed between its frames sends a copy of
##      it with a long, unsigned `after` that sorts first, so the author's log keeps that copy;
##      the author's retry is not blocked (`too-large` before the fix, for good): it re-seals
##      the copy the author signed, two frames of 90,153 B, and the other member holds the
##      note complete
##  25. a note's two frames leave back to back: when the first reaches the transport, both
##      parts are already signed, logged and journalled, for a 1 s and a 59 s note alike, so
##      nothing whose cost grows with the note's length runs between the two sends
##  26. coordinate_proof refuses only a room whose authentic view holds a part the fold stands
##      (voiceStanding): a room whose raw log holds only junk under voice/ (unsigned, a forged
##      author, a malformed value, a squatted note id, keys of the wrong shape) exports a proof
##      that accounts for every raw entry (exo-f76) and verifies, a copied half of a note's
##      clip with it (voice-notes.md §10's residual); beside the same junk, a note arriving,
##      complete or broken refuses with the same error and detail as before
##  27. the room's memo keeps each part's header fields by event id (PR 340's review: the
##      header pass parsed every part's value on every poll): over an unchanged log the
##      rows coordinate_messages serves and coordinate_conversations' lastTs parse 0 parts
##      (`voiceParses`); a new part alone is parsed, and the part that completes a note reads
##      its other half back once for the verdict (`voiceHalfReads`); Play gathers once and
##      reads back the two halves it decodes; the memo holds one header per part in the
##      room's view, and `forgetRoom` (coordinate_leave) drops a room's memo
##  28. the room's other polled reads go through the same memo, by the recorder's procs the
##      hosted methods call: `flowRows` (coordinate_flow), `graphOf` (coordinate_graph),
##      `provenanceOf` (coordinate_provenance) and `lastTs` (coordinate_conversations, given
##      the events the method read) each give the memo-less fold's output; a cold memo parses
##      each part once across all four, a warm one none, and after the thread's rows have read
##      the room (`memoFor`'s memo) none of them parses a part
##  29. a device start held (PR 340's review: a start could hold the module thread):
##      voice_record_start answers in under 100 ms while a StartGate holds SyntheticAudioIo's
##      start on its start thread; voice_status says starting, at 0 ms, while time passes,
##      and the thread's rows and voice_status answer meanwhile; released, recording, its
##      elapsed time and its 60 s cap counted from the device's start
##  29b. Stop (not-started), Discard and close while the start is held answer at once and
##      leave the recorder idle; the start thread frees the buffer once its start returns (the
##      buffers counted) and stops the device it started; a start that fails: idle, error and
##      ready.capture no-device, the buffer freed at once; one still pending at StartBoundMs:
##      device-start-slow, let go
##  29c. Discard and close after the device's start returned (run or failed) but before any
##      read saw it, the recorder still starting: idle at once, the io finishing the start on
##      the module thread, the buffer freed at once; on the null device its running device
##      and context released too
##  29d. while a start is on its way ready says unknown for its device, not the word the last
##      start left (device-start-slow), for a recording and for Play
##  30. the same for Play: playing names the note, starting, at 0 ms; released, it plays to
##      done as before; Stop lets it go; a failure says no-device in ready.playback; past the
##      bound device-start-slow
##  31. close while a start is held returns at once, and the hosted exit proc's bounded wait
##      for start threads (waitStarts) ends: it never hangs on a start that never returns
## Needs libopus, libsecp256k1, libsodium and the miniaudio pin (run-suite.sh links them all).

import std/[algorithm, json, math, monotimes, os, strutils, sequtils, tables]
from std/posix import RLimit, getrlimit, setrlimit, signal, SIGXFSZ, SIG_IGN, SIG_DFL
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/audio/[audio_io, voice_clip, voice_codec, miniaudio]
import ../src/log/[log, proof]
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/intent_events
import ../src/coordination/contacts
import ../src/coordination/voice
import ../src/coordination/voice_live
import ../src/coordination/[flow, intents, room_graph]
import ../src/drivers/driver

var RLIMIT_FSIZE {.importc: "RLIMIT_FSIZE", header: "<sys/resource.h>".}: cint
  ## the largest file this process may write (§20); posix.nim declares no constant for it

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc sine(freq: float, n: int, amp = 0.5): seq[int16] =
  result = newSeq[int16](n)
  for i in 0 ..< n:
    result[i] = int16(amp * 32767.0 * sin(2.0 * PI * freq * float(i) / float(ClipRate)))

proc goertzel(x: openArray[int16], freq: float): float =
  ## The signal's power at one frequency.
  let k = 2.0 * cos(2.0 * PI * freq / float(ClipRate))
  var s1, s2 = 0.0
  for v in x:
    let s0 = float(v) + k * s1 - s2
    s2 = s1
    s1 = s0
  (s1 * s1 + s2 * s2 - k * s1 * s2) / (float(x.len) * float(x.len))

let aliceKs = newInMemoryKeystore(seed(0x71), seed(0x81))
let bobKs   = newInMemoryKeystore(seed(0x72), seed(0x82))
let alice   = hex(aliceKs.encIdentity().toBytes())

const topic = "/muster/1/room-voice-live/proto"
const WireBytes = 1 + 24 + 16 + 90_112
const Second = ClipRate                  ## samples in a second

type Wire = ref object
  frames: seq[seq[byte]]

proc tap(net: LocalNetwork, topic: string): Wire =
  let w = Wire()
  newLocalTransport(net).subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} =
    w.frames.add m.payload)
  w

proc dataFrames(w: Wire): seq[seq[byte]] =
  for f in w.frames: (if f.len > 0 and f[0] == 0x00'u8: result.add f)

type Refuser = ref object
  left: int   ## voice frames to let through before one is refused; -1 refuses none

proc refuser(net: LocalNetwork, topic: string): Refuser =
  ## A subscriber on the topic that raises on a voice frame once armed, as a failing send
  ## raises to its publisher: LocalTransport carries the raise back through `publish`.
  let r = Refuser(left: -1)
  newLocalTransport(net).subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} =
    if m.payload.len == WireBytes and r.left >= 0:
      if r.left == 0:
        r.left = -1
        raise newException(IOError, "the delivery node refused the frame")
      dec r.left)
  r

let net = newLocalNetwork()
let aliceCrypto = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity()])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobKs.encIdentity()))
let aliceS = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bobS = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)
let wire = tap(net, topic)

var seen: seq[JsonNode]   ## every JSON a call returned, for §8
proc ck(j: JsonNode): JsonNode = (seen.add j; j)
proc status(v: VoiceRecorder): JsonNode = ck(v.voiceStatus())
proc err(j: JsonNode): string = j{"error"}.getStr()
proc ok(j: JsonNode): bool = j{"ok"}.getBool() and j{"error"} == nil

proc noteRow(rows: seq[ThreadRow], nid: string): ThreadRow =
  var n = 0
  for r in rows:
    if r.isVoice and r.id == nid: (result = r; inc n)
  doAssert n == 1, "one voice row " & nid & ", not " & $n

var ts = 1_792_100_000'i64
proc nextTs(): int64 = (ts += 10; ts)

proc recordFor(v: VoiceRecorder, vc: VirtualClock, s: CoordinationSession, ms: int): JsonNode =
  ## Start, let `ms` pass on the clock with a status read each second, then Stop.
  doAssert v.recordStart(s).ck.ok
  var left = ms
  while left > 0:
    let step = min(left, 1000)
    vc.advance(step)
    left -= step
    discard v.status()
  v.recordStop().ck

proc msSince(t: MonoTime): int = int((getMonoTime().ticks - t.ticks) div 1_000_000)

proc waitUntil(cond: proc (): bool, limitMs: int): bool =
  let t0 = getMonoTime()
  while not cond():
    if msSince(t0) >= limitMs: return false
    sleep(2)
  true

type Net = object
  g: StartGate
  ms: int
proc netMain(n: Net) {.thread.} =
  var waited = 0
  while waited < n.ms and n.g.held:
    sleep(10)
    waited += 10
  n.g.releaseStart()                  # a no-op once the test has released it

proc state(v: VoiceRecorder): string = v.status()["recording"]["state"].getStr()

proc landed(io: AudioIo, limitMs = 2_000): string =
  ## Pump until the start in flight lands (the device starts on a thread of its own): "" once
  ## it runs, its failure's word, or "still-starting".
  let t0 = getMonoTime()
  while io.starting and msSince(t0) < limitMs:
    let why = io.pump()
    if why.len > 0: return why
    sleep(1)
  if io.starting: "still-starting" else: ""

# ── 1. record → draft → send → the other member plays ──────────────────────────────
var nid1 = ""
block:
  let tone = sine(1000.0, 3 * Second)
  let vcA = VirtualClock(ms: 5_000)
  let ioA = newSyntheticAudioIo(tone, vcA.clock)
  let a = newVoiceRecorder(ioA)
  var st = a.status()
  doAssert st["recording"]["state"].getStr() == "idle" and st["playing"].kind == JNull, $st
  doAssert st["ready"]["capture"].getStr() == "unknown" and st["ready"]["codec"].getStr() == opusVersion()
  doAssert a.recordStart(aliceS).ck.ok
  doAssert ioA.stream == asCapture
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "recording" and st["ready"]["capture"].getStr() == "ok", $st
  vcA.advance(1_000)
  st = a.status()
  doAssert st["recording"]["elapsedMs"].getInt() == 1_000, $st
  doAssert st["recording"]["peak"].getInt() > 10_000, "a tone at half scale: " & $st
  doAssert a.status()["recording"]["peak"].getInt() == 0, "the peak is reset when read, nothing new since"
  vcA.advance(2_000)
  let stop = a.recordStop().ck
  doAssert stop["draft"]["durationMs"].getInt() == 3_000, $stop
  doAssert not stop["draft"]["silent"].getBool() and stop["draft"]["peak"].getInt() > 10_000, $stop
  doAssert ioA.stream == asIdle, "the capture is released at Stop"
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "draft" and st["recording"]["elapsedMs"].getInt() == 3_000, $st
  let before = wire.dataFrames().len
  let sent = a.draftSend(aliceS, aliceKs, nextTs()).ck
  nid1 = sent{"note"}.getStr()
  doAssert nid1.len == 32, $sent
  let frames = wire.dataFrames()[before .. ^1]
  doAssert frames.len == 2 and frames.allIt(it.len == WireBytes), "two frames of 90,153 B: " & $frames.mapIt(it.len)
  doAssert a.status()["recording"]["state"].getStr() == "idle", "sent: no draft held"
  # Bob's thread: one voice row, Alice's, complete, metadata only
  let vcB = VirtualClock(ms: 9_000)
  let ioB = newSyntheticAudioIo(@[], vcB.clock)
  let b = newVoiceRecorder(ioB)
  let row = noteRow(b.rows(bobS), nid1)
  doAssert row.author == alice and row.body == "" and row.note.state == vsComplete, $row
  let rj = rowJson(row)
  doAssert rj["voice"] == %*{"v": 1, "note": nid1, "durationMs": 3_000, "state": "complete"}, $rj
  # Bob plays it
  doAssert b.play(bobS, nid1).ck.ok
  doAssert ioB.stream == asPlayback
  st = b.status()
  doAssert st["playing"] == %*{"note": nid1, "positionMs": 0, "durationMs": 3_000, "starting": false}, $st
  doAssert st["ready"]["playback"].getStr() == "ok" and st["recording"]["state"].getStr() == "idle", $st
  vcB.advance(1_500)
  doAssert b.status()["playing"]["positionMs"].getInt() == 1_500
  vcB.advance(1_600)
  st = b.status()
  doAssert st["playing"].kind == JNull, "done: idle again: " & $st
  doAssert ioB.stream == asIdle, "the playback is released once the pump sees done"
  let (okR, record) = voiceRecordOf(bobS.roomEvents(), nid1)
  doAssert okR
  let (okD, pcm, _) = decodeClip(record)
  doAssert okD and pcm.len == 3 * Second
  doAssert ioB.played == pcm, "the sink holds exactly the clip's samples: " & $ioB.played.len
  let p1k = goertzel(ioB.played, 1000.0)
  doAssert p1k > 0.25 * goertzel(tone, 1000.0), $p1k
  doAssert goertzel(ioB.played, 3100.0) < 0.01 * p1k, "the power is at 1 kHz"
  echo "1. a 3 s tone recorded, sent as two 90153 B frames, played by the other member: ",
       "the clip's samples exactly, 1 kHz; idle after done OK"

# ── 2. the 60 s cap ─────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(440.0, 70 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(aliceS).ck.ok
  var st: JsonNode
  for s in 1 .. 70:
    vc.advance(1_000)
    st = a.status()
    if s < 60:
      doAssert st["recording"]["state"].getStr() == "recording" and not st["recording"]["capped"].getBool(), $s & ": " & $st
  doAssert st["recording"]["state"].getStr() == "draft", "the cap made the draft: " & $st
  doAssert st["recording"]["capped"].getBool() and st["recording"]["elapsedMs"].getInt() == 60_000, $st
  doAssert st["recording"]["capMs"].getInt() == 60_000
  doAssert io.stream == asIdle, "the pump released the device at the cap"
  let stop = a.recordStop().ck
  doAssert stop["draft"]["durationMs"].getInt() == 60_000, "Stop hands back the capped draft: " & $stop
  let sent = a.draftSend(aliceS, aliceKs, nextTs()).ck
  let nid = sent{"note"}.getStr()
  doAssert nid.len == 32, $sent
  let row = noteRow(threadRows(bobS.roomEvents()), nid)
  doAssert row.note.state == vsComplete and row.note.durMs == 60_000, $row
  echo "2. a 70 s source stops at 60000 ms, capped, released by the pump; it sends OK"

# ── 3. an all-zero recording ────────────────────────────────────────────────────────
block:
  doAssert platformNote("macosx") ==
    "Basecamp 0.3.2 can't use the microphone on macOS yet: it lacks the microphone permission."
  doAssert platformNote("linux") == ""
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(newSeq[int16](2 * Second), vc.clock))
  let stop = a.recordFor(vc, aliceS, 2_000)
  doAssert stop["draft"]["durationMs"].getInt() == 2_000 and stop["draft"]["silent"].getBool(), $stop
  doAssert stop["draft"]["peak"].getInt() == 0, $stop
  let frames = wire.frames.len
  let heads = aliceS.heads()
  let digest = aliceS.digest()
  let r = a.draftSend(aliceS, aliceKs, nextTs()).ck
  doAssert r.err == "silent" and r{"detail"}.getStr() == platformNote(), $r
  doAssert wire.frames.len == frames, "nothing reached the topic"
  doAssert aliceS.heads() == heads and aliceS.digest() == digest, "nothing reached the log"
  let st = a.status()
  doAssert st["recording"]["state"].getStr() == "draft" and st["recording"]["silent"].getBool(), "the draft stays: " & $st
  doAssert st["ready"]["note"].getStr() == platformNote(), $st
  doAssert a.draftDiscard() == "ok"
  echo "3. an all-zero recording: Send refuses silent with the platform note (\"", platformNote(),
       "\"), nothing published OK"

# ── 4. under 500 ms ─────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, Second), vc.clock))
  doAssert a.recordFor(vc, aliceS, VoiceMinMs - 1)["draft"]["durationMs"].getInt() == 499
  let frames = wire.frames.len
  let digest = aliceS.digest()
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "too-short"
  doAssert wire.frames.len == frames and aliceS.digest() == digest, "nothing published"
  doAssert a.draftDiscard() == "ok"
  doAssert a.recordFor(vc, aliceS, VoiceMinMs)["draft"]["durationMs"].getInt() == 500
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck{"note"}.getStr().len == 32, "500 ms sends"
  doAssert wire.frames.len == frames + 2
  echo "4. 499 ms is too-short and publishes nothing; 500 ms sends OK"

# ── 5. busy ─────────────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 5 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStop().ck.err == "not-recording"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "no-draft"
  doAssert a.recordStart(aliceS).ck.ok
  doAssert a.recordStart(aliceS).ck.err == "busy", "start while recording"
  doAssert a.play(aliceS, nid1).ck.err == "busy", "play while recording"
  doAssert a.play(aliceS, "draft").ck.err == "busy", "play the draft while recording"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "no-draft", "send with no draft"
  vc.advance(1_000)
  doAssert a.recordStop().ck["draft"]["durationMs"].getInt() == 1_000
  doAssert a.recordStart(aliceS).ck.err == "busy", "start while a draft is held"
  doAssert a.play(aliceS, "draft").ck.ok
  doAssert a.status()["playing"]["note"].getStr() == "draft"
  doAssert a.recordStart(aliceS).ck.err == "busy", "start while playing"
  doAssert a.play(aliceS, nid1).ck.err == "busy", "play while playing"
  doAssert a.playStop() == "ok" and a.playStop() == "ok"
  let st = a.status()
  doAssert st["playing"].kind == JNull and st["recording"]["state"].getStr() == "draft", "back where it was: " & $st
  doAssert io.stream == asIdle
  doAssert a.play(aliceS, nid1).ck.ok, "a note plays beside a held draft"
  vc.advance(4_000)
  doAssert a.status()["playing"].kind == JNull
  doAssert a.status()["recording"]["state"].getStr() == "draft"
  doAssert a.draftDiscard() == "ok"
  doAssert a.recordStart(aliceS).ck.ok, "idle again: a recording starts"
  doAssert a.draftDiscard() == "ok"
  echo "5. busy while recording, playing or holding a draft; no-draft; not-recording OK"

# ── 6. no room joined ───────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(nil).ck.err == "not-joined"
  doAssert io.stream == asIdle and a.status()["ready"]["capture"].getStr() == "unknown", "nothing opened"
  doAssert a.play(nil, nid1).ck.err == "not-joined"
  doAssert io.stream == asIdle
  discard a.recordFor(vc, aliceS, 1_000)
  doAssert a.draftSend(nil, aliceKs, nextTs()).ck.err == "not-joined"
  doAssert a.status()["recording"]["state"].getStr() == "draft", "the draft stays"
  doAssert a.play(nil, "draft").ck.ok, "a draft plays with no room"
  doAssert a.playStop() == "ok" and a.draftDiscard() == "ok"
  echo "6. no room: start, send and play a note refuse not-joined, nothing opened OK"

# ── 7. play refusals ────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(@[], vc.clock)
  let b = newVoiceRecorder(io)
  doAssert b.play(bobS, "0f".repeat(16)).ck.err == "unknown-note"
  # arriving: one part of a real clip
  let (okE, clip, _) = encodeClip(sine(1000.0, Second))
  doAssert okE
  let (nidA, partsA) = voiceEvents(alice, clip, nextTs())
  aliceS.publishAuthored(aliceKs, partsA[0])
  doAssert noteRow(b.rows(bobS), nidA).note.state == vsArriving
  doAssert b.play(bobS, nidA).ck.err == "incomplete"
  # broken: two halves of bytes that are no record
  let junk = toSeq(0'u8 .. 199'u8)
  let (nidB, partsB) = voicePartEvents(alice, junk, nextTs(), 1_000)
  for e in partsB: aliceS.publishAuthored(aliceKs, e)
  doAssert noteRow(b.rows(bobS), nidB).note.state == vsBroken
  doAssert b.play(bobS, nidB).ck.err == "broken"
  # complete to the fold, which decodes no audio, but its packets are not Opus libopus reads
  var fake = VoiceClip(preskip: 312, samples: Second)
  for i in 0 ..< packetCount(Second, 312): fake.packets.add newSeqWith(PacketBytes, 0xFF'u8)
  let (nidF, partsF) = voiceEvents(alice, fake, nextTs())
  for e in partsF: aliceS.publishAuthored(aliceKs, e)
  doAssert noteRow(b.rows(bobS), nidF).note.state == vsComplete
  doAssert not decodeClip(encodeRecord(fake)).ok
  doAssert b.play(bobS, nidF).ck.err == "broken"
  doAssert io.stream == asIdle and b.status()["playing"].kind == JNull, "no refusal opened a device"
  echo "7. play refuses unknown-note, incomplete, broken, and broken for packets libopus refuses OK"

# ── 9. incremental encoding ─────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, 60 * Second), vc.clock))
  doAssert a.recordStart(aliceS).ck.ok
  doAssert a.encodedMs() == 0
  for s in 1 .. 59:
    vc.advance(1_000)
    discard a.status()
    doAssert a.encodedMs() == s * 1_000, $s & " s of pumps: " & $a.encodedMs() & " ms encoded"
  vc.advance(500)
  doAssert a.encodedMs() == 59_000, "Stop finds 0.5 s left to encode"
  doAssert a.recordStop().ck["draft"]["durationMs"].getInt() == 59_500
  doAssert a.encodedMs() == 59_500
  doAssert a.draftDiscard() == "ok"
  echo "9. each pump encodes what was captured: after 59 s Stop encodes the last 0.5 s alone OK"

# ── 10. discard ─────────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 5 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  discard a.recordFor(vc, aliceS, 1_000)
  doAssert a.draftDiscard() == "ok" and a.draftDiscard() == "ok"
  doAssert a.status()["recording"]["state"].getStr() == "idle"
  doAssert a.play(aliceS, "draft").ck.err == "no-draft"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "no-draft"
  doAssert a.recordStart(aliceS).ck.ok
  vc.advance(700)
  doAssert a.draftDiscard() == "ok", "a recording in progress is dropped too"
  doAssert io.stream == asIdle and a.status()["recording"]["state"].getStr() == "idle"
  doAssert a.recordStop().ck.err == "not-recording"
  echo "10. discard drops the draft and a recording; then play(draft) and send say no-draft OK"

# ── 11. the memo ────────────────────────────────────────────────────────────────────
block:
  let b = newVoiceRecorder(newSyntheticAudioIo(@[], VirtualClock().clock))
  let first = b.rows(bobS)
  let memo = b.memoFor(bobS)
  var pairs = 0
  for n in reduceVoice(bobS.roomEvents()):
    if n.parts[0].len > 0 and n.parts[1].len > 0: inc pairs
  doAssert pairs >= 4 and memo.len == pairs and memo.hits == 0, $pairs & " " & $memo.len & " " & $memo.hits
  let second = b.rows(bobS)
  doAssert second == first and memo.hits == pairs, "every verdict served from the memo: " & $memo.hits
  let elsewhere = newCoordinationSession(newLocalTransport(net),
                                         newEpochCrypto(bobKs, "/muster/1/another-room/proto", @[]),
                                         "/muster/1/another-room/proto")
  doAssert b.memoFor(bobS) == memo and b.memoFor(elsewhere) != memo, "one memo per room"
  doAssert first == threadRows(bobS.roomEvents()), "the memo changes no row"
  echo "11. the thread's rows judge each pair of parts once, then serve the memo's verdict OK"

# ── 12. which AudioIo, and FileAudioIo end to end ───────────────────────────────────
block:
  doAssert voiceIoChoice("", "", "") == (kind: vkSystem, source: "", sink: "")
  doAssert voiceIoChoice("", "", "null") == (kind: vkNull, source: "", sink: "")
  doAssert voiceIoChoice("", "", "system") == (kind: vkSystem, source: "", sink: "")
  doAssert voiceIoChoice("", "", "pulse") == (kind: vkSystem, source: "", sink: "")
  doAssert voiceIoChoice("/a.wav", "", "null") == (kind: vkFile, source: "/a.wav", sink: "")
  doAssert voiceIoChoice("", "/b.pcm", "") == (kind: vkFile, source: "", sink: "/b.pcm")
  let dir = getTempDir() / ("muster_voice_live_test_" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  proc le16(v: int): string = char(v and 0xFF) & char((v shr 8) and 0xFF)
  proc le32(v: int): string = le16(v and 0xFFFF) & le16((v shr 16) and 0xFFFF)
  let tone = sine(1000.0, Second)
  var data = ""
  for s in tone: data.add le16(int(cast[uint16](s)))
  let fmt = "fmt " & le32(16) & le16(1) & le16(1) & le32(ClipRate) & le32(ClipRate * 2) & le16(2) & le16(16)
  writeFile(dir / "tone.wav", "RIFF" & le32(4 + fmt.len + 8 + data.len) & "WAVE" & fmt & "data" & le32(data.len) & data)
  let vc = VirtualClock()
  let a = newVoiceRecorder(newFileAudioIo(dir / "tone.wav", "", vc.clock))
  doAssert a.recordFor(vc, aliceS, 1_000)["draft"]["durationMs"].getInt() == 1_000
  let nid = a.draftSend(aliceS, aliceKs, nextTs()).ck{"note"}.getStr()
  doAssert nid.len == 32
  let b = newVoiceRecorder(newFileAudioIo("", dir / "sink.pcm", vc.clock))
  doAssert b.play(bobS, nid).ck.ok
  vc.advance(1_100)
  doAssert b.status()["playing"].kind == JNull
  let (_, pcm, _) = decodeClip(voiceRecordOf(bobS.roomEvents(), nid).record)
  var want = ""
  for s in pcm: want.add le16(int(cast[uint16](s)))
  doAssert readFile(dir / "sink.pcm") == want, "the sink holds the clip's samples, s16le"
  let none = newVoiceRecorder(newFileAudioIo(dir / "missing.wav", "", vc.clock))
  doAssert none.recordStart(aliceS).ck.err == "no-source"
  let st = none.status()
  doAssert st["ready"]["capture"].getStr() == "no-source" and st["recording"]["state"].getStr() == "idle", $st
  echo "12. the env picks FileAudioIo, miniaudio null or the system; a WAV recorded, sent and played ",
       "into a PCM sink; a missing source is no-source OK"

# ── 13. miniaudio's null device ─────────────────────────────────────────────────────
block:
  let io = newMiniaudioIo(abNull)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(aliceS).ck.ok
  doAssert waitUntil(proc (): bool = a.state == "recording", 2_000), "the null device starts"
  doAssert io.backendName() == "Null"
  for _ in 0 ..< 8:
    sleep(100)
    discard a.status()
  let stop = a.recordStop().ck
  doAssert stop["draft"]["durationMs"].getInt() in 500 .. 3_000, $stop
  doAssert stop["draft"]["silent"].getBool() and stop["draft"]["peak"].getInt() == 0, "the null device captures zeros: " & $stop
  doAssert io.backendName() == "", "the context is released when the stream ends"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "silent"
  doAssert a.draftDiscard() == "ok" and a.close() == "ok"
  echo "13. miniaudio's null device: zeros, refused silent; the context released after Stop OK"

# ── 14. close ───────────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 5 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(aliceS).ck.ok
  vc.advance(600)
  doAssert a.close() == "ok"
  doAssert io.stream == asIdle and a.status()["recording"]["state"].getStr() == "idle"
  doAssert a.play(bobS, nid1).ck.ok
  doAssert a.close() == "ok" and a.close() == "ok"
  doAssert io.stream == asIdle and a.status()["playing"].kind == JNull
  echo "14. close stops what runs and releases the device, idempotently OK"

# ── 15. a Send that fails between its parts, retried ────────────────────────────────
block:
  const topic2 = "/muster/1/room-voice-retry/proto"
  let ac = newEpochCrypto(aliceKs, topic2, @[bobKs.encIdentity()])
  let bc = newEpochJoiner(bobKs)
  bc.ingestGrant(ac.grantFor(0, bobKs.encIdentity()))
  let a2 = newCoordinationSession(newLocalTransport(net), ac, topic2)
  let refuse = refuser(net, topic2)       # subscribed before Bob: he never sees what it refuses
  let b2 = newCoordinationSession(newLocalTransport(net), bc, topic2)
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, 2 * Second), vc.clock))
  discard a.recordFor(vc, a2, 1_000)
  refuse.left = 1                         # part 0 goes out, part 1 is refused
  doAssertRaises(IOError): discard a.draftSend(a2, aliceKs, nextTs())
  let first = reduceVoice(b2.roomEvents())
  doAssert first.len == 1 and first[0].state == vsArriving, "Bob holds part 0 alone: " & $first
  doAssert a.status()["recording"]["state"].getStr() == "draft", "the draft is kept"
  # session.publish logs a part before the transport sees it, so Alice's log took part 1 too:
  # her own fold calls the note complete while the room holds half of it, and her retry
  # finds both parts held and re-sends both on the held path (voice-notes.md §4, §8)
  let mine = reduceVoice(a2.roomEvents())
  doAssert mine.len == 1 and mine[0].nid == first[0].nid and mine[0].state == vsComplete, $mine
  doAssert mine[0].parts.allIt(a2.log.find(it).found), "both parts are in the sender's log"
  let sent = a.draftSend(a2, aliceKs, nextTs()).ck
  doAssert sent{"note"}.getStr() == first[0].nid, "the retry sends the same note: " & $sent
  let after = reduceVoice(b2.roomEvents())
  doAssert after.len == 1 and after[0].state == vsComplete and after[0].nid == first[0].nid, $after
  doAssert a.status()["recording"]["state"].getStr() == "idle"
  echo "15. a Send refused between its parts keeps the draft; the sender's fold already calls it ",
       "complete; the retry re-sends both parts held, the same note, complete, nothing stranded OK"

# ── 16. no audio at all is too short, not silent ─────────────────────────────────────
block:
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, Second), vc.clock))
  doAssert a.recordStart(aliceS).ck.ok
  let stop = a.recordStop().ck                    # at once: not one sample captured
  doAssert stop["draft"]["durationMs"].getInt() == 0 and not stop["draft"]["silent"].getBool(), $stop
  let r = a.draftSend(aliceS, aliceKs, nextTs()).ck
  doAssert r.err == "too-short" and r{"detail"} == nil, "nothing recorded is too short, not silent: " & $r
  doAssert a.status()["ready"]["note"].getStr() == "", "and says nothing about the microphone"
  doAssert a.draftDiscard() == "ok"
  let z = newVoiceRecorder(newSyntheticAudioIo(newSeq[int16](Second), vc.clock))
  let zs = z.recordFor(vc, aliceS, 300)            # 300 ms of zeros
  doAssert zs["draft"]["durationMs"].getInt() == 300 and zs["draft"]["silent"].getBool(), $zs
  doAssert z.draftSend(aliceS, aliceKs, nextTs()).ck.err == "too-short", "under 500 ms is too short first"
  doAssert z.status()["ready"]["note"].getStr() == ""
  doAssert z.draftDiscard() == "ok"
  echo "16. a recording of nothing, or 300 ms of zeros, is too-short, with no microphone note OK"

# ── 17. each call reads the device side first ────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 70 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.play(aliceS, nid1).ck.ok
  vc.advance(3_100)                               # nid1 (3 s) heard to its end; no status read
  doAssert a.play(aliceS, nid1).ck.ok, "a playback heard to its end is not busy to Play"
  vc.advance(3_100)
  doAssert a.recordStart(aliceS).ck.ok, "nor to Start"
  doAssert io.stream == asCapture
  vc.advance(61_000)                              # the cap passes; no status read since
  let sent = a.draftSend(aliceS, aliceKs, nextTs()).ck
  doAssert sent{"note"}.getStr().len == 32, "Send finds the draft the cap made: " & $sent
  doAssert noteRow(threadRows(bobS.roomEvents()), sent["note"].getStr()).note.durMs == 60_000
  doAssert io.stream == asIdle and a.status()["recording"]["state"].getStr() == "idle"
  echo "17. Play and Start after a playback ended unread, and Send after the cap, each see it OK"

# ── 18. a draft belongs to its room ─────────────────────────────────────────────────
block:
  const topic3 = "/muster/1/room-voice-elsewhere/proto"
  let elsewhere = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic3, @[]), topic3)
  let w3 = tap(net, topic3)
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, 2 * Second), vc.clock))
  discard a.recordFor(vc, aliceS, 1_000)          # recorded in aliceS's room
  let frames = wire.frames.len
  let digest = aliceS.digest()
  let r = a.draftSend(elsewhere, aliceKs, nextTs()).ck
  doAssert r.err == "room-changed", "Send in another room: " & $r
  doAssert w3.frames.len == 0 and elsewhere.log.allEvents().len == 0, "nothing reached the other room"
  doAssert wire.frames.len == frames and aliceS.digest() == digest, "nor its own"
  doAssert a.status()["recording"]["state"].getStr() == "draft", "the draft is kept"
  let sent = a.draftSend(aliceS, aliceKs, nextTs()).ck
  doAssert sent{"note"}.getStr().len == 32 and wire.frames.len == frames + 2, "it sends in its own room: " & $sent
  echo "18. a draft sent through another room's session is room-changed, nothing published, kept; ",
       "it sends in its own room OK"

# ── 19. Send and Discard stop the draft's playback ───────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 5 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  discard a.recordFor(vc, aliceS, 1_000)
  doAssert a.play(aliceS, "draft").ck.ok
  vc.advance(300)
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck{"note"}.getStr().len == 32
  doAssert io.stream == asIdle, "Send released the draft's playback"
  doAssert a.status()["playing"].kind == JNull
  discard a.recordFor(vc, aliceS, 1_000)
  doAssert a.play(aliceS, "draft").ck.ok
  vc.advance(300)
  doAssert a.draftDiscard() == "ok"
  doAssert io.stream == asIdle, "Discard released it"
  doAssert a.status()["playing"].kind == JNull
  echo "19. Send and Discard while the draft plays stop it and release the device OK"

# ── 20. a sink that refuses a write ─────────────────────────────────────────────────
block:
  let dir = getTempDir() / ("muster_voice_live_sink_" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let vc = VirtualClock()
  let io = newFileAudioIo("", dir / "sink.pcm", vc.clock)
  let b = newVoiceRecorder(io)
  doAssert b.play(bobS, nid1).ck.ok
  # The process may write files of 1 KB at most, so the sink's next write fails (EFBIG; the
  # signal it would raise is ignored for the while). Nothing else writes in this window.
  var was, lim: RLimit
  doAssert getrlimit(RLIMIT_FSIZE, was) == 0
  lim = was
  lim.rlim_cur = 1024
  signal(SIGXFSZ, SIG_IGN)
  doAssert setrlimit(RLIMIT_FSIZE, lim) == 0
  vc.advance(1_000)                               # 96,000 B due to the sink
  let st = b.status()
  doAssert setrlimit(RLIMIT_FSIZE, was) == 0
  signal(SIGXFSZ, SIG_DFL)
  doAssert st["ready"]["playback"].getStr() == "sink-write", $st
  doAssert st["playing"].kind == JNull and io.stream == asIdle, "the refused sink's stream is released: " & $st
  echo "20. a sink write refused past a file-size limit ends the playback: sink-write, released OK"

# ── 21. the recorder owns its AudioIo ────────────────────────────────────────────────
block:
  # A stream opened on the io behind the recorder's back stands in for a start that failed
  # once miniaudio's context was made: whatever the io holds, a refused start and close end.
  let io = newMiniaudioIo(abNull)
  let a = newVoiceRecorder(io)
  let held = newAudioBuffer(Second)
  doAssert io.startPlayback(held) == "" and io.landed() == "" and io.backendName() == "Null"
  let r = a.recordStart(aliceS).ck
  doAssert r.err == "busy" and a.status()["ready"]["capture"].getStr() == "busy", $r
  doAssert io.backendName() == "" and io.stream == asIdle, "a refused start released the context"
  doAssert io.startPlayback(held) == "" and io.landed() == "" and io.backendName() == "Null"
  doAssert a.close() == "ok"
  doAssert io.backendName() == "" and io.stream == asIdle, "close released the device and the context"
  freeAudioBuffer(held)
  echo "21. a refused start and close release what the io holds, miniaudio's context included OK"

# ── 22. the rows coordinate_messages serves ──────────────────────────────────────────
block:
  let bob = hex(bobKs.encIdentity().toBytes())
  let tsA = nextTs()
  let (mA, evA) = newMessageEvent(alice, tsA, "a line of text", 1)
  aliceS.publishAuthored(aliceKs, evA)
  let tsB = nextTs()
  let (mB, evB) = newMessageEvent(bob, tsB, "a reply", 1)
  bobS.publishAuthored(bobKs, evB)
  let b = newVoiceRecorder(newSyntheticAudioIo(@[], VirtualClock().clock))
  let rows = b.messagesJson(bobS, proc (who: string): string =
    if normId(who) == alice: "Alice" elif normId(who) == bob: "Bob" else: "")
  var byId: Table[string, JsonNode]
  for r in rows: byId[r["id"].getStr()] = r
  doAssert byId[mA] == %*{"id": mA, "author": alice, "ts": tsA, "body": "a line of text",
                          "alias": "Alice", "self": false}, $byId[mA]
  doAssert byId[mB] == %*{"id": mB, "author": bob, "ts": tsB, "body": "a reply",
                          "alias": "Bob", "self": true}, $byId[mB]
  let n = byId[nid1]
  doAssert toSeq(n.keys).sorted() == @["alias", "author", "body", "id", "self", "ts", "voice"], $n
  doAssert n["author"].getStr() == alice and n["body"].getStr() == "" and n["alias"].getStr() == "Alice" and
           not n["self"].getBool(), $n
  doAssert n["voice"] == %*{"v": 1, "note": nid1, "durationMs": 3_000, "state": "complete"}, $n
  var last = 0'i64
  for r in rows:
    doAssert r["ts"].getInt() >= last, "oldest first"
    last = r["ts"].getInt()
  echo "22. coordinate_messages' rows: {id, author, ts, body, alias, self}, a note's with voice OK"

# ── 23. no proof of a room that holds a voice note ───────────────────────────────────
block:
  let refused = roomProof(aliceS).ck
  doAssert refused{"error"}.getStr() == "voice-notes-present" and refused{"events"} == nil,
           "no proof of a room holding a voice note; got the keys " & $toSeq(refused.keys)
  const topic4 = "/muster/1/room-voice-proof/proto"
  let s4 = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic4, @[]), topic4)
  let (_, ev) = newMessageEvent(alice, nextTs(), "no voice here", 2)
  s4.publishAuthored(aliceKs, ev)
  let p = roomProof(s4)
  doAssert p{"error"} == nil and p["events"].len == 1, $p
  let (okP, why) = verifyProof(proofFromJson(p))
  doAssert okP, why
  s4.publish(Event(key: "voice/not-a-note", value: "{}"))   # unsigned, no note's shape
  doAssert reduceVoice(s4.roomEvents()).len == 0, "no fold stands it"
  # since the review (corpetty, PR 340): a voice/ entry no fold stands refuses nothing, so
  # one member's junk cannot switch the room's proof off for good; §26 holds the rest
  let pj = roomProof(s4)
  doAssert pj{"error"} == nil and pj["events"].len == 2, "a voice/ entry no fold stands refuses nothing: " & $pj{"error"}
  echo "23. coordinate_proof refuses voice-notes-present for a room holding a voice note; ",
       "a room with none exports a proof that verifies OK"

# ── 24. a member's copy of a part does not block the author's retry ──────────────────
block:
  const topic5 = "/muster/1/room-voice-variant/proto"
  let malKs = newInMemoryKeystore(seed(0x73), seed(0x83))
  let ac = newEpochCrypto(aliceKs, topic5, @[bobKs.encIdentity(), malKs.encIdentity()])
  let bc = newEpochJoiner(bobKs)
  bc.ingestGrant(ac.grantFor(0, bobKs.encIdentity()))
  let mc = newEpochJoiner(malKs)
  mc.ingestGrant(ac.grantFor(0, malKs.encIdentity()))
  let refuse = refuser(net, topic5)       # before the members: none sees what it refuses
  let w5 = tap(net, topic5)
  let a5 = newCoordinationSession(newLocalTransport(net), ac, topic5)
  let b5 = newCoordinationSession(newLocalTransport(net), bc, topic5)
  let m5 = newCoordinationSession(newLocalTransport(net), mc, topic5)
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, 2 * Second), vc.clock))
  discard a.recordFor(vc, a5, 1_000)
  refuse.left = 1                         # part 0 goes out, part 1 is refused
  doAssertRaises(IOError): discard a.draftSend(a5, aliceKs, nextTs())
  # Mallory, who received part 0, sends a copy of it: the same id, an `after` of 1,400
  # made-up ids nobody signed, ground until it sorts before Alice's copy, so her log keeps it
  var p0: Event
  for e in m5.log.allEvents():
    if isVoiceKey(e.key) and e.key.split('/')[3] == "0": p0 = e
  doAssert p0.key.len > 0, "Mallory holds part 0"
  let aliceCopy = a5.log.find(eventId(p0)).event
  var v = p0
  var n = 0
  while true:
    inc n
    v.after = @[]
    for k in 0 ..< 1400: v.after.add hex(seed(byte(n and 0xff))) & ($k).align(6, '0') & ($n).align(58, '0')
    v.afterSig = ""
    if afterDigest(v) < afterDigest(aliceCopy): break
  var j = %*{"parents": [], "key": v.key, "value": v.value}
  j["after"] = %v.after
  var plain: seq[byte]
  for c in $j: plain.add byte(c)
  doAssert plain.len > 90_112, "the copy does not fit a voice frame: " & $plain.len & " B"
  discard newLocalTransport(net).publish(topic5, @[0x00'u8] & mc.seal(plain))
  doAssert a5.log.find(eventId(p0)).event.after.len == 1400, "Alice's log keeps Mallory's copy"
  let before = w5.dataFrames().len
  let sent = a.draftSend(a5, aliceKs, nextTs()).ck
  doAssert sent{"note"}.getStr().len == 32, "the retry is not blocked: " & $sent
  let resent = w5.dataFrames()[before .. ^1]
  doAssert resent.len == 2 and resent.allIt(it.len == WireBytes), "two frames of 90,153 B: " & $resent.mapIt(it.len)
  let bobHolds = reduceVoice(b5.roomEvents())
  doAssert bobHolds.len == 1 and bobHolds[0].nid == sent["note"].getStr() and bobHolds[0].state == vsComplete, $bobHolds
  echo "24. a member's long unsigned copy of part 0, kept by the author's log, does not block ",
       "the retry: it re-seals the author's own copy, two frames of 90,153 B, complete for Bob OK"

# ── 25. a note's two frames leave back to back ───────────────────────────────────────
block:
  const topic6 = "/muster/1/room-voice-burst/proto"
  let ac = newEpochCrypto(aliceKs, topic6, @[bobKs.encIdentity()])
  let bc = newEpochJoiner(bobKs)
  bc.ingestGrant(ac.grantFor(0, bobKs.encIdentity()))
  let a6 = newCoordinationSession(newLocalTransport(net), ac, topic6)
  var journal: seq[seq[byte]]
  a6.setJournal(proc (f: seq[byte]) {.gcsafe.} = {.cast(gcsafe).}: journal.add f)
  let b6 = newCoordinationSession(newLocalTransport(net), bc, topic6)
  # when the first voice frame reaches the transport, what of the note is already done
  var atFirst: tuple[logged, journalled, frames: int] = (-1, -1, 0)
  newLocalTransport(net).subscribe(topic6, proc (m: IncomingMessage) {.gcsafe.} =
    {.cast(gcsafe).}:
      if m.payload.len == WireBytes:
        if atFirst.frames == 0:
          atFirst.logged = a6.log.allEvents().countIt(isVoiceKey(it.key))
          atFirst.journalled = journal.deduplicate().countIt(it.len == WireBytes)
        inc atFirst.frames)
  for secs in [1, 59]:
    atFirst = (-1, -1, 0)
    journal = @[]
    let vc = VirtualClock()
    let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, (secs + 1) * Second), vc.clock))
    discard a.recordFor(vc, a6, secs * 1000)
    let before = a6.log.allEvents().countIt(isVoiceKey(it.key))
    doAssert a.draftSend(a6, aliceKs, nextTs()).ck{"note"}.getStr().len == 32
    doAssert atFirst.frames == 2, "two voice frames: " & $atFirst
    # both parts signed, padded, sealed, logged and journalled before the first frame leaves:
    # what is left between the two sends is the first send itself, the same for any length
    doAssert atFirst.logged == before + 2 and atFirst.journalled == 2,
             "at the first send of a " & $secs & " s note: " & $atFirst & " (voice entries before: " & $before & ")"
  let bobNotes = reduceVoice(b6.roomEvents())
  doAssert bobNotes.len == 2 and bobNotes.allIt(it.state == vsComplete), $bobNotes
  echo "25. both parts of a 1 s and a 59 s note are logged and journalled before the first ",
       "frame leaves, so the two sends are back to back OK"

# ── 26. a proof is refused for a note's part the room's view stands, not for junk ────
block:
  let malKs = newInMemoryKeystore(seed(0x74), seed(0x84))
  proc signedAs(ks: Keystore, room: string, e: Event): Event =
    ## `e` signed by `ks` for `room`, whoever its key names: a forgery unless `ks` is its author.
    var j = parseJson(e.value)
    j["authorSig"] = %hex(ks.edSign(authorDigest(room, e)))
    Event(parents: e.parents, key: e.key, value: $j)
  let (okR, record) = voiceRecordOf(bobS.roomEvents(), nid1)
  doAssert okR
  let clip = decodeRecord(record).clip                 # a real note's clip, 3 s
  proc junkRoom(t: string): tuple[s: CoordinationSession, copied: string] =
    ## A room of Alice's whose raw log holds a message and, under voice/, only junk: entries
    ## the room's view drops (unsigned, a forged author) and entries it keeps that no fold
    ## stands (a malformed value, a squatted note id, keys of the wrong shape). The unsigned
    ## one copies a real note's half; `copied` is that half.
    let s = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, t, @[]), t)
    let (_, m) = newMessageEvent(alice, nextTs(), "no note here", 3)
    s.publishAuthored(aliceKs, m)
    let (nid, parts) = voiceEvents(alice, clip, nextTs())
    s.publish(parts[0])                                                    # unsigned
    s.publish(signedAs(malKs, t, parts[1]))                                # Mallory, under Alice's key
    var bad = parseJson(parts[1].value)
    bad["part"] = %"    AB"                                                # base64 decode reads past the end of
    s.publish(signedAs(aliceKs, t, Event(key: parts[1].key, value: $bad)))
    s.publish(signedAs(aliceKs, t, Event(key: parts[0].key, value: $(%*{"v": 1}))))
    s.publish(signedAs(aliceKs, t, Event(key: "voice/" & "0f".repeat(16) & "/" & alice & "/0/2",
                                         value: parts[0].value)))           # squatted: her clip, another nid
    s.publish(signedAs(aliceKs, t, Event(key: "voice/" & nid & "/" & alice & "/0/3", value: parts[0].value)))
    s.publish(Event(key: "voice/not-a-note", value: "{}"))
    (s, parseJson(parts[0].value)["part"].getStr())
  let (j, copied) = junkRoom("/muster/1/room-voice-junk/proto")
  let raw = j.log.allEvents()
  let junk = raw.filterIt(isVoiceKey(it.key))
  doAssert junk.len == 7 and raw.len == 8, $junk.len & " " & $raw.len
  doAssert j.roomEvents().countIt(isVoiceKey(it.key)) == 4, "the view keeps the four Alice signed"
  doAssert voiceStanding(j.roomEvents()).len == 0 and reduceVoice(j.roomEvents()).len == 0, "no fold stands any"
  let p = j.roomProof()
  doAssert p{"error"} == nil, "junk alone refuses nothing: " & $p
  let ids = p["ids"].getElems().mapIt(it.getStr())
  doAssert p["events"].len == raw.len, $p["events"].len
  for e in raw: doAssert eventId(e) in ids, "the proof accounts for every raw entry (exo-f76): " & e.key
  let (okP, why) = verifyProof(proofFromJson(p))
  doAssert okP, why
  # what it costs (voice-notes.md §10): junk that copies a note's bytes, in a room whose view
  # holds none of that note's parts, leaves with the proof, as a message's body would
  doAssert copied.len > 1_000 and copied in $p
  # a note the fold stands, whatever its state, refuses as before, beside the same junk
  let (_, brokenParts) = voicePartEvents(alice, newSeq[byte](300), nextTs(), 1_000)
  for (what, k) in [("arriving", 1), ("complete", 2), ("broken", -1)]:
    let (r, _) = junkRoom("/muster/1/room-voice-junk-" & what & "/proto")
    let parts = (if k < 0: brokenParts else: voiceEvents(alice, clip, nextTs()).events)
    for i in 0 ..< (if k < 0: 2 else: k): r.publishAuthored(aliceKs, parts[i])
    let notes = reduceVoice(r.roomEvents())
    doAssert notes.len == 1 and $notes[0].state == what, what & ": " & $notes
    let q = r.roomProof()
    doAssert q == %*{"error": ProofRefusal, "detail": ProofRefusalDetail}, what & ": " & $q
    doAssert q["error"].getStr() == "voice-notes-present"
  echo "26. a room whose raw log holds only junk under voice/ (unsigned, a forged author, a malformed ",
       "value, a squatted note id, wrong-shape keys) exports a proof that accounts for every entry; ",
       "a note arriving, complete or broken refuses voice-notes-present as before OK"

# ── 27. a poll parses no part twice: the room's memo keeps each part's header ────────
block:
  let b = newVoiceRecorder(newSyntheticAudioIo(@[], VirtualClock().clock))
  let memo = b.memoFor(bobS)
  let inView = bobS.roomEvents().countIt(isVoiceKey(it.key))
  doAssert inView >= 12, $inView
  proc counts(): (int, int) = (voiceParses(), voiceHalfReads())
  proc since(c: (int, int)): (int, int) = (voiceParses() - c[0], voiceHalfReads() - c[1])
  var c = counts()
  let rows0 = b.rows(bobS)
  doAssert since(c) == (inView, 0), "a cold read parses each part once and reads no half back: " & $since(c)
  c = counts()
  let last0 = b.lastTs(bobS, bobS.roomEvents())
  doAssert b.rows(bobS) == rows0 and b.lastTs(bobS, bobS.roomEvents()) == last0
  doAssert since(c) == (0, 0), "over an unchanged log coordinate_messages' rows and threadLastTs parse 0 parts: " & $since(c)
  doAssert memo.headers == inView, "one header per part in the room's view: " & $memo.headers
  # a new part arrives: that one alone is parsed
  let clip = decodeRecord(voiceRecordOf(bobS.roomEvents(), nid1).record).clip
  let tsN = nextTs()
  let (nidN, partsN) = voiceEvents(alice, clip, tsN)
  aliceS.publishAuthored(aliceKs, partsN[0])
  c = counts()
  var rows = b.rows(bobS)
  doAssert since(c) == (1, 0), "the new part alone: " & $since(c)
  doAssert noteRow(rows, nidN).note.state == vsArriving
  c = counts()
  doAssert b.lastTs(bobS, bobS.roomEvents()) == tsN and since(c) == (0, 0), $since(c)
  aliceS.publishAuthored(aliceKs, partsN[1])
  c = counts()
  rows = b.rows(bobS)
  doAssert since(c) == (1, 1), "the other part alone, and part 0's half read back once for the verdict: " & $since(c)
  doAssert noteRow(rows, nidN).note.state == vsComplete
  c = counts()
  doAssert b.rows(bobS) == rows and since(c) == (0, 0), "nothing again on the next poll: " & $since(c)
  doAssert rows == threadRows(bobS.roomEvents()) and b.lastTs(bobS, bobS.roomEvents()) == threadLastTs(bobS.roomEvents()),
           "the rows and lastTs a read with no memo gives"
  # Play gathers once, through the memo: no part parsed, the two halves it decodes read back
  c = counts()
  doAssert b.play(bobS, nidN).ck.ok
  doAssert since(c) == (0, 2), "Play: " & $since(c)
  doAssert b.playStop() == "ok"
  # bounded by the room's log: one header per part; a room left takes its memo with it
  doAssert memo.headers == inView + 2
  const t7 = "/muster/1/room-voice-memo/proto"
  let other = newCoordinationSession(newLocalTransport(net), newEpochCrypto(bobKs, t7, @[]), t7)
  doAssert b.rows(other).len == 0 and b.memoRooms == 2
  b.forgetRoom(t7)
  doAssert b.memoRooms == 1 and b.memoFor(bobS) == memo
  b.forgetRoom(topic)
  doAssert b.memoRooms == 0
  c = counts()
  doAssert b.rows(bobS) == rows and since(c)[0] == inView + 2 and b.memoFor(bobS) != memo,
           "the room read again starts a fresh memo: " & $since(c)
  echo "27. the room's memo keeps each part's header: an unchanged log parses 0 parts, a new part ",
       "alone is parsed, Play gathers once and reads back the two halves it decodes; a room left ",
       "drops its memo OK"

# ── 28. the room's other polled reads go through its memo: the flow, the map, provenance ─
# PR 340's review, again: coordinate_flow (on the room's 5 s tick) and coordinate_graph (every
# 2 s while the map is open) folded with no memo, so each poll parsed every part's value again,
# and coordinate_conversations passed the memo itself, in a line no test ran. The hosted
# methods now call the recorder's flowRows, graphOf, provenanceOf and lastTs, each over the
# events the method read and the room's memo, the one memoFor gives and the thread's rows use.
block:
  let stub: DriverFor = proc(kind: string): Driver = newStubDriver(rounds = 1, threshold = 1, verifyResult = true)
  let evs = bobS.roomEvents()
  var roster: seq[string]
  for m in bobS.members(): roster.add hex(m.toBytes())
  let founders = foundersOf(evs, roster)
  let me = hex(bobKs.encIdentity().toBytes())
  let parts = evs.countIt(isVoiceKey(it.key))
  doAssert parts >= 14 and voiceStanding(evs).len == parts, $parts & " " & $voiceStanding(evs).len
  proc reads(v: VoiceRecorder): string =
    $(%*{"flow": $v.flowRows(bobS, evs, stub, founders),
         "graph": v.graphOf(bobS, evs, stub, founders, me).toJson(),
         "provenance": $v.provenanceOf(bobS, evs, stub),
         "lastTs": v.lastTs(bobS, evs)})
  let want = $(%*{"flow": $reduceFlow(evs, stub, founders, bobS.sealedIn),
                  "graph": reduceRoomGraph(evs, stub, founders, me, bobS.sealedIn).toJson(),
                  "provenance": $logProvenance(evs, stub, bobS.sealedIn),
                  "lastTs": threadLastTs(evs)})
  let b = newVoiceRecorder(newSyntheticAudioIo(@[], VirtualClock().clock))
  var p0 = voiceParses()
  doAssert b.reads() == want, "the memo-less folds' output"
  doAssert voiceParses() - p0 == parts, "cold: each part once across the four reads: " & $(voiceParses() - p0)
  p0 = voiceParses()
  doAssert b.reads() == want and voiceParses() == p0,
           "warm: the next poll of each parses 0 parts: " & $(voiceParses() - p0)
  doAssert b.memoFor(bobS).headers == parts, "the room's memo, the one memoFor gives"
  # the thread's rows warm the memo the others read
  let c = newVoiceRecorder(newSyntheticAudioIo(@[], VirtualClock().clock))
  discard c.rows(bobS)
  p0 = voiceParses()
  doAssert c.reads() == want and voiceParses() == p0,
           "after coordinate_messages' rows, the flow, the map, provenance and lastTs parse 0 parts: " &
           $(voiceParses() - p0)
  doAssert b.close() == "ok" and c.close() == "ok"
  echo "28. the flow, the map, provenance and lastTs go through the room's memo, the thread's own: the ",
       "memo-less output; each part parsed once across them, none on the next poll OK"

# ── A device start held (PR 340's review: starting a device could hold the module thread) ─
# A StartGate holds SyntheticAudioIo's device start, as Core Audio held one behind an
# unanswered microphone prompt (S11). A safety net releases each gate after 1.5 s, so a start
# that blocks its caller returns late and fails on the time instead of hanging the test.


# ── 29. voice_record_start answers at once; the recording starts when the device does ─
block:
  let base = liveAudioBuffers()
  let vc = VirtualClock(ms: 1_000)
  let g = newStartGate()
  var net: Thread[Net]
  createThread(net, netMain, Net(g: g, ms: 1_500))
  let io = newSyntheticAudioIo(sine(1000.0, 70 * Second), vc.clock, g)
  let a = newVoiceRecorder(io, vc.clock)
  let t = getMonoTime()
  let r = a.recordStart(aliceS).ck
  doAssert r.ok and msSince(t) < 100,
           "voice_record_start answers at once while the device start is held: " & $msSince(t) & " ms, " & $r
  doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000), "the device starts on a thread of its own"
  var st = a.status()
  doAssert st["recording"]["state"].getStr() == "starting" and st["recording"]["elapsedMs"].getInt() == 0, $st
  doAssert st["ready"]["capture"].getStr() == "unknown", "not known until the start lands: " & $st
  # the module answers meanwhile: coordinate_messages' rows and voice_status, each at once
  let t2 = getMonoTime()
  doAssert a.messagesJson(aliceS, proc (who: string): string = "").len > 0
  doAssert a.state == "starting"
  doAssert msSince(t2) < 100, "the module answered other calls in " & $msSince(t2) & " ms"
  doAssert a.recordStart(aliceS).ck.err == "busy" and a.play(aliceS, nid1).ck.err == "busy"
  vc.advance(5_000)                   # time passes while it starts: none of it is recorded
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "starting" and st["recording"]["elapsedMs"].getInt() == 0, $st
  g.releaseStart()
  doAssert waitUntil(proc (): bool = a.state == "recording", 1_000), "the recording starts with the device"
  st = a.status()
  doAssert st["ready"]["capture"].getStr() == "ok" and st["recording"]["elapsedMs"].getInt() == 0, $st
  # the elapsed time and the 60 s cap count from the device start, not from the call
  vc.advance(59_000)
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "recording" and st["recording"]["elapsedMs"].getInt() == 59_000 and
           not st["recording"]["capped"].getBool(), $st
  vc.advance(1_000)
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "draft" and st["recording"]["capped"].getBool() and
           st["recording"]["elapsedMs"].getInt() == 60_000, $st
  doAssert a.draftDiscard() == "ok"
  joinThread(net)
  doAssert waitStarts(1_000) and liveAudioBuffers() == base, "every buffer freed: " & $(liveAudioBuffers() - base)
  freeStartGate(g)
  echo "29. voice_record_start answers at once while the device start is held: starting, the module ",
       "answering meanwhile; released, recording, timed and capped from the device start OK"

# ── 29b. Stop, Discard and close while the start is held; a start that fails; one too slow ─
block:
  for how in ["stop", "discard", "close", "fail", "slow"]:
    let base = liveAudioBuffers()
    let vc = VirtualClock()
    let g = newStartGate()
    var net: Thread[Net]
    createThread(net, netMain, Net(g: g, ms: 1_500))
    let io = newSyntheticAudioIo(sine(1000.0, Second), vc.clock, g)
    let a = newVoiceRecorder(io, vc.clock)
    doAssert a.recordStart(aliceS).ck.ok
    doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000), how
    doAssert liveAudioBuffers() == base + 1, how
    let t = getMonoTime()
    case how
    of "stop": doAssert a.recordStop().ck.err == "not-started", "Stop before the device started records nothing"
    of "discard": doAssert a.draftDiscard() == "ok"
    of "close": doAssert a.close() == "ok"
    of "fail":
      g.releaseStart("no-device")
      doAssert waitStarts(1_000)
    of "slow":
      vc.advance(StartBoundMs - 1)
      doAssert a.state == "starting", "still within the bound"
      vc.advance(1)
    doAssert msSince(t) < (if how == "fail": 1_100 else: 100), how & " answers at once while the start is held"
    let st = a.status()
    let want = (case how
                of "fail": "no-device"
                of "slow": "device-start-slow"
                else: "")
    doAssert st["recording"]["state"].getStr() == "idle" and st["recording"]["error"].getStr() == want, how & ": " & $st
    if want.len > 0:
      doAssert st["ready"]["capture"].getStr() == want, how & ": ready.capture says it: " & $st
    doAssert io.stream == asIdle and not io.starting, how
    doAssert a.recordStop().ck.err == "not-recording", how
    if how == "fail":
      doAssert liveAudioBuffers() == base, "a failed start's buffer is freed at once"
    else:
      # let go, never waited on: the start thread holds the buffer until its start returns
      doAssert startsInFlight() == 1 and liveAudioBuffers() == base + 1, how & ": the start thread holds it"
      doAssert not waitStarts(30), how
      g.releaseStart()
      doAssert waitStarts(1_000), how & ": the start returned"
      doAssert liveAudioBuffers() == base, how & ": its thread freed the buffer"
      doAssert g.startsStopped == 1, how & ": its thread stopped the device it started"
      doAssert a.state == "idle", how & ": a start let go never becomes a recording"
    joinThread(net)
    freeStartGate(g)
  echo "29b. Stop (not-started), Discard and close while the start is held answer at once, idle, the start ",
       "thread freeing the buffer once it returns; a start that fails: idle, error and ready.capture ",
       "no-device; one past ", StartBoundMs, " ms: device-start-slow, let go OK"

# ── 29c. Discard and close after the start returned, before any read saw it ──────────
# The device's start returned (it runs, or it failed) but no pump has seen it, so the
# recorder is still `starting`: Discard and close drop a starting recording without pumping
# first. The io finds no start to let go and finishes it on the module thread: idle at once,
# the buffer freed at once (no start thread holds it any more), a running device closed.
# On SyntheticAudioIo with a gate, and on miniaudio's null device, whose start thread leaves
# a running device behind.
block:
  for dev in ["synthetic", "synthetic-failed", "null"]:
    for how in ["discard", "close"]:
      let what = dev & " " & how
      let base = liveAudioBuffers()
      let vc = VirtualClock()
      let g = (if dev == "null": StartGate(nil) else: newStartGate())
      var net: Thread[Net]
      if g != nil: createThread(net, netMain, Net(g: g, ms: 1_500))
      let io: AudioIo = (if dev == "null": AudioIo(newMiniaudioIo(abNull))
                         else: AudioIo(newSyntheticAudioIo(sine(1000.0, Second), vc.clock, g)))
      let a = newVoiceRecorder(io, vc.clock)
      doAssert a.recordStart(aliceS).ck.ok, what
      doAssert io.starting, what & ": the device starts on a thread of its own"
      if g != nil:
        doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000), what
        g.releaseStart(if dev == "synthetic-failed": "no-device" else: "")
      doAssert waitStarts(2_000), what & ": the start returned"
      doAssert io.starting, what & ": no read has seen it, so the recorder still says starting"
      let t = getMonoTime()
      case how
      of "discard": doAssert a.draftDiscard() == "ok"
      else: doAssert a.close() == "ok"
      doAssert msSince(t) < 100, what & " answers at once"
      doAssert io.stream == asIdle and not io.starting, what & ": the io is idle"
      if dev == "null":
        doAssert MiniaudioIo(io).backendName == "", what & ": the device and its context released"
      doAssert liveAudioBuffers() == base, what & ": the buffer freed at once: " & $(liveAudioBuffers() - base) & " left"
      let st = a.status()
      doAssert st["recording"]["state"].getStr() == "idle" and st["recording"]["error"].getStr() == "", what & ": " & $st
      doAssert a.recordStop().ck.err == "not-recording", what
      if g != nil:
        doAssert g.startsStopped == 0, what & ": nothing left for a start thread to stop"
        joinThread(net)
        freeStartGate(g)
  echo "29c. Discard and close after the device's start returned, before any read saw it: idle at once, ",
       "the module thread finishing the start, the buffer freed at once, the null device's closed OK"

# ── 29d. while a device starts, ready says nothing of it yet: unknown, never the last word ─
# A start that was too slow leaves its word in ready.capture (ready.playback for Play). The
# next start on its way knows nothing of its own device yet, so while it is `starting` ready
# says unknown, until the pump sees the device run (ok) or fail (its word). The gate stays
# held throughout, so each start stays pending as long as the test needs (a released gate
# would let the next start fail or run before the status read).
block:
  let base = liveAudioBuffers()
  let vc = VirtualClock()
  let g = newStartGate()
  var net: Thread[Net]
  createThread(net, netMain, Net(g: g, ms: 1_500))
  let io = newSyntheticAudioIo(sine(1000.0, Second), vc.clock, g)
  let a = newVoiceRecorder(io, vc.clock)
  doAssert a.recordStart(aliceS).ck.ok
  vc.advance(StartBoundMs)
  var st = a.status()
  doAssert st["recording"]["state"].getStr() == "idle" and st["ready"]["capture"].getStr() == "device-start-slow", $st
  doAssert a.recordStart(aliceS).ck.ok
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "starting" and st["ready"]["capture"].getStr() == "unknown",
           "a capture start on its way says unknown, not the last start's word: " & $st
  doAssert a.draftDiscard() == "ok"
  doAssert a.play(aliceS, nid1).ck.ok
  vc.advance(StartBoundMs)
  st = a.status()
  doAssert st["playing"].kind == JNull and st["ready"]["playback"].getStr() == "device-start-slow", $st
  doAssert a.play(aliceS, nid1).ck.ok
  st = a.status()
  doAssert st["playing"]{"starting"}.getBool() and st["ready"]["playback"].getStr() == "unknown",
           "a playback start on its way says unknown, not the last start's word: " & $st
  doAssert a.playStop() == "ok"
  doAssert startsInFlight() == 4, "four starts let go, each still held: " & $startsInFlight()
  g.releaseStart()
  doAssert waitStarts(1_000) and g.startsStopped == 4 and liveAudioBuffers() == base
  joinThread(net)
  freeStartGate(g)
  echo "29d. while a start is on its way, ready.capture and ready.playback say unknown, not the word ",
       "the last start left (device-start-slow) OK"

# ── 30. voice_play answers at once; the note plays when the device starts ────────────
block:
  for how in ["play", "stop", "fail", "slow"]:
    let base = liveAudioBuffers()
    let vc = VirtualClock()
    let g = newStartGate()
    var net: Thread[Net]
    createThread(net, netMain, Net(g: g, ms: 1_500))
    let io = newSyntheticAudioIo(@[], vc.clock, g)
    let b = newVoiceRecorder(io, vc.clock)
    let t = getMonoTime()
    let r = b.play(bobS, nid1).ck
    doAssert r.ok and msSince(t) < 100, how & ": voice_play answers at once: " & $msSince(t) & " ms, " & $r
    doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000), how
    var st = b.status()
    doAssert st["playing"] == %*{"note": nid1, "positionMs": 0, "durationMs": 3_000, "starting": true}, how & ": " & $st
    doAssert b.play(bobS, nid1).ck.err == "busy" and b.recordStart(bobS).ck.err == "busy", how
    vc.advance(2_000)
    doAssert b.status()["playing"]["positionMs"].getInt() == 0, how & ": nothing plays while it starts"
    case how
    of "play":
      g.releaseStart()
      doAssert waitUntil(proc (): bool = not b.status()["playing"]{"starting"}.getBool(true), 1_000)
      st = b.status()
      doAssert st["playing"] == %*{"note": nid1, "positionMs": 0, "durationMs": 3_000, "starting": false}, $st
      doAssert st["ready"]["playback"].getStr() == "ok", $st
      vc.advance(1_500)
      doAssert b.status()["playing"]["positionMs"].getInt() == 1_500
      vc.advance(1_600)
      doAssert b.status()["playing"].kind == JNull, "done: idle again, the pump's done detection as before"
      let (_, pcm, _) = decodeClip(voiceRecordOf(bobS.roomEvents(), nid1).record)
      doAssert io.played == pcm, "the sink holds exactly the clip's samples"
    of "stop":
      doAssert b.playStop() == "ok" and msSince(t) < 200
      doAssert b.status()["playing"].kind == JNull and io.stream == asIdle
      doAssert startsInFlight() == 1 and liveAudioBuffers() == base + 1
      g.releaseStart()
      doAssert waitStarts(1_000) and g.startsStopped == 1
    of "fail":
      g.releaseStart("no-device")
      doAssert waitStarts(1_000)
      st = b.status()
      doAssert st["playing"].kind == JNull and st["ready"]["playback"].getStr() == "no-device", $st
    else:
      vc.advance(StartBoundMs)
      st = b.status()
      doAssert st["playing"].kind == JNull and st["ready"]["playback"].getStr() == "device-start-slow", $st
      g.releaseStart()
      doAssert waitStarts(1_000) and g.startsStopped == 1
    doAssert io.stream == asIdle and not io.starting, how
    doAssert liveAudioBuffers() == base, how & ": every buffer freed"
    joinThread(net)
    freeStartGate(g)
  echo "30. voice_play answers at once while the device start is held: playing, starting; released, ",
       "it plays to done as before; Stop lets it go, a failure says no-device, past the bound ",
       "device-start-slow OK"

# ── 31. close at unload: never waits on a start that never returns ───────────────────
# The hosted exit proc closes the recorder, then waits a bounded while for start threads
# (waitStarts): a start that never returns costs that wait, never a hang.
block:
  let base = liveAudioBuffers()
  let vc = VirtualClock()
  let g = newStartGate()
  var net: Thread[Net]
  createThread(net, netMain, Net(g: g, ms: 1_500))
  let a = newVoiceRecorder(newSyntheticAudioIo(@[], vc.clock, g), vc.clock)
  doAssert a.recordStart(aliceS).ck.ok
  doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000)
  let t = getMonoTime()
  doAssert a.close() == "ok" and msSince(t) < 100
  doAssert not waitStarts(200) and msSince(t) in 190 .. 600, "the bounded wait ends: " & $msSince(t) & " ms"
  g.releaseStart()
  doAssert waitStarts(1_000) and liveAudioBuffers() == base
  joinThread(net)
  freeStartGate(g)
  echo "31. close while a start is held returns at once, and the bounded wait for start threads ends OK"

# ── 8. no JSON carries audio or a float ─────────────────────────────────────────────
block:
  proc walk(j: JsonNode, path: string) =
    case j.kind
    of JFloat: doAssert false, path & " is a float: " & $j
    of JObject:
      for k, v in j:
        doAssert k != "part", path & " carries a part"
        walk(v, path & "." & k)
    of JArray:
      for i, v in j.elems: walk(v, path & "[" & $i & "]")
    of JString:
      var run = 0
      for c in j.getStr():
        run = (if c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '+', '/', '='}: run + 1 else: 0)
        doAssert run <= 64, path & ": a base64 run over 64 characters"
    else: discard
  var states: CountTable[string]
  for j in seen:
    walk(j, "$")
    doAssert ($j).len < 1024, "bounded: " & $($j).len & " B"
    if j{"recording"} != nil:
      states.inc j["recording"]["state"].getStr()
      if j["playing"].kind != JNull: states.inc "playing"
  for s in ["idle", "starting", "recording", "draft", "playing"]:
    doAssert states[s] > 0, "no status was read in state " & s
  echo "8. ", seen.len, " JSON replies, every state: no part, no base64 run over 64, no float, under 1 KB OK"

echo "voice_live_test: all OK"
