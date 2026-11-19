## The audio device seam of voice notes (docs/design/voice-notes.md §9), in the shape of
## Transport and BlobStore: the voice surface (S7) codes against AudioIo, never against
## miniaudio, and no test mocks it (CLAUDE.md working agreements). Implementations:
##   * SyntheticAudioIo (here): deterministic PCM on a virtual clock and a collecting sink, the
##     in-process stand-in, as LocalBlobStore is;
##   * FileAudioIo (here): a 48 kHz mono s16 WAV source and a raw PCM sink, for the offscreen
##     self-test (MUSTER_VOICE_SOURCE / MUSTER_VOICE_SINK, S9), on the monotonic clock;
##   * MiniaudioIo (miniaudio.nim): a real device thread, on the platform's backends or null.
##
## Samples cross threads only through an AudioBuffer: calloc'd once and sized to its cap (a
## 60 s recording is 2,880,000 samples, 5,760,000 B), linear, never wrapping, and counted by
## reference, so a start thread (below) that outlives its caller's interest frees it. One side
## writes at the write index, the other reads at the read index, both Atomic. The device side,
## `captureInto` and `playFrom`, runs on a thread Nim does not own, so it keeps
## transport/inbound_queue.nim's rule (:1-11): no GC allocation, no raise, no Defect (checks
## are off there, since a Defect on that thread takes down logos_host), an explicit min() on
## every index, atomics only. SyntheticAudioIo and FileAudioIo call the same two procs from
## `pump`, 10 ms at a time as miniaudio's default period does, so the tests hold the cap,
## `capped`, the peak and `done` on the code the device thread runs.
##
## Capture: the device side copies frames in at the write index until the buffer is full,
## then drops them and sets `capped`. Only that side can hold the 60 s cap: the module has no
## clock (side-modules.md:66), and a Stop can queue behind a 20 s sync call. The module thread
## drains with `takeCaptured`. Playback: the module thread loads the whole decoded clip with
## `loadPlayback`, then starts; the device side copies out at the read index and writes zeros
## past the end. `done` means heard, not handed over: it is set once the device side has
## written the buffer's `tail` of zeros after the last sample, the frames the implementation
## counts as still queued between the callback and the speaker (0 for the in-process sinks,
## which queue nothing; the device's own buffers for MiniaudioIo, read back at its start).
## Stopping a device drops what it still holds (ma_device_uninit), so the module thread, which
## has no clock to wait on, can stop the stream as soon as it sees `done` and drop only silence.
##
## A start can wait on the person: on a Mac, Core Audio held a capture start while a
## microphone prompt stood unanswered (S11). So a device's start never runs on the module
## thread: startCapture / startPlayback return at once, the stream `starting`, and its blocking
## half runs on a start thread of its own (spawnStart, the start job below), which keeps the
## device side's rule; `pump` settles it (running, or the failure's word once), and a stop or
## close while it is in flight lets it go without waiting, its own thread closing what it
## opens. SyntheticAudioIo given a StartGate starts the same way, the gate holding the start
## until a test releases it; without one, and FileAudioIo (no device), a start runs at once.
## One stream at a time per AudioIo (§8 never records and plays at once), so a second start,
## or one while a start is in flight, is "busy". A start refuses a nil buffer ("no-buffer") on
## the module thread, since the device side would dereference it with checks off. A caller
## lets go of a buffer only after the stream using it stopped. Every method returns "" or a
## word naming the refusal.

import std/[atomics, monotimes, os]
from std/posix import Timespec, Time, nanosleep, Pthread, Pthread_attr, pthread_attr_init,
  pthread_attr_destroy, pthread_attr_setdetachstate, pthread_attr_setstacksize,
  pthread_create, PTHREAD_CREATE_DETACHED
import ./voice_clip

const
  FramesPerMs = ClipRate div 1000       ## 48: mono, so a frame is one sample
  Period = 10 * FramesPerMs             ## 480: miniaudio's default 10 ms period

# C's heap, not Nim's: a start thread (below) may free what the module thread allocated, and
# under ORC Nim's allocShared is the calling thread's own heap, which a thread Nim does not own
# must not touch. calloc and free are safe on any thread.
proc cCalloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>", gcsafe, raises: [].}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>", gcsafe, raises: [].}

type
  AudioBufferObj = object
    samples: ptr UncheckedArray[int16]  ## calloc'd, `cap` long; nil when cap is 0
    cap: int
    refs: Atomic[int]                   ## its holders: the caller, and a start thread while its start runs
    writeAt, readAt: Atomic[int]        ## capture: device writes, module reads; playback: the reverse
    peakAbs: Atomic[int]                ## the largest |sample| captured since `takePeak`
    tailAt: Atomic[int]                 ## playback: the zeros past the end before `done`; module sets
    silenceAt: Atomic[int]              ## playback: the zeros written past the end so far; device sets
    cappedFlag, doneFlag: Atomic[bool]
  AudioBuffer* = ptr AudioBufferObj
    ## Shared with a device thread: plain memory and atomics, never GC-traced.

var liveBuffers: Atomic[int]            ## buffers made and not yet freed, in this process

proc newAudioBuffer*(cap: int): AudioBuffer =
  ## A zeroed buffer of `cap` samples, held once, by the caller. Module thread. Let go of it
  ## with freeAudioBuffer once no stream of the caller's uses it.
  let cap = max(cap, 0)
  result = cast[AudioBuffer](cCalloc(1, csize_t(sizeof(AudioBufferObj))))
  result.cap = cap
  result.refs.store(1, moRelaxed)
  if cap > 0:
    result.samples = cast[ptr UncheckedArray[int16]](cCalloc(csize_t(cap), csize_t(sizeof(int16))))
  discard liveBuffers.fetchAdd(1, moRelaxed)

{.push stackTrace: off, checks: off.}
proc retainAudioBuffer(b: AudioBuffer) {.gcsafe, raises: [].} =
  discard b.refs.fetchAdd(1, moRelaxed)

proc freeAudioBuffer*(b: AudioBuffer) {.gcsafe, raises: [].} =
  ## Let go of `b`; it is freed when its last holder lets go: the caller, and a start thread
  ## whose start was let go while it ran (below). Any thread: it touches C's heap and atomics
  ## only.
  if b == nil: return
  if b.refs.fetchSub(1, moAcquireRelease) != 1: return
  if b.samples != nil: cFree(b.samples)
  cFree(b)
  discard liveBuffers.fetchSub(1, moRelease)
{.pop.}

proc liveAudioBuffers*(): int = liveBuffers.load(moAcquire)
  ## How many audio buffers this process has made and not yet freed (what the tests count).

proc cap*(b: AudioBuffer): int = b.cap
proc written*(b: AudioBuffer): int = b.writeAt.load(moAcquire)
  ## Samples in the buffer: captured so far, or loaded to play.
proc readIndex*(b: AudioBuffer): int = b.readAt.load(moAcquire)
  ## Samples taken out: drained by the module thread (capture), or played (playback).
proc capped*(b: AudioBuffer): bool = b.cappedFlag.load(moAcquire)
  ## The capture filled the buffer; frames since were dropped.
proc done*(b: AudioBuffer): bool = b.doneFlag.load(moAcquire)
  ## The playback consumed everything loaded, then wrote `tail` frames of silence after it.
proc tail*(b: AudioBuffer): int = b.tailAt.load(moAcquire)
  ## The silence the device side writes past the end before `done`: what the implementation
  ## counts as still queued between the callback and the speaker.
proc silenceAfter*(b: AudioBuffer): int = b.silenceAt.load(moAcquire)
  ## The frames of silence the device side has written past the end of what was loaded.
proc takePeak*(b: AudioBuffer): int = b.peakAbs.exchange(0, moAcquireRelease)
  ## The largest |sample| captured since the last call (0..32768), and reset it.

{.push stackTrace: off, checks: off.}
proc beginCapture*(b: AudioBuffer) {.gcsafe, raises: [].} =
  ## Empty `b` for a capture, before the stream starts: on the module thread, or on a start
  ## thread before its device starts (atomics only).
  b.writeAt.store(0, moRelaxed)
  b.readAt.store(0, moRelaxed)
  b.peakAbs.store(0, moRelaxed)
  b.cappedFlag.store(false, moRelaxed)
  b.doneFlag.store(false, moRelease)

proc beginPlayback*(b: AudioBuffer, tail = 0) {.gcsafe, raises: [].} =
  ## Rewind `b` to play what was loaded from its start, `done` after `tail` frames of silence
  ## past its end; before the stream starts, on either thread, as beginCapture.
  b.readAt.store(0, moRelaxed)
  b.tailAt.store(max(tail, 0), moRelaxed)
  b.silenceAt.store(0, moRelaxed)
  b.peakAbs.store(0, moRelaxed)
  b.cappedFlag.store(false, moRelaxed)
  b.doneFlag.store(false, moRelease)
{.pop.}

proc loadPlayback*(b: AudioBuffer, pcm: openArray[int16]): int =
  ## Put `pcm` in `b` to be played, up to its cap; the samples loaded. Module thread, with no
  ## stream on `b`.
  let n = min(pcm.len, b.cap)
  if n > 0: copyMem(addr b.samples[0], addr pcm[0], n * sizeof(int16))
  b.writeAt.store(n, moRelease)
  b.beginPlayback()
  n

proc takeCaptured*(b: AudioBuffer): seq[int16] =
  ## The samples captured since the last take, in order. Module thread.
  let w = b.writeAt.load(moAcquire)
  let r = b.readAt.load(moRelaxed)
  if w > r:
    result = newSeq[int16](w - r)
    copyMem(addr result[0], addr b.samples[r], (w - r) * sizeof(int16))
  b.readAt.store(max(w, r), moRelease)

# ── The device side: called on a thread Nim does not own ─────────────────────────────────
{.push stackTrace: off, checks: off.}

proc raisePeak(b: AudioBuffer, m: int) {.inline, gcsafe, raises: [].} =
  var cur = b.peakAbs.load(moRelaxed)
  while m > cur and not b.peakAbs.compareExchangeWeak(cur, m, moRelaxed, moRelaxed): discard

proc captureInto*(b: AudioBuffer, input: ptr UncheckedArray[int16], frames: int) {.gcsafe, raises: [].} =
  ## Copy `frames` captured samples in at the write index, up to the cap. Frames past it are
  ## dropped, and `capped` is set once the buffer is full. This side alone moves the write index.
  let w = b.writeAt.load(moRelaxed)
  let n = max(0, min(frames, b.cap - w))
  var m = 0
  for i in 0 ..< n:
    let v = int(input[i])
    b.samples[w + i] = input[i]
    m = max(m, (if v < 0: -v else: v))
  if n > 0:
    b.writeAt.store(w + n, moRelease)
    b.raisePeak(m)
  if w + n >= b.cap: b.cappedFlag.store(true, moRelease)

proc playFrom*(b: AudioBuffer, output: ptr UncheckedArray[int16], frames: int): int {.gcsafe, raises: [].} =
  ## Copy up to `frames` samples out from the read index, zeros past the end of what was
  ## loaded; set `done` once all of it is consumed and `tail` zeros followed it (they push the
  ## last samples out of the device's queue). The samples copied. This side alone moves the
  ## read index and the silence count.
  let w = b.writeAt.load(moAcquire)
  let r = b.readAt.load(moRelaxed)
  let n = max(0, min(frames, w - r))
  for i in 0 ..< n: output[i] = b.samples[r + i]
  for i in n ..< frames: output[i] = 0
  if n > 0: b.readAt.store(r + n, moRelease)
  if r + n >= w:                        # all of it handed over: count the silence after it
    let z = b.silenceAt.load(moRelaxed) + max(0, frames - n)
    b.silenceAt.store(z, moRelease)
    if z >= b.tailAt.load(moRelaxed): b.doneFlag.store(true, moRelease)
  n

{.pop.}

# ── A start that may not return ──────────────────────────────────────────────────────────

const
  StartSlow* = "device-start-slow"
    ## A start refused because MaxStartsInFlight earlier ones have not returned; also the
    ## voice recorder's word for a start still pending past its bound (voice_live).
  MaxStartsInFlight* = 4
    ## Start threads that may wait at once; past them a start is refused, StartSlow.
  StartWords = ["", "no-device", "device-format", "no-thread", "let-go"]
    ## What a start thread can report, by code: 0 runs; "no-thread" is a start thread that
    ## could not be made; "let-go" a start that saw it was let go and started nothing (no one
    ## reads it: the module thread has forgotten that job).

proc startCode(word: string): int =
  for i, w in StartWords:
    if w == word: return i
  1
proc startWord(code: int): string =
  if code > 0 and code < StartWords.len: StartWords[code] else: StartWords[1]

var startsOut: Atomic[int]              ## start threads whose start has not returned

proc startsInFlight*(): int = startsOut.load(moAcquire)
  ## Start threads in this process whose start has not returned yet.

proc waitStarts*(limitMs: int): bool =
  ## Wait up to `limitMs` for every start thread's start to return: true once none is left.
  ## Module thread. The hosted exit proc runs it after closing the recorder, so close at
  ## unload waits that long at most for a start that never returns.
  let t0 = getMonoTime()
  while startsInFlight() > 0:
    if (getMonoTime().ticks - t0.ticks) div 1_000_000 >= limitMs: return false
    sleep(2)
  true

type
  StartGateObj = object
    state: Atomic[int]                  ## -1 held; else the code its starts return: 0 runs
    reached, stopped: Atomic[int]
  StartGate* = ptr StartGateObj
    ## A device start held until a test releases it, as Core Audio held one behind an
    ## unanswered microphone prompt (S11): SyntheticAudioIo's start waits on it.

proc newStartGate*(): StartGate =
  ## A held gate. Free it with freeStartGate once no start waits on it (waitStarts).
  result = cast[StartGate](cCalloc(1, csize_t(sizeof(StartGateObj))))
  result.state.store(-1, moRelease)
proc freeStartGate*(g: StartGate) = cFree(g)
proc held*(g: StartGate): bool = g.state.load(moAcquire) < 0
proc releaseStart*(g: StartGate, fail = "") =
  ## Let every start waiting on `g` return: run, or fail with the device word `fail`. Only
  ## the first release counts.
  var h = -1
  discard g.state.compareExchange(h, (if fail.len == 0: 0 else: startCode(fail)), moAcquireRelease, moAcquire)
proc startsReached*(g: StartGate): int = g.reached.load(moAcquire)
  ## Starts that reached the gate.
proc startsStopped*(g: StartGate): int = g.stopped.load(moAcquire)
  ## Starts let go while they waited, whose stream their own thread then stopped.

{.push stackTrace: off, checks: off.}
proc gateWait*(g: StartGate): int {.gcsafe, raises: [].} =
  ## A gated start's hold, on its start thread: wait until released; the code it was
  ## released with (0 runs). SyntheticAudioIo's whole start, and the hold a test puts in
  ## MiniaudioIo's (between the device's init and its start).
  discard g.reached.fetchAdd(1, moAcquireRelease)
  var ts = Timespec(tv_sec: Time(0), tv_nsec: 1_000_000)
  var rem: Timespec
  while g.state.load(moAcquire) < 0: discard nanosleep(ts, rem)
  g.state.load(moAcquire)
{.pop.}

# A start job: the blocking half of one stream's start, run on a thread of its own, so the
# module thread never waits on it (PR 340's review; voice-notes.md §9). The start thread is a
# detached pthread, which Nim does not own, so everything it runs keeps the device thread's
# rule (transport/inbound_queue.nim:1-11): no GC allocation, no raise, no Defect (checks off),
# C's heap and atomics only. The module thread makes the job and everything in it before the
# thread starts; afterwards the two meet only at `phase`, by compare-and-swap:
#   * the start thread, once `run` returns: pending → running or failed. The module thread's
#     pump sees that, takes what it needs (MiniaudioIo: the context and the device) and
#     finishes the job (finishStart);
#   * the module thread, on a stop or close before then: pending → let go (letGo), and
#     forgets the job. The start thread's own swap then fails, so it finishes the job itself:
#     it stops a stream its `run` started (`stop`), lets go of the job's buffer reference,
#     frees the implementation's memory (`dispose`) and the job. A `run` may read the let-go
#     itself (wasLetGo) before it starts a stream, and start none (MiniaudioIo does).
#   * a stop or close after the start returned but before any pump saw it: letGo is false,
#     and the module thread finishes the job as the pump would (audio_io_test §8b).
# So nothing is freed twice or used after its free, and a start that never returns holds
# its job, its buffer and its thread until the process ends: never the module thread.

type
  AudioStream* = enum
    asIdle = "idle", asCapture = "capture", asPlayback = "playback"
  StartPhase* = enum
    spPending, spRunning, spFailed, spLetGo
  StartJob* = ptr StartJobObj
  StartRun* = proc (job: StartJob): int {.cdecl, gcsafe, raises: [].}
    ## A start's blocking half, on its start thread: 0 once the stream runs, else a code
    ## (StartNoDevice, StartDeviceFormat, StartLetGo), with whatever it initialised released
    ## again.
  StartStop* = proc (job: StartJob) {.cdecl, gcsafe, raises: [].}
    ## Stop the stream `run` started and release what it initialised, for a start let go
    ## while it ran: on the start thread.
  StartDispose* = proc (job: StartJob) {.cdecl, gcsafe, raises: [].}
    ## Free `job.data`, on whichever thread finishes the job: C's heap only.
  StartJobObj* = object
    phase, code: Atomic[int]
    run: StartRun
    stop: StartStop
    dispose: StartDispose
    buf*: AudioBuffer                   ## the stream's buffer; the job holds a reference of its own
    stream*: AudioStream
    data*: pointer                      ## the implementation's, calloc'd (or not owned: no dispose)

const
  StartNoDevice* = 1
  StartDeviceFormat* = 2
  StartNoThread = 3
  StartLetGo* = 4
    ## `run`'s code for a start that saw it was let go (wasLetGo) and started nothing.

{.push stackTrace: off, checks: off.}
proc endJob(job: StartJob) {.gcsafe, raises: [].} =
  freeAudioBuffer(job.buf)
  if job.dispose != nil: job.dispose(job)
  cFree(job)

proc startMain(arg: pointer): pointer {.noconv, gcsafe, raises: [].} =
  let job = cast[StartJob](arg)
  let code = job.run(job)
  job.code.store(code, moRelaxed)
  var pending = ord(spPending)
  if not job.phase.compareExchange(pending, ord(if code == 0: spRunning else: spFailed),
                                   moAcquireRelease, moAcquire):
    # let go while it ran: the module thread has forgotten it, so this thread finishes it
    if code == 0 and job.stop != nil: job.stop(job)
    endJob(job)
  discard startsOut.fetchSub(1, moAcquireRelease)
  nil
{.pop.}

proc pthreadCreateDetached(arg: pointer): bool =
  # noinit: posix.nim declares pthread_attr_t as an integer on macOS, and a zeroing cast to the
  # struct does not compile; pthread_attr_init initialises it
  var attr {.noinit.}: Pthread_attr
  var tid {.noinit.}: Pthread
  if pthread_attr_init(addr attr) != 0: return false
  discard pthread_attr_setdetachstate(addr attr, PTHREAD_CREATE_DETACHED)
  discard pthread_attr_setstacksize(addr attr, 1 shl 20)   # 1 MiB: miniaudio's init, nothing deep
  result = pthread_create(addr tid, addr attr, startMain, arg) == 0
  discard pthread_attr_destroy(addr attr)

proc spawnStart*(buf: AudioBuffer, stream: AudioStream, run: StartRun, stop: StartStop,
                 dispose: StartDispose, data: pointer): tuple[job: StartJob, why: string] =
  ## Run `run` on a start thread of its own; module thread. (job, "") once it is on its
  ## way, or (nil, why) with nothing taken: StartSlow (MaxStartsInFlight starts have not
  ## returned) or "no-thread"; `data` is still the caller's then.
  if startsInFlight() >= MaxStartsInFlight: return (nil, StartSlow)
  let job = cast[StartJob](cCalloc(1, csize_t(sizeof(StartJobObj))))
  job.phase.store(ord(spPending), moRelaxed)
  job.run = run
  job.stop = stop
  job.dispose = dispose
  job.buf = buf
  job.stream = stream
  job.data = data
  retainAudioBuffer(buf)
  discard startsOut.fetchAdd(1, moAcquireRelease)
  if not pthreadCreateDetached(job):
    discard startsOut.fetchSub(1, moAcquireRelease)
    freeAudioBuffer(buf)
    cFree(job)
    return (nil, StartWords[StartNoThread])
  (job, "")

{.push stackTrace: off, checks: off.}
proc wasLetGo*(job: StartJob): bool {.gcsafe, raises: [].} =
  ## Start thread: the module thread has let this start go (atomics only). `run` reads it
  ## before it starts a stream, so a start given up does not start one.
  job.phase.load(moAcquire) == ord(spLetGo)
{.pop.}

proc startPhase*(job: StartJob): StartPhase = StartPhase(job.phase.load(moAcquire))
  ## Module thread: where the start stands (never spLetGo: a job let go is forgotten).

proc startFailure*(job: StartJob): string = startWord(job.code.load(moAcquire))
  ## Module thread, once spFailed: the device's word for it.

proc letGo*(job: StartJob): bool =
  ## Module thread: let a pending start go. true: its start thread finishes it, and the
  ## caller must not touch the job again. false: its start has returned (spRunning or
  ## spFailed), and the caller finishes it as the pump would.
  var pending = ord(spPending)
  job.phase.compareExchange(pending, ord(spLetGo), moAcquireRelease, moAcquire)

proc finishStart*(job: StartJob) =
  ## Module thread, for a job whose start returned and that was not let go: its buffer
  ## reference, its data (`dispose`) and the job are freed. Take what the stream keeps out of
  ## `data` first.
  endJob(job)

# ── Clocks ─────────────────────────────────────────────────────────────────────────────────

type
  AudioClock* = proc (): int64 {.gcsafe, raises: [].}
    ## Milliseconds on a clock that never goes back.
  VirtualClock* = ref object
    ms*: int64                          ## now on this clock; `advance` moves it

proc advance*(c: VirtualClock, ms: int) = c.ms += int64(ms)
proc clock*(c: VirtualClock): AudioClock =
  ## The clock a test owns.
  result = proc (): int64 = c.ms
proc monotonicClock*(): AudioClock =
  ## The process's monotonic clock.
  result = proc (): int64 = getMonoTime().ticks div 1_000_000

# ── The seam ───────────────────────────────────────────────────────────────────────────────

type
  AudioIo* = ref object of RootObj
    stream*: AudioStream                ## the stream open now; set by implementations only
    buffer*: AudioBuffer                ## the buffer it moves samples through; nil when idle
    starting*: bool                     ## its start has begun and not yet landed; implementations set it

method startCapture*(io: AudioIo, buf: AudioBuffer): string {.base.} =
  ## Empty `buf` and fill it from the source, up to its cap. "" once the start is on its way
  ## (`starting` set while its start thread runs; `pump` settles it), or a refusal at once:
  ## "no-buffer" (`buf` is nil; nothing opens), "busy" (a stream is open or starting),
  ## "no-device", StartSlow, or the implementation's own word.
  raise newException(CatchableError, "AudioIo.startCapture is abstract")
method stopCapture*(io: AudioIo): string {.base.} =
  ## Stop the capture, if one is open: the buffer keeps what it holds. A start in flight is
  ## let go, never waited on. Always "".
  raise newException(CatchableError, "AudioIo.stopCapture is abstract")
method startPlayback*(io: AudioIo, buf: AudioBuffer): string {.base.} =
  ## Play what `buf` holds (loadPlayback), from its start. "" or a refusal, as startCapture.
  raise newException(CatchableError, "AudioIo.startPlayback is abstract")
method stopPlayback*(io: AudioIo): string {.base.} =
  ## Stop the playback, if one is open. Always "".
  raise newException(CatchableError, "AudioIo.stopPlayback is abstract")
method pump*(io: AudioIo): string {.base.} =
  ## Called from the module thread's voice pump: settle a start in flight (its failure's word,
  ## once, the io idle again), then move what is due. "" or a refusal.
  ""
method close*(io: AudioIo): string {.base.} =
  ## Stop any stream and release the device, before the module unloads; a start in flight is
  ## let go, never waited on. Idempotent.
  ""

proc shut(io: AudioIo) =
  io.stream = asIdle
  io.buffer = nil

# ── A device thread run by the module thread's pump ─────────────────────────────────────

type
  PacedAudioIo = ref object of AudioIo
    ## `pump` moves the frames the clock says are due through captureInto / playFrom, a period
    ## at a time, as the device callback would have.
    clock: AudioClock
    source: seq[int16]                  ## what a capture hears from its start; silence after
    t0: int64                           ## the clock when the stream opened
    frames: int                         ## frames moved since

proc open(io: PacedAudioIo, s: AudioStream, buf: AudioBuffer) =
  io.stream = s
  io.buffer = buf
  io.t0 = io.clock()
  io.frames = 0

proc due(io: PacedAudioIo): int =
  max(0, int(io.clock() - io.t0) * FramesPerMs - io.frames)

proc pumpCapture(io: PacedAudioIo) =
  var period: array[Period, int16]
  var n = io.due
  while n > 0:
    if io.buffer.capped:                # the rest would be dropped: skip the copying
      io.frames += n
      break
    let k = min(n, Period)
    for i in 0 ..< k:
      let at = io.frames + i
      period[i] = (if at < io.source.len: io.source[at] else: 0'i16)
    captureInto(io.buffer, cast[ptr UncheckedArray[int16]](addr period[0]), k)
    io.frames += k
    n -= k

proc pumpPlayback(io: PacedAudioIo): seq[int16] =
  ## The samples played: what a speaker would have sounded, without the zeros after the end.
  var period: array[Period, int16]
  var n = io.due
  while n > 0:
    let k = min(n, Period)
    let got = playFrom(io.buffer, cast[ptr UncheckedArray[int16]](addr period[0]), k)
    result.add period.toOpenArray(0, got - 1)
    io.frames += k
    n -= k
    if io.buffer.done:
      io.frames += n
      break

# ── SyntheticAudioIo ───────────────────────────────────────────────────────────────────────

type
  SyntheticAudioIo* = ref object of PacedAudioIo
    sunk: seq[int16]                    ## the collecting sink: the last playback, exactly
    gate: StartGate                     ## when set, every start waits on it, on a start thread
    job: StartJob                       ## the start in flight while `starting`

proc newSyntheticAudioIo*(source: seq[int16], clock: AudioClock, gate: StartGate = nil): SyntheticAudioIo =
  ## A capture hears `source` from its start, then silence; playback is collected. Both run
  ## on `clock`, 48 frames a millisecond. With no `gate` a start runs at once. With one, each
  ## start's blocking half waits on it on a start thread, as MiniaudioIo's device start does:
  ## the start returns at once, `starting`, and runs (its clock from then) or fails as the
  ## gate is released.
  SyntheticAudioIo(source: source, clock: clock, gate: gate)

proc played*(io: SyntheticAudioIo): seq[int16] = io.sunk

{.push stackTrace: off, checks: off.}
proc gateRun(job: StartJob): int {.cdecl, gcsafe, raises: [].} =
  gateWait(cast[StartGate](job.data))
proc gateStop(job: StartJob) {.cdecl, gcsafe, raises: [].} =
  discard cast[StartGate](job.data).stopped.fetchAdd(1, moAcquireRelease)
{.pop.}

proc startGated(io: SyntheticAudioIo, s: AudioStream, buf: AudioBuffer): string =
  if io.gate == nil:
    io.open(s, buf)
    return ""
  let (job, why) = spawnStart(buf, s, gateRun, gateStop, nil, io.gate)   # the gate is the test's
  if job == nil: return why
  io.job = job
  io.stream = s
  io.buffer = buf
  io.starting = true
  ""

proc settle(io: SyntheticAudioIo): string =
  ## A start in flight: "" while pending or once it runs (the clock counts from now), or the
  ## failure's word, once, with the io idle.
  case startPhase(io.job)
  of spPending: ""
  of spRunning:
    finishStart(io.job)
    io.job = nil
    io.starting = false
    io.open(io.stream, io.buffer)
    ""
  of spFailed, spLetGo:
    let why = startFailure(io.job)
    finishStart(io.job)
    io.job = nil
    io.starting = false
    io.shut()
    why

proc letGoStart(io: SyntheticAudioIo) =
  ## Stop or close while starting: never waits. A start that returned meanwhile is finished
  ## here; a synthetic stream has no device to stop.
  if not letGo(io.job): finishStart(io.job)
  io.job = nil
  io.starting = false

method startCapture*(io: SyntheticAudioIo, buf: AudioBuffer): string =
  if buf == nil: return "no-buffer"
  if io.stream != asIdle: return "busy"
  buf.beginCapture()
  io.startGated(asCapture, buf)
method stopCapture*(io: SyntheticAudioIo): string =
  if io.stream == asCapture:
    if io.starting: io.letGoStart()
    io.shut()
  ""
method startPlayback*(io: SyntheticAudioIo, buf: AudioBuffer): string =
  if buf == nil: return "no-buffer"
  if io.stream != asIdle: return "busy"
  buf.beginPlayback()
  io.sunk.setLen(0)
  io.startGated(asPlayback, buf)
method stopPlayback*(io: SyntheticAudioIo): string =
  if io.stream == asPlayback:
    if io.starting: io.letGoStart()
    io.shut()
  ""
method pump*(io: SyntheticAudioIo): string =
  if io.starting:
    let why = io.settle()
    if why.len > 0 or io.starting: return why
  case io.stream
  of asCapture: io.pumpCapture()
  of asPlayback: io.sunk.add io.pumpPlayback()
  of asIdle: discard
  ""
method close*(io: SyntheticAudioIo): string =
  if io.starting: io.letGoStart()
  io.shut()
  ""

# ── FileAudioIo ────────────────────────────────────────────────────────────────────────────

proc u16At(s: string, i: int): int = int(uint8(s[i])) or (int(uint8(s[i + 1])) shl 8)
proc u32At(s: string, i: int): int = u16At(s, i) or (u16At(s, i + 2) shl 16)

proc parseWav*(bytes: string): tuple[ok: bool, pcm: seq[int16], why: string] =
  ## The samples of a RIFF/WAVE file of 48 kHz mono s16 PCM (format 1). Refusals:
  ## "wav-format" for any other kind of file, "wav-truncated" for one that ends before its
  ## "fmt " and "data" chunks do. Chunks between them (LIST, …) are skipped.
  if bytes.len < 12: return (false, @[], "wav-truncated")
  if bytes[0 ..< 4] != "RIFF" or bytes[8 ..< 12] != "WAVE": return (false, @[], "wav-format")
  var at = 12
  var fmtSeen = false
  while true:
    if at + 8 > bytes.len: return (false, @[], "wav-truncated")
    let id = bytes[at ..< at + 4]
    let size = u32At(bytes, at + 4)
    let body = at + 8
    if size > bytes.len - body: return (false, @[], "wav-truncated")
    if id == "fmt ":
      if size < 16 or u16At(bytes, body) != 1 or u16At(bytes, body + 2) != ClipChannels or
          u32At(bytes, body + 4) != ClipRate or u16At(bytes, body + 12) != 2 or
          u16At(bytes, body + 14) != 16:
        return (false, @[], "wav-format")
      fmtSeen = true
    elif id == "data":
      if not fmtSeen or size mod 2 != 0: return (false, @[], "wav-format")
      var pcm = newSeq[int16](size div 2)
      for i in 0 ..< pcm.len: pcm[i] = cast[int16](uint16(u16At(bytes, body + 2 * i)))
      return (true, pcm, "")
    at = body + size + (size and 1)     # chunks are word-aligned

proc pcmLe(pcm: openArray[int16]): string =
  result = newString(pcm.len * 2)
  for i, s in pcm:
    let u = cast[uint16](s)
    result[2 * i] = char(u and 0xFF)
    result[2 * i + 1] = char(u shr 8)

type
  FileAudioIo* = ref object of PacedAudioIo
    sourcePath, sinkPath: string
    sink: File
    sinkOpen: bool

proc newFileAudioIo*(source, sink: string, clock = monotonicClock()): FileAudioIo =
  ## A capture hears the WAV file at `source`, read again at each start, then silence;
  ## playback writes raw s16 little-endian PCM to `sink`, truncated at each start. The only
  ## AudioIo that writes a file, and only to the path it is given (MUSTER_VOICE_SINK).
  FileAudioIo(sourcePath: source, sinkPath: sink, clock: clock)

proc closeSink(io: FileAudioIo) =
  if io.sinkOpen:
    close(io.sink)
    io.sinkOpen = false

method startCapture*(io: FileAudioIo, buf: AudioBuffer): string =
  ## Also "no-source" (no path, or no file there), "wav-format", "wav-truncated".
  if buf == nil: return "no-buffer"
  if io.stream != asIdle: return "busy"
  if io.sourcePath.len == 0: return "no-source"
  var bytes: string
  try: bytes = readFile(io.sourcePath)
  except IOError: return "no-source"
  let w = parseWav(bytes)
  if not w.ok: return w.why
  io.source = w.pcm
  buf.beginCapture()
  io.open(asCapture, buf)
  ""
method stopCapture*(io: FileAudioIo): string =
  if io.stream == asCapture: io.shut()
  ""
method startPlayback*(io: FileAudioIo, buf: AudioBuffer): string =
  ## Also "no-sink": no path, or one that cannot be opened for writing.
  if buf == nil: return "no-buffer"
  if io.stream != asIdle: return "busy"
  if io.sinkPath.len == 0 or not open(io.sink, io.sinkPath, fmWrite): return "no-sink"
  io.sinkOpen = true
  buf.beginPlayback()
  io.open(asPlayback, buf)
  ""
method stopPlayback*(io: FileAudioIo): string =
  if io.stream == asPlayback:
    io.closeSink()
    io.shut()
  ""
method pump*(io: FileAudioIo): string =
  ## Also "sink-write", when the sink refuses a write.
  case io.stream
  of asCapture: io.pumpCapture()
  of asPlayback:
    let pcm = io.pumpPlayback()
    if pcm.len > 0:
      try: io.sink.write(pcmLe(pcm))
      except IOError: return "sink-write"
  of asIdle: discard
  ""
method close*(io: FileAudioIo): string =
  io.closeSink()
  io.shut()
  ""
