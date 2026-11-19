## Voice notes on a REAL audio device (docs/design/voice-notes.md §9, §17 S11): MiniaudioIo on
## the platform's own backends (abSystem: Core Audio on macOS; PulseAudio, then ALSA, on Linux),
## through the same AudioIo seam the module records and plays with. No mock and no null device.
##
## It is in run-suite's E2E list and gated, so it never runs by default: with MUSTER_VOICE_REAL
## unset (or 0) it prints a SKIP line and exits 0.
##
##   MUSTER_VOICE_REAL=1 module/tests/run-suite.sh e2e voice_device_e2e     # both legs
##   MUSTER_VOICE_REAL=mic …       the microphone leg only: only with the person's consent
##   MUSTER_VOICE_REAL=speaker …   the speaker leg only
##   MUSTER_VOICE_REAL_AUDIBLE=1   the speaker leg plays a 0.5 s 440 Hz tone at about -30 dBFS;
##                                 without it, it plays digital silence (zeros): nothing to hear
##
## The microphone leg captures 2 s: the stream must read back as 48 kHz mono s16, frames must
## arrive at 48 a millisecond (±5%), the write index must only grow, and the 2 s cap must stop
## it at exactly 96,000 frames with `capped` set, as on the null device (audio_io_null_test
## §1, §2). Then the capture goes through the module's own libopus path at the fixed settings
## and back, its length kept. Audio never leaves this process: nothing is written to a file,
## and the only numbers printed from it are the capture's peak and RMS. An all-zero capture
## fails, naming the likely cause.
##
## The speaker leg plays through the real output device: 48,000 frames a second (±5%), and on
## a short buffer `done` only after the device's own tail of silence (audio_io_null_test §3).
##
## A device start returns at once and the device starts on a thread of its own (voice-notes.md
## §9), so this test's thread is never held: it pumps until the start lands. A start that never
## lands (a permission prompt nobody answers can hold one), or a stop or close that does not
## return, is caught by a watchdog thread, which prints what it was waiting on and exits 1:
## that ends the whole test, so the legs after it do not run (run them alone). A leg that
## fails a check is recorded, and the next leg still runs.

import std/[atomics, math, monotimes, os, strutils, times]
import ../src/audio/[audio_io, miniaudio, voice_clip, voice_codec]

const
  FramesPerMs = ClipRate div 1000                        ## 48
  CapMs = 2_000
  Cap = CapMs * FramesPerMs                              ## 96,000 frames: the capture's cap
  Clip: StreamFormat = (rate: ClipRate, channels: ClipChannels, s16: true)
  Idle: StreamFormat = (rate: 0, channels: 0, s16: false)
  RateLo = 45_600                                        ## 48,000 frames a second, -5%
  RateHi = 50_400                                        ## and +5%
  ToneHz = 440
  ToneAmp = 1_036                                        ## 32,768 × 10^(-30/20): -30 dBFS peak

when defined(macosx):
  const
    WhoAsks = "the app macOS holds responsible for this process (the terminal app, or the " &
              "app that started the shell this runs in)"
    # The binary's name starts with the test's (`nim r`, as run-suite runs it, adds a hash),
    # and tccd names it as the accessing process; the source file gives the name.
    TestName = currentSourcePath().splitFile.name
    # An hour, not minutes: a prompt an earlier run raised and nobody answered is still the
    # one waiting, and a later run's request logs a preflight, not a new prompt. tccd logs
    # every process's requests (hundreds an hour), so the grep keeps the microphone prompts
    # and the lines naming this test's binary. /usr/bin/log in full: zsh, macOS's default
    # shell, has a `log` builtin of its own, which refuses these arguments.
    WhoWasAsked = " To see which app macOS asked: /usr/bin/log show --last 1h --predicate " &
                  "'subsystem == \"com.apple.TCC\"' | grep -E 'AUTHREQ_PROMPTING: " &
                  ".*kTCCServiceMicrophone|identifier=" & TestName & "' (a PROMPTING line " &
                  "names the app it asked for; in a line naming " & TestName & ", that app " &
                  "is responsible=)."
    Grant = "grant it in System Settings > Privacy & Security > Microphone and run again"
    # a loopback driver runs its own clock: with nothing playing into it, it gives frames of
    # silence, so it is a cause of this check's failure, never of the no-frames one
    QuietInput = "the default input hears nothing: it is muted or its input volume is zero, " &
                 "or it is a virtual loopback device (BlackHole, a Zoom or Teams device), " &
                 "which gives frames of silence while nothing plays into it (System " &
                 "Settings > Sound > Input)"
    ZeroHint = "On macOS that is what capture gives when " & WhoAsks & " has been " &
               "denied the microphone (a prompt nobody answers holds the start instead, and " &
               "the watchdog says so): " & Grant & ". Otherwise " & QuietInput & "."
    NoFramesHint = "The device started but gave no frames at all, not even silence. That has " &
                   "not been seen on a Mac, so its cause is not known; an aggregate device " &
                   "whose clock device is missing is a guess, not checked. Pick another " &
                   "input in System Settings > Sound > Input and run again."
    NoDeviceHint = "There is no input device, or macOS refused to open one: the microphone " &
                   "permission belongs to " & WhoAsks & "; " & Grant & "."
else:
  const
    ZeroHint = "The input is muted, or its volume is zero, or the default source hears " &
               "nothing (check pactl info, or arecord -l)."
    NoFramesHint = "The audio server opened a source but gave no frames at all, not even " &
                   "silence. That has not been seen, so its cause is not known (check pactl " &
                   "info, or arecord -l)."
    NoDeviceHint = "There is no input device, or the audio server (PulseAudio, PipeWire or " &
                   "ALSA) refused to open one, or this process could not load its library."

# ── The gate ───────────────────────────────────────────────────────────────────────────────

let gate = getEnv("MUSTER_VOICE_REAL").strip
if gate.len == 0 or gate == "0":
  echo "SKIP voice_device_e2e: MUSTER_VOICE_REAL is not set. It opens the real microphone " &
       "and speaker; run it by name only: MUSTER_VOICE_REAL=1 (both legs), mic or speaker."
  quit 0
var wantMic, wantSpeaker = false
for w in gate.toLowerAscii.split({',', ' '}):
  case w
  of "": discard
  of "1", "all": (wantMic = true; wantSpeaker = true)
  of "mic": wantMic = true
  of "speaker": wantSpeaker = true
  else:
    echo "FAIL voice_device_e2e: MUSTER_VOICE_REAL=", gate, ": say 1 (both legs), mic, " &
         "speaker, or mic,speaker"
    quit 1
if not (wantMic or wantSpeaker):     # separators alone: no leg named, so nothing would run
  echo "FAIL voice_device_e2e: MUSTER_VOICE_REAL=", gate, " names no leg: say 1 (both legs), " &
       "mic, speaker, or mic,speaker"
  quit 1
let audible = getEnv("MUSTER_VOICE_REAL_AUDIBLE") == "1"

# ── A watchdog for device calls that do not return ─────────────────────────────────────────

const Stalls = [
  "",
  "mic: the capture device did not start within 20 s. " &
    (when defined(macosx): "On macOS this is most likely a microphone permission prompt " &
       "nobody answered, for " & WhoAsks & ". Answer it, or grant the microphone in System " &
       "Settings > Privacy & Security > Microphone, and run again." & WhoWasAsked
     else: "The audio server (PulseAudio, PipeWire or ALSA) did not answer."),
  "mic: stopping or closing the capture device did not return within 10 s.",
  "speaker: the output device did not start within 20 s.",
  "speaker: stopping or closing the output device did not return within 10 s."]
var wdStage: Atomic[int]
var wdUntil: Atomic[int64]
var wdThread: Thread[void]

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

proc watchdog() {.thread.} =
  while true:
    sleep(100)
    let s = wdStage.load
    if s > 0 and nowMs() > wdUntil.load:
      echo "FAIL voice_device_e2e: ", Stalls[s]
      quit 1

proc arm(stage, ms: int) =
  wdUntil.store(nowMs() + ms)
  wdStage.store(stage)
proc disarm() = wdStage.store(0)

createThread(wdThread, watchdog)

# ── Helpers ────────────────────────────────────────────────────────────────────────────────

type LegFailed = object of CatchableError

proc check(cond: bool, why: string) =
  if not cond: raise newException(LegFailed, why)

proc msSince(t: MonoTime): int = int((getMonoTime() - t).inMilliseconds)

proc waitUntil(cond: proc (): bool, limitMs: int): int =
  ## Poll every 5 ms until `cond` holds or `limitMs` passes; the ms it took.
  let t0 = getMonoTime()
  while not cond() and msSince(t0) < limitMs: sleep(5)
  msSince(t0)

proc startAndLand(io: MiniaudioIo, buf: AudioBuffer, play: bool, stage: int): tuple[why: string, callMs: int] =
  ## Start, then pump until the start lands, under the watchdog's `stage`: "" once the device
  ## runs, or the word of a start refused at once or failed on its start thread. `callMs`
  ## is how long the start call itself took: the device starts on a thread of its own.
  let t = getMonoTime()
  var why = (if play: io.startPlayback(buf) else: io.startCapture(buf))
  result.callMs = msSince(t)
  arm(stage, 20_000)
  while why.len == 0 and io.starting:
    sleep(2)
    why = io.pump()
  disarm()
  result.why = why

proc dbfs(x: float): string =
  if x <= 0: "-inf dBFS" else: formatFloat(20 * log10(x / 32_768), ffDecimal, 1) & " dBFS"

proc perMs(rate: int): string = formatFloat(rate / 1_000, ffDecimal, 2)

# ── 1. The microphone ──────────────────────────────────────────────────────────────────────

proc micLeg() =
  let sys = backendNames(abSystem)
  check sys.len > 0 and "Null" notin sys, "abSystem lists " & $sys
  let io = newMiniaudioIo(abSystem)
  let buf = newAudioBuffer(Cap)
  let other = newAudioBuffer(ClipRate)
  defer:
    arm(2, 10_000)
    discard io.close()
    disarm()
    freeAudioBuffer(buf)                                 # only after the stream stopped
    freeAudioBuffer(other)
  echo "   mic: opening the capture device on ", sys, " (if the process ends here with no " &
       "FAIL line, the OS ended it: on macOS, TCC refusing the microphone)"
  let (started, callMs) = io.startAndLand(buf, play = false, stage = 1)
  let t0 = getMonoTime()                                 # the cap's pace is timed from here
  check callMs < 100, "mic: startCapture took " & $callMs & " ms to return; it must return at " &
    "once, its device starting on a thread of its own"
  check started != "no-device", "mic: the system backend opened no capture device " &
    "(no-device). " & NoDeviceHint
  check started == "", "mic: startCapture refused: " & started &
    (if started == "device-format": " (the device did not read back as 48 kHz mono s16)" else: "")
  check io.stream == asCapture, "mic: stream " & $io.stream
  check io.streamFormat == Clip, "mic: read back as " & $io.streamFormat & ", want " & $Clip
  check io.backendName in sys, "mic: backend " & io.backendName & " not in " & $sys
  check io.startCapture(other) == "busy" and io.startPlayback(other) == "busy",
    "mic: a second start while capturing was not busy"
  # The write index only grows and never passes the cap; the device thread alone moves it.
  var last = 0
  proc follow(ms: int, stopWhenCapped = false) =
    let t = getMonoTime()
    while msSince(t) < ms:
      let w = buf.written
      check w >= last, "mic: the write index went back, " & $last & " then " & $w
      check w <= Cap, "mic: the write index passed the cap: " & $w
      last = w
      if stopWhenCapped and buf.capped: break
      sleep(5)
  let firstMs = waitUntil(proc (): bool = buf.written > 0, 5_000)
  check buf.written > 0, "mic: no frames within 5 s of the start. " & NoFramesHint
  follow(200)
  let w1 = buf.written
  let t1 = getMonoTime()
  follow(1_000)
  let w2 = buf.written
  let us = int((getMonoTime() - t1).inMicroseconds)
  let rate = (w2 - w1) * 1_000_000 div us
  check not buf.capped, "mic: capped before the rate was measured (" & $w2 & " frames)"
  check rate in RateLo .. RateHi, "mic: " & $(w2 - w1) & " frames in " & $(us div 1_000) &
    " ms: " & $rate & "/s, want 48,000 ±5%"
  echo "   mic: ", io.backendName, ", read back ", io.streamFormat, "; first frames after ",
    firstMs, " ms; ", w2 - w1, " frames in ", us div 1_000, " ms = ", perMs(rate), " frames/ms"
  # The cap: the device thread stops writing at exactly 2 s and sets `capped`, then keeps
  # calling back without writing past it.
  follow(5_000, stopWhenCapped = true)
  let capMs = msSince(t0)
  check buf.capped, "mic: not capped within " & $capMs & " ms (" & $buf.written & " frames)"
  check buf.written == Cap, "mic: capped at " & $buf.written & ", want " & $Cap
  check capMs >= CapMs * 3 div 4, "mic: " & $Cap & " frames in " & $capMs & " ms: not paced"
  follow(100)
  check buf.written == Cap and buf.capped, "mic: written past the cap: " & $buf.written
  arm(2, 10_000)
  check io.stopCapture() == "" and io.stopCapture() == "", "mic: stop"
  disarm()
  check io.stream == asIdle and io.streamFormat == Idle, "mic: not idle after stop"
  echo "   mic: capped after ", capMs, " ms at exactly ", buf.written, " frames"
  # Peak and RMS: the only numbers printed from the audio. The device side's own peak (the
  # one voice_status reports) must equal the peak of the samples it wrote.
  let pcm = buf.takeCaptured()
  check pcm.len == Cap, "mic: took " & $pcm.len & " samples, want " & $Cap
  var peak = 0
  var sq = 0.0
  for s in pcm:
    let v = abs(int(s))
    if v > peak: peak = v
    sq += float(v) * float(v)
  let rms = sqrt(sq / float(pcm.len))
  let devPeak = buf.takePeak()
  echo "   mic: peak ", peak, " (", dbfs(float(peak)), "), RMS ", formatFloat(rms, ffDecimal, 1),
    " (", dbfs(rms), ")"
  check devPeak == peak, "mic: the device side's peak " & $devPeak & " is not the samples' " & $peak
  # The module's own codec path at the fixed settings (voice-notes.md §3.1), and back.
  let enc = encodeClip(pcm)
  check enc.ok, "codec: encode refused: " & enc.why
  check enc.clip.samples == pcm.len, "codec: " & $enc.clip.samples & " samples encoded"
  check enc.clip.packets.len == packetCount(pcm.len, enc.clip.preskip),
    "codec: " & $enc.clip.packets.len & " packets"
  for p in enc.clip.packets: check p.len == PacketBytes, "codec: a packet of " & $p.len & " B"
  let rec = encodeRecord(enc.clip)
  check rec.len <= maxClipBytes(CapMs), "codec: a record of " & $rec.len & " B, over " &
    $maxClipBytes(CapMs)
  let dec = decodeClip(rec)
  check dec.ok, "codec: decode refused: " & dec.why
  check dec.pcm.len == pcm.len, "codec: decoded " & $dec.pcm.len & " samples of " & $pcm.len
  echo "   codec: ", opusVersion(), ", ", pcm.len, " samples into ",
    enc.clip.packets.len, " packets of ", PacketBytes, " B (record ", rec.len,
    " B), decoded back to ", dec.pcm.len, " samples"
  # Last: a capture of nothing but zeros is not a recording.
  check peak > 0, "mic: every one of the " & $pcm.len & " samples is zero (peak 0): the " &
    "microphone delivered silence. " & ZeroHint

# ── 2. The speaker ─────────────────────────────────────────────────────────────────────────

proc speakerLeg() =
  var pcm = newSeq[int16](2 * ClipRate)                  # 2 s of digital silence
  if audible:                                            # 0.5 s of 440 Hz, 10 ms fades
    let n = ClipRate div 2
    let fade = 10 * FramesPerMs
    for i in 0 ..< n:
      let g = min(1.0, min(float(i), float(n - 1 - i)) / float(fade))
      pcm[i] = int16(round(float(ToneAmp) * g * sin(2 * PI * float(ToneHz * i) / float(ClipRate))))
  let io = newMiniaudioIo(abSystem)
  let buf = newAudioBuffer(pcm.len)
  let short = newAudioBuffer(ClipRate div 10)            # 100 ms
  let other = newAudioBuffer(ClipRate)
  defer:
    arm(4, 10_000)
    discard io.close()
    disarm()
    freeAudioBuffer(buf)
    freeAudioBuffer(short)
    freeAudioBuffer(other)
  echo "   speaker: playing ", (if audible: "0.5 s of a 440 Hz tone at -30 dBFS, then 1.5 s " &
       "of silence" else: "2 s of digital silence (zeros): nothing to hear")
  check buf.loadPlayback(pcm) == pcm.len, "speaker: load"
  let (started, callMs) = io.startAndLand(buf, play = true, stage = 3)
  check callMs < 100, "speaker: startPlayback took " & $callMs & " ms to return; it must return " &
    "at once, its device starting on a thread of its own"
  check started == "", "speaker: startPlayback refused: " & started &
    (if started == "no-device": " (no output device, or the OS refused to open one)" else: "")
  check io.stream == asPlayback, "speaker: stream " & $io.stream
  check io.streamFormat == Clip, "speaker: read back as " & $io.streamFormat & ", want " & $Clip
  check io.backendName in backendNames(abSystem), "speaker: backend " & io.backendName &
    " not in " & $backendNames(abSystem)
  check io.startCapture(other) == "busy" and io.startPlayback(other) == "busy",
    "speaker: a second start while playing was not busy"
  # 48,000 frames a second ±5%, between two reads 1 s apart, once the device has started
  # and taken what it takes ahead (a real device starts later than the null one).
  let firstMs = waitUntil(proc (): bool = buf.readIndex > 0, 5_000)
  check buf.readIndex > 0, "speaker: the device took no frames within 5 s"
  sleep(100)
  let r1 = buf.readIndex
  let t1 = getMonoTime()
  sleep(1_000)
  let r2 = buf.readIndex
  let us = int((getMonoTime() - t1).inMicroseconds)
  let rate = (r2 - r1) * 1_000_000 div us
  check not buf.done, "speaker: done before 2 s were played"
  check rate in RateLo .. RateHi, "speaker: " & $(r2 - r1) & " frames in " & $(us div 1_000) &
    " ms: " & $rate & "/s, want 48,000 ±5%"
  arm(4, 10_000)
  check io.stopPlayback() == "", "speaker: stop"
  disarm()
  echo "   speaker: ", io.backendName, ", read back ", Clip, "; first frames taken after ",
    firstMs, " ms; ", r2 - r1, " frames in ", us div 1_000, " ms = ", perMs(rate), " frames/ms"
  # A short buffer: `done` only once the device's own tail of silence followed its last
  # sample (the tail read back at start: miniaudio's intermediary buffer and the device's
  # periods, the same on the null device, not the output's own latency, which miniaudio does
  # not report here). audio_io sets `done` only past that tail, so the check below guards
  # that rule against a regression; it measures nothing of when the sound is heard. Always
  # silence.
  check short.loadPlayback(newSeq[int16](short.cap)) == 4_800, "speaker: short load"
  let (again, _) = io.startAndLand(short, play = true, stage = 3)
  check again == "", "speaker: the second start refused: " & again
  let tail = short.tail
  check tail > 0 and tail < ClipRate, "speaker: a tail of " & $tail & " frames"
  let doneMs = waitUntil(proc (): bool = short.done, 2_000)
  check short.done, "speaker: not done within " & $doneMs & " ms"
  check short.readIndex == 4_800, "speaker: " & $short.readIndex & " frames played"
  check short.silenceAfter >= tail, "speaker: done after " & $short.silenceAfter &
    " frames of silence, the tail is " & $tail
  arm(4, 10_000)
  check io.stopPlayback() == "" and io.stopPlayback() == "", "speaker: stop"
  check io.close() == "" and io.close() == "", "speaker: close"
  disarm()
  check io.stream == asIdle and io.streamFormat == Idle, "speaker: not idle after stop"
  echo "   speaker: 100 ms done after ", doneMs, " ms, ", short.silenceAfter,
    " frames of silence after it (the device's tail: ", tail, " frames, ",
    formatFloat(tail / FramesPerMs, ffDecimal, 1), " ms)"

# ── Run ────────────────────────────────────────────────────────────────────────────────────

echo "voice_device_e2e: miniaudio ", miniaudioVersion(), ", ", opusVersion(),
  ", system backends ", backendNames(abSystem), "; legs: ",
  (if wantMic: "mic " else: ""), (if wantSpeaker: "speaker" else: "")
var failures: seq[string]
if wantMic:
  try:
    micLeg()
    echo "1. mic: 2 s captured on the system device: 48 kHz mono s16, 48 frames/ms ±5%, " &
         "capped at 96,000; through libopus and back, its length kept OK"
  except LegFailed as e:
    failures.add e.msg
    echo "1. FAIL: ", e.msg
if wantSpeaker:
  try:
    speakerLeg()
    echo "2. speaker: the system device: 48 kHz mono s16, 48,000 frames/s ±5%; done " &
         "after the device's tail OK"
  except LegFailed as e:
    failures.add e.msg
    echo "2. FAIL: ", e.msg
if failures.len > 0:
  for f in failures: echo "FAIL voice_device_e2e: ", f
  quit 1
