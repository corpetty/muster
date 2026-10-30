## The audio seam (docs/design/voice-notes.md §9) on its two in-process implementations, with
## no device: SyntheticAudioIo (deterministic PCM on a virtual clock, a collecting sink) and
## FileAudioIo (a 48 kHz mono s16 WAV source, a raw PCM sink). Both move samples through
## `captureInto` / `playFrom`, the procs the miniaudio device callback runs, so the cap,
## `capped`, the peak and `done` are held here on a clock the test owns, and (§7–§9) a start
## held on its start thread by a StartGate: stopped after the pump saw it run (§7), let go
## before it returned (§8), stopped after it returned but before any pump saw it (§8b),
## failed, the in-flight cap (§9). The real device thread runs in audio_io_null_test. Pure
## Nim: no libopus, no miniaudio.

import std/[monotimes, os, strutils]
import ../src/audio/[audio_io, voice_clip]

proc ramp(n: int): seq[int16] =
  ## Deterministic and never constant: a sawtooth through both signs.
  result = newSeq[int16](n)
  for i in 0 ..< n: result[i] = int16((i * 37) mod 2001 - 1000)

proc le16(v: int): string = char(v and 0xFF) & char((v shr 8) and 0xFF)
proc le32(v: int): string = le16(v and 0xFFFF) & le16((v shr 16) and 0xFFFF)

proc pcmBytes(pcm: openArray[int16]): string =
  ## Little-endian s16, two bytes a sample: what a raw PCM sink must hold.
  for s in pcm: result.add le16(int(cast[uint16](s)))

proc wav(pcm: openArray[int16], rate = ClipRate, channels = 1, bits = 16, format = 1,
         extra = ""): string =
  ## A RIFF/WAVE file: "fmt " (16 bytes), then `extra` (whole chunks), then "data".
  let data = pcmBytes(pcm)
  let fmt = "fmt " & le32(16) & le16(format) & le16(channels) & le32(rate) &
            le32(rate * channels * bits div 8) & le16(channels * bits div 8) & le16(bits)
  let body = "WAVE" & fmt & extra & "data" & le32(data.len) & data
  "RIFF" & le32(body.len) & body

let dir = getTempDir() / ("muster_audio_io_test_" & $getCurrentProcessId())
createDir(dir)

# 1. A capture fills exactly to the cap and sets `capped`. The source runs on the virtual
#    clock, 48 frames a millisecond; the write index only grows, never past the cap, and
#    `capped` is set exactly when the buffer is full. Frames past the cap are dropped (the
#    source runs on), so a 60 s buffer cannot overflow however late the module thread drains
#    it (§9). The drained samples are the source's first `cap`, in order.
block:
  let vc = VirtualClock()
  let src = ramp(10_000)
  let io = newSyntheticAudioIo(src, vc.clock)
  let buf = newAudioBuffer(4_800)                       # 100 ms
  doAssert io.startCapture(buf) == ""
  doAssert io.stream == asCapture
  doAssert io.startCapture(buf) == "busy"
  doAssert io.startPlayback(buf) == "busy"
  var t, last = 0
  var drained: seq[int16]
  for step in [0, 1, 7, 13, 29, 3, 41, 2, 4, 50, 1_000]:
    vc.advance(step)
    t += step
    doAssert io.pump() == ""
    let w = buf.written
    doAssert w >= last, "the write index went back: " & $last & " then " & $w
    doAssert w == min(t * ClipRate div 1000, buf.cap), $t & " ms: " & $w
    doAssert buf.capped == (w == buf.cap), $w
    last = w
    drained.add buf.takeCaptured()
  doAssert buf.written == 4_800 and buf.capped
  doAssert drained == src[0 ..< 4_800]
  vc.advance(500)
  doAssert io.pump() == ""
  doAssert buf.written == 4_800 and buf.takeCaptured().len == 0
  doAssert io.stopCapture() == "" and io.stopCapture() == ""
  doAssert io.stream == asIdle
  # one jump far past the cap writes exactly the cap, from a reset buffer
  doAssert io.startCapture(buf) == ""
  doAssert buf.written == 0 and not buf.capped
  vc.advance(60_000)
  doAssert io.pump() == ""
  doAssert buf.written == 4_800 and buf.capped
  doAssert buf.takeCaptured() == src[0 ..< 4_800]
  doAssert io.close() == "" and io.close() == ""
  freeAudioBuffer(buf)
echo "1. capture: paced 48 frames/ms, write index monotone, exactly the cap, capped; busy OK"

# 2. The peak: the largest |sample| written since the last read, reset by reading it. The most
#    negative s16 reads 32768, not a wrapped value. Silence past the source's end reads 0.
block:
  var src = newSeq[int16](1_440)
  for i in 0 ..< 480: src[i] = (if i mod 2 == 0: 1_000'i16 else: -999'i16)
  for i in 480 ..< 960: src[i] = (if i == 700: low(int16) else: 5'i16)
  for i in 960 ..< 1_440: src[i] = 300
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(src, vc.clock)
  let buf = newAudioBuffer(ClipRate)
  doAssert io.startCapture(buf) == ""
  doAssert buf.takePeak() == 0
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.takePeak() == 1_000
  doAssert buf.takePeak() == 0, "read once, the peak resets"
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.takePeak() == 32_768
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.takePeak() == 300
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.written == 1_920 and buf.takePeak() == 0
  doAssert io.stopCapture() == ""
  freeAudioBuffer(buf)
echo "2. peak: 1000, reset to 0 on read, 32768 for int16.low, 300, 0 for silence OK"

# 3. Playback consumes the whole buffer at the clock's pace, then reports `done`. The
#    collecting sink holds exactly what was loaded. `playFrom`, the callback's half, writes
#    zeros past the end of what was loaded and sets `done` once it has written the buffer's
#    `tail` of them: what an implementation counts as still queued between the callback and
#    the speaker, so a stop on `done` drops only silence. The in-process sinks queue nothing
#    (tail 0: done with the last sample); MiniaudioIo sets the device's (audio_io_null_test §3).
block:
  let pcm = ramp(2_000)
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(@[], vc.clock)
  let buf = newAudioBuffer(4_800)
  doAssert buf.loadPlayback(pcm) == 2_000
  doAssert io.startPlayback(buf) == ""
  doAssert io.stream == asPlayback
  doAssert io.startPlayback(buf) == "busy"
  doAssert io.startCapture(buf) == "busy"
  var t = 0
  for step in [10, 10, 5, 3]:
    vc.advance(step)
    t += step
    doAssert io.pump() == ""
    doAssert buf.readIndex == t * ClipRate div 1000 and not buf.done, $buf.readIndex
  vc.advance(100)
  doAssert io.pump() == ""
  doAssert buf.done and buf.readIndex == 2_000
  doAssert buf.tail == 0, "the collecting sink queues nothing"
  doAssert io.played == pcm
  vc.advance(100)
  doAssert io.pump() == "" and io.played == pcm
  doAssert io.stopPlayback() == "" and io.stopPlayback() == ""
  doAssert io.stream == asIdle
  doAssert buf.loadPlayback(ramp(6_000)) == 4_800, "a load longer than the buffer stops at its cap"
  # the device-thread half on its own
  doAssert buf.loadPlayback(pcm) == 2_000
  var output = newSeq[int16](3_000)
  for x in output.mitems: x = 7
  doAssert buf.playFrom(cast[ptr UncheckedArray[int16]](addr output[0]), 1_500) == 1_500
  doAssert not buf.done and output[0 ..< 1_500] == pcm[0 ..< 1_500]
  doAssert buf.playFrom(cast[ptr UncheckedArray[int16]](addr output[1_500]), 1_500) == 500
  doAssert buf.done and buf.readIndex == 2_000
  doAssert output[1_500 ..< 2_000] == pcm[1_500 ..< 2_000]
  for i in 2_000 ..< 3_000: doAssert output[i] == 0, "past the end: silence, at " & $i
  # with a tail of 1,200: the callback that hands over the last 500 samples writes 1,000
  # zeros after them and is not done; the next, all silence, reaches the tail and is
  doAssert buf.loadPlayback(pcm) == 2_000
  buf.beginPlayback(tail = 1_200)
  doAssert buf.tail == 1_200 and buf.silenceAfter == 0 and not buf.done
  for x in output.mitems: x = 7
  doAssert buf.playFrom(cast[ptr UncheckedArray[int16]](addr output[0]), 1_500) == 1_500
  doAssert not buf.done and buf.silenceAfter == 0
  doAssert buf.playFrom(cast[ptr UncheckedArray[int16]](addr output[1_500]), 1_500) == 500
  doAssert buf.readIndex == 2_000 and buf.silenceAfter == 1_000
  doAssert not buf.done, "done with the last samples still queued"
  var more = newSeq[int16](480)
  for x in more.mitems: x = 7
  doAssert buf.playFrom(cast[ptr UncheckedArray[int16]](addr more[0]), 480) == 0
  doAssert buf.done and buf.silenceAfter == 1_480 and buf.readIndex == 2_000
  for x in more: doAssert x == 0
  doAssert output[0 ..< 2_000] == pcm
  buf.beginPlayback()
  doAssert buf.tail == 0 and buf.silenceAfter == 0 and not buf.done
  freeAudioBuffer(buf)
echo "3. playback: paced, the whole buffer then done; the sink holds it exactly; zeros past the end OK"

# 4. A WAV source is paced by the given clock, then silent past its end, as a microphone
#    in a quiet room. Anything but 48 kHz mono s16 PCM is refused as `wav-format`, a file cut
#    short as `wav-truncated`, a missing one as `no-source`; a refused start opens nothing.
block:
  let pcm = ramp(9_600)                                 # 200 ms
  writeFile(dir / "ok.wav", wav(pcm, extra = "LIST" & le32(4) & "INFO"))
  let vc = VirtualClock()
  let io = newFileAudioIo(dir / "ok.wav", "", vc.clock)
  let buf = newAudioBuffer(ClipRate)
  doAssert io.startCapture(buf) == ""
  doAssert io.pump() == "" and buf.written == 0, "nothing before the clock moves"
  vc.advance(50)
  doAssert io.pump() == "" and buf.written == 2_400
  vc.advance(150)
  doAssert io.pump() == "" and buf.written == 9_600
  vc.advance(100)
  doAssert io.pump() == "" and buf.written == 14_400
  let got = buf.takeCaptured()
  doAssert got[0 ..< 9_600] == pcm
  for i in 9_600 ..< 14_400: doAssert got[i] == 0, "past the file's end: silence, at " & $i
  doAssert io.stopCapture() == ""
  let whole = wav(pcm)
  for (name, bytes, want) in [
      ("44k1", wav(pcm, rate = 44_100), "wav-format"),
      ("stereo", wav(pcm, channels = 2), "wav-format"),
      ("u8", wav(pcm, bits = 8), "wav-format"),
      ("float", wav(pcm, format = 3), "wav-format"),
      ("rifx", "RIFX" & whole[4 .. ^1], "wav-format"),
      ("odd-data", whole[0 ..< 40] & le32(19_199) & whole[44 .. ^2], "wav-format"),
      ("riff-only", whole[0 ..< 11], "wav-truncated"),
      ("fmt-cut", whole[0 ..< 30], "wav-truncated"),
      ("no-data", whole[0 ..< 36], "wav-truncated"),
      ("data-cut", whole[0 ..< 44 + 101], "wav-truncated")]:
    writeFile(dir / name & ".wav", bytes)
    let bad = newFileAudioIo(dir / name & ".wav", "", vc.clock)
    let why = bad.startCapture(buf)
    doAssert why == want, name & ": " & why
    doAssert bad.stream == asIdle, name
  doAssert newFileAudioIo(dir / "missing.wav", "", vc.clock).startCapture(buf) == "no-source"
  doAssert newFileAudioIo("", "", vc.clock).startCapture(buf) == "no-source"
  freeAudioBuffer(buf)
echo "4. WAV source: paced by the clock, silent past its end; wav-format, wav-truncated, no-source OK"

# 5. The PCM sink writes exactly the PCM played: two bytes a sample, little-endian, nothing
#    before or after, whatever the file held. Without a sink path, or with one that cannot be
#    opened, playback is refused as `no-sink`.
block:
  var pcm = ramp(7_000)
  pcm.add [low(int16), high(int16), -1'i16, 0'i16, 1'i16]
  let sink = dir / "sink.pcm"
  writeFile(sink, "stale bytes from an earlier playback")
  let vc = VirtualClock()
  let io = newFileAudioIo("", sink, vc.clock)
  let buf = newAudioBuffer(pcm.len)
  doAssert buf.loadPlayback(pcm) == pcm.len
  doAssert io.startPlayback(buf) == ""
  var guard = 0
  while not buf.done:
    vc.advance(7)
    doAssert io.pump() == ""
    inc guard
    doAssert guard < 1_000, "playback never finished"
  vc.advance(100)
  doAssert io.pump() == ""
  doAssert io.stopPlayback() == "" and io.stopPlayback() == ""
  doAssert readFile(sink) == pcmBytes(pcm)
  doAssert newFileAudioIo("", "", vc.clock).startPlayback(buf) == "no-sink"
  doAssert newFileAudioIo("", dir / "no" / "such" / "dir.pcm", vc.clock).startPlayback(buf) == "no-sink"
  freeAudioBuffer(buf)
echo "5. PCM sink: exactly the samples played, little-endian; no-sink OK"

# 6. A nil buffer is refused as `no-buffer` by every start, before anything opens: on a device
#    thread the nil would be dereferenced with checks off (a SIGSEGV in logos_host), so the
#    module thread refuses it, as MiniaudioIo does (audio_io_null_test §4).
block:
  let vc = VirtualClock()
  writeFile(dir / "six.wav", wav(ramp(480)))
  let sink = dir / "six.pcm"
  let syn = newSyntheticAudioIo(ramp(480), vc.clock)
  let file = newFileAudioIo(dir / "six.wav", sink, vc.clock)
  for io in [AudioIo(syn), AudioIo(file)]:
    doAssert io.startCapture(nil) == "no-buffer"
    doAssert io.stream == asIdle and io.buffer == nil
    doAssert io.startPlayback(nil) == "no-buffer"
    doAssert io.stream == asIdle and io.buffer == nil
    vc.advance(10)
    doAssert io.pump() == ""
    doAssert io.close() == ""
  doAssert not fileExists(sink), "a refused playback opened its sink"
echo "6. a nil buffer: no-buffer from every start, nothing opened OK"

# ── A device start that does not return (PR 340's review, voice-notes.md §9, §15) ─────────
# On a Mac, Core Audio held a capture start while a microphone prompt stood unanswered (S11:
# still not returned after 20 s). A start held by a StartGate stands in for it: the start's
# blocking half waits on the gate until the test releases it. The seam's answer is a start
# that runs on a thread of its own: startCapture / startPlayback return at once with the
# stream `starting`, and the pump says when it lands or fails. A safety net releases each
# gate after 1.5 s, so a start that blocks its caller (the seam before the start thread)
# returns late and fails on the time instead of hanging the test.

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

# 7. A held capture start: the call returns at once, `starting`; a second start is busy; the
#    pump moves nothing while it is held, so time that passes then is not captured. Released,
#    the next pumps see it run, and the clock counts from there.
block:
  let base = liveAudioBuffers()
  let vc = VirtualClock(ms: 1_000)
  let g = newStartGate()
  var net: Thread[Net]
  createThread(net, netMain, Net(g: g, ms: 1_500))
  let io = newSyntheticAudioIo(ramp(10_000), vc.clock, g)
  let buf = newAudioBuffer(4_800)
  let t = getMonoTime()
  doAssert io.startCapture(buf) == ""
  doAssert msSince(t) < 100, "the start returns at once while the device start is held: " & $msSince(t) & " ms"
  doAssert io.starting and io.stream == asCapture
  doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000), "the start's blocking half runs on a thread of its own"
  doAssert startsInFlight() == 1
  doAssert io.startCapture(buf) == "busy" and io.startPlayback(buf) == "busy"
  vc.advance(50)
  doAssert io.pump() == "" and io.starting and buf.written == 0, "nothing moves while the start is held"
  g.releaseStart()
  doAssert waitUntil(proc (): bool = (discard io.pump(); not io.starting), 1_000), "the pump sees it run"
  doAssert io.stream == asCapture and buf.written == 0
  vc.advance(10)
  doAssert io.pump() == "" and buf.written == 480, "the clock counts from the device start: " & $buf.written
  doAssert buf.takeCaptured() == ramp(480)
  doAssert io.stopCapture() == "" and io.stream == asIdle
  joinThread(net)
  doAssert waitUntil(proc (): bool = startsInFlight() == 0, 1_000)
  freeAudioBuffer(buf)
  doAssert liveAudioBuffers() == base, "every buffer freed: " & $(liveAudioBuffers() - base)
  doAssert g.startsStopped == 0, "a start the io adopted is stopped by the io, not its thread"
  freeStartGate(g)
echo "7. a held start: it returns at once, starting, busy to a second; released, it runs, timed from there OK"

# 8. Stop, close, or a failure while the start is held. Stop and close return at once and let
#    the start go: the io is idle at once, while the start thread holds the buffer (its own
#    reference) until its start returns, then stops what it started and frees it. A start
#    that fails is reported by the pump with the device's word, once, and the io is idle.
block:
  for how in ["stop-capture", "stop-playback", "close", "fail"]:
    let base = liveAudioBuffers()
    let vc = VirtualClock()
    let g = newStartGate()
    var net: Thread[Net]
    createThread(net, netMain, Net(g: g, ms: 1_500))
    let io = newSyntheticAudioIo(ramp(4_800), vc.clock, g)
    let buf = newAudioBuffer(4_800)
    let play = how == "stop-playback"
    if play: doAssert buf.loadPlayback(ramp(4_800)) == 4_800
    let t = getMonoTime()
    doAssert (if play: io.startPlayback(buf) else: io.startCapture(buf)) == ""
    doAssert msSince(t) < 100, how & ": the start returns at once"
    doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000), how
    doAssert liveAudioBuffers() == base + 1
    if how == "fail":
      g.releaseStart("no-device")
      var why = ""
      doAssert waitUntil(proc (): bool = (why = io.pump(); why.len > 0), 1_000), "the pump reports the failure"
      doAssert why == "no-device" and io.stream == asIdle and not io.starting, why
      doAssert io.pump() == "", "a failure is reported once"
      freeAudioBuffer(buf)
      doAssert waitUntil(proc (): bool = startsInFlight() == 0, 1_000)
      doAssert liveAudioBuffers() == base, how & ": freed"
    else:
      let t2 = getMonoTime()
      case how
      of "stop-capture": doAssert io.stopCapture() == ""
      of "stop-playback": doAssert io.stopPlayback() == ""
      else: doAssert io.close() == ""
      doAssert msSince(t2) < 100, how & " returns at once while the start is held"
      doAssert io.stream == asIdle and not io.starting and io.buffer == nil, how
      vc.advance(100)
      doAssert io.pump() == "", how & ": a start let go reports nothing"
      freeAudioBuffer(buf)                # the caller's reference: the start thread holds its own
      doAssert liveAudioBuffers() == base + 1 and startsInFlight() == 1, how & ": the start thread holds it"
      doAssert not waitStarts(30), how & ": its start has not returned"
      g.releaseStart()
      doAssert waitStarts(1_000), how & ": the start returned"
      doAssert liveAudioBuffers() == base, how & ": its thread freed the buffer"
      doAssert g.startsStopped == 1, how & ": its thread stopped what it started"
    joinThread(net)
    freeStartGate(g)
echo "8. stop, close or a failure while held: idle at once; the start thread frees the buffer and stops ",
     "what it started once its start returns; a failure reported once OK"

# 8b. The third order: the start returned, run or failed, before any pump saw it, then a stop
#     or a close. Its start thread swapped pending to running (or failed) and is gone, and the
#     io still says `starting`, since only the pump settles a start. A stop or a close then
#     finds nothing to let go (letGo is false), so the module thread finishes the job itself:
#     the io is idle at once, the job's reference to the buffer is let go (the caller's free is
#     then the last one), nothing is reported later, and the start thread stopped nothing.
#     §7 is a stop after the pump saw the start run; §8, one before the start returned.
block:
  for fail in ["", "no-device"]:
    for how in ["stop-capture", "stop-playback", "close-capture", "close-playback"]:
      let what = how & (if fail.len > 0: " after a failed start" else: "")
      let base = liveAudioBuffers()
      let vc = VirtualClock()
      let g = newStartGate()
      var net: Thread[Net]
      createThread(net, netMain, Net(g: g, ms: 1_500))
      let io = newSyntheticAudioIo(ramp(4_800), vc.clock, g)
      let buf = newAudioBuffer(4_800)
      let play = how.endsWith("playback")
      if play: doAssert buf.loadPlayback(ramp(4_800)) == 4_800
      doAssert (if play: io.startPlayback(buf) else: io.startCapture(buf)) == ""
      doAssert waitUntil(proc (): bool = g.startsReached == 1, 1_000), what
      g.releaseStart(fail)
      doAssert waitStarts(1_000), what & ": the start returned"
      doAssert io.starting and io.stream == (if play: asPlayback else: asCapture),
               what & ": no pump has seen it, so the io still says starting"
      doAssert liveAudioBuffers() == base + 1, what
      let t = getMonoTime()
      case how
      of "stop-capture": doAssert io.stopCapture() == ""
      of "stop-playback": doAssert io.stopPlayback() == ""
      else: doAssert io.close() == ""
      doAssert msSince(t) < 100, what & " returns at once"
      doAssert io.stream == asIdle and not io.starting and io.buffer == nil, what & ": idle"
      vc.advance(100)
      doAssert io.pump() == "", what & ": a start the stop finished reports nothing later"
      doAssert buf.written == (if play: 4_800 else: 0), what & ": nothing captured"
      freeAudioBuffer(buf)
      doAssert liveAudioBuffers() == base, what & ": the module thread finished the start: buffers left " &
               $(liveAudioBuffers() - base)
      doAssert g.startsStopped == 0, what & ": a start that returned is not stopped by its thread"
      joinThread(net)
      freeStartGate(g)
echo "8b. a start that returned, run or failed, before any pump, then a stop or a close: idle at once, ",
     "the module thread finishes it, every buffer freed, nothing reported later OK"

# 9. No more than MaxStartsInFlight starts wait at once: past it a start is refused,
#    `device-start-slow`, so a caller cannot pile up threads behind a start that never returns.
block:
  let base = liveAudioBuffers()
  let vc = VirtualClock()
  let g = newStartGate()
  var net: Thread[Net]
  createThread(net, netMain, Net(g: g, ms: 1_500))
  var bufs: seq[AudioBuffer]
  for i in 0 ..< MaxStartsInFlight:
    let io = newSyntheticAudioIo(@[], vc.clock, g)
    bufs.add newAudioBuffer(480)
    doAssert io.startCapture(bufs[^1]) == ""
    doAssert io.stopCapture() == ""     # let go: its thread still waits on the gate
  doAssert startsInFlight() == MaxStartsInFlight
  let more = newSyntheticAudioIo(@[], vc.clock, g)
  bufs.add newAudioBuffer(480)
  doAssert more.startCapture(bufs[^1]) == "device-start-slow" and more.stream == asIdle
  for b in bufs: freeAudioBuffer(b)
  g.releaseStart()
  doAssert waitStarts(1_000) and liveAudioBuffers() == base
  let again = newAudioBuffer(480)       # once they have returned, a start is taken again
  doAssert more.startCapture(again) == ""
  doAssert waitUntil(proc (): bool = (discard more.pump(); not more.starting), 1_000)
  doAssert more.stream == asCapture and more.stopCapture() == ""
  freeAudioBuffer(again)
  doAssert waitStarts(1_000) and liveAudioBuffers() == base
  joinThread(net)
  freeStartGate(g)
echo "9. at most ", MaxStartsInFlight, " starts wait at once; past them device-start-slow OK"

removeDir(dir)
