## miniaudio 0.11.23 (github.com/mackron/miniaudio, Unlicense OR MIT-0) behind the AudioIo seam
## (docs/design/voice-notes.md §9): MiniaudioIo, a real device thread on the platform's own
## backends (abSystem) or on miniaudio's null backend (abNull). The null device runs the same
## thread, paced in real time, with no microphone, no speaker and no OS permission prompt.
##
## No C is tracked (scripts/check-no-cpp.py:35-45). miniaudio is a codegen.nim.packages pin in
## metadata.json, so its source sits on a --path: the builder's fetchFromGitHub, or
## tools/nim-closure.sh's checkout for run-suite.sh. `maDir` finds miniaudio.h there at
## compile time, and {.compile.} builds miniaudio.c into the staticlib. The -D flags go in a
## GLOBAL passC, not localPassC: the enabled backends change struct layouts, so miniaudio.c and
## every C file that includes miniaudio.h must see the same ones (localPassC failed in the
## prototype), and Nim, not this module, decides which files those are. A generic instance
## over a header type is emitted where Nim puts it: a `seq[ma_backend]` once put its hooks,
## and an #include of miniaudio.h, into system's C. So every header-typed binding stays in
## this module, the backend list is a fixed array (no hooks), and MiniaudioIo's fields are
## plain pointers; with those, only this module's C includes the header (checked in the
## nimcache of audio_io_null_test and of an --app:staticlib build).
##
## Backends: only CoreAudio, PulseAudio (which PipeWire answers through pipewire-pulse), ALSA
## and Null are compiled in. abSystem lists CoreAudio on macOS, PulseAudio then ALSA on Linux,
## and never Null, so a machine with none of them says "no-device" rather than record zeros
## (§9, §12; `backendNames`, audio_io_null_test §5). miniaudio's runtime linking is kept: it
## dlopens those libraries itself, so nothing joins codegen.nim.link, a flat list that would
## carry macOS frameworks onto the Linux link line. The module is built --app:staticlib, so
## nim links nothing: the archive leaves dlopen, dlsym and dlclose undefined, for the plugin's
## own link to resolve (S3), from libSystem on macOS and, on Linux, from libc itself (glibc
## 2.34 and later; earlier ones need -ldl). The darwin-arm64 plugin has been linked (S3): it
## defines ma_context_init and every other ma_ symbol, binds dlopen, dlsym and dlclose to
## libSystem, and links no audio framework. The Linux plugin links have not been run.
##
## Every stream is read back after ma_device_init (S1's read-back rule): the callback must be
## handed 48 kHz mono s16, the clip's own format, or the start is refused, "device-format".
## The device converts to whatever the hardware runs; what it holds after the callback (the
## one-period intermediary buffer and the device's own periods) is a playback's `tail`, so
## `done` is set only once that much silence has followed the last sample (audio_io.nim).
##
## The data callbacks run on miniaudio's thread, which Nim does not own. They are cdecl, gcsafe
## and raises: [], compiled with checks and stack traces off, and only hand the device's
## buffer to audio_io's captureInto / playFrom. A device is initialised and started on a start
## thread of its own (audio_io's start job: maRun), never on the module thread, since Core
## Audio can hold a start while a microphone prompt stands (S11), and never from a callback;
## the start thread keeps the callbacks' rule, and the memory it may free (the context, the
## device, the buffer) is C's heap. The module thread's pump takes the context and the device
## once the start runs. A start let go while it initialised never starts its device: maRun
## reads the let-go just before ma_device_start and releases what it made instead (a start let
## go in the instant after that read starts the device, and its own thread stops it at once).
## A device is uninitialised on the module thread (ma_device_uninit stops it and waits for its
## thread, so the buffer can be let go of once a stop returns), or, for a start let go before
## it returned, on its own start thread. The context is made by a
## start, moves with each later start (the start holds it while in flight) and back to the io
## when it runs, and is kept until `close`, which uninitialises it; a start that fails
## releases it. The voice recorder (coordination/voice_live.nim, S7) closes its AudioIo whenever
## a stream ends, so between streams no context is open, and since muster_module has no
## unload hook (the generated surface exports none) it registers an exit proc that closes
## whatever still runs: a context, and its backend's threads, left alive when the host unloads
## the plugin is a crash risk.

import std/[atomics, compilesettings, os]
import ./audio_io
import ./voice_clip

const maDir = block:
  var d = ""
  for p in querySettingSeq(searchPaths):
    if d.len == 0 and fileExists(p / "miniaudio.h"): d = p
  doAssert d.len > 0, "miniaudio.h is on no --path: the metadata.json miniaudio pin " &
    "(run-suite.sh passes --path:$P/miniaudio, the builder its fetch)"
  d

{.passC: "-I" & quoteShell(maDir) &
  " -DMA_ENABLE_ONLY_SPECIFIC_BACKENDS -DMA_ENABLE_COREAUDIO -DMA_ENABLE_PULSEAUDIO" &
  " -DMA_ENABLE_ALSA -DMA_ENABLE_NULL -DMA_NO_DECODING -DMA_NO_ENCODING -DMA_NO_GENERATION" &
  " -DMA_NO_RESOURCE_MANAGER -DMA_NO_NODE_GRAPH -DMA_NO_ENGINE".}
{.compile: maDir / "miniaudio.c".}

const H = "miniaudio.h"

type
  MaResult {.importc: "ma_result", header: H.} = cint
  MaBackend {.importc: "ma_backend", header: H.} = cint
  MaDeviceType {.importc: "ma_device_type", header: H.} = cint
  MaFormat {.importc: "ma_format", header: H.} = cint
  MaDataProc {.importc: "ma_device_data_proc", header: H.} = pointer
    ## void (*)(ma_device*, void*, const void*, ma_uint32): its own type, with each Nim
    ## callback cast to it, since clang 19 rejects assigning a proc whose input is not const.
  MaContext {.importc: "ma_context", header: H.} = object
    backend: MaBackend
  MaDeviceStream {.importc: "struct ma_device_stream_unnamed", header: H.} = object
    ## ma_device's anonymous `playback` and `capture` structs (miniaudio.h:7814-7861), reached
    ## only as dev.playback.* / dev.capture.*, so this name never reaches C. `format` and
    ## `channels` are the client side, what the callback is handed; the internal fields are
    ## the device's own; intermediaryBufferCap is at the client rate.
    format: MaFormat
    channels: uint32
    internalSampleRate, internalPeriodSizeInFrames, internalPeriods: uint32
    intermediaryBufferCap: uint32
  MaDevice {.importc: "ma_device", header: H.} = object
    sampleRate: uint32                  ## the client side's, for both directions
    pUserData: pointer
    playback, capture: MaDeviceStream
  MaStreamConfig {.importc: "struct ma_device_config_stream_unnamed", header: H.} = object
    ## ma_device_config's anonymous `playback` and `capture` structs. They are reached only as
    ## cfg.playback.* / cfg.capture.*, so this name never reaches C.
    format: MaFormat
    channels: uint32
  MaDeviceConfig {.importc: "ma_device_config", header: H.} = object
    sampleRate: uint32
    dataCallback: MaDataProc
    pUserData: pointer
    playback, capture: MaStreamConfig

let
  MA_SUCCESS {.importc, header: H, nodecl.}: MaResult
  ma_backend_coreaudio {.importc, header: H, nodecl.}: MaBackend
  ma_backend_pulseaudio {.importc, header: H, nodecl.}: MaBackend
  ma_backend_alsa {.importc, header: H, nodecl.}: MaBackend
  ma_backend_null {.importc, header: H, nodecl.}: MaBackend
  ma_device_type_playback {.importc, header: H, nodecl.}: MaDeviceType
  ma_device_type_capture {.importc, header: H, nodecl.}: MaDeviceType
  ma_format_s16 {.importc, header: H, nodecl.}: MaFormat

{.push importc, cdecl, header: H.}
proc ma_context_init(backends: ptr MaBackend, backendCount: uint32, config: pointer,
                     ctx: ptr MaContext): MaResult
proc ma_context_uninit(ctx: ptr MaContext): MaResult
proc ma_device_config_init(deviceType: MaDeviceType): MaDeviceConfig
proc ma_device_init(ctx: ptr MaContext, config: ptr MaDeviceConfig, dev: ptr MaDevice): MaResult
proc ma_device_uninit(dev: ptr MaDevice)
proc ma_device_start(dev: ptr MaDevice): MaResult
proc ma_get_backend_name(backend: MaBackend): cstring
proc ma_version_string(): cstring
{.pop.}

# ── The device thread's callbacks ───────────────────────────────────────────────────────────
{.push stackTrace: off, checks: off.}

proc onCapture(dev: ptr MaDevice, output, input: pointer, frameCount: uint32) {.cdecl, gcsafe, raises: [].} =
  captureInto(cast[AudioBuffer](dev.pUserData), cast[ptr UncheckedArray[int16]](input),
              int(frameCount))

proc onPlayback(dev: ptr MaDevice, output, input: pointer, frameCount: uint32) {.cdecl, gcsafe, raises: [].} =
  discard playFrom(cast[AudioBuffer](dev.pUserData), cast[ptr UncheckedArray[int16]](output),
                   int(frameCount))

{.pop.}

# ── MiniaudioIo ────────────────────────────────────────────────────────────────────────────

type
  AudioBackend* = enum
    abSystem = "system"         ## CoreAudio (macOS); PulseAudio, then ALSA (Linux); never Null
    abNull = "null"             ## miniaudio's null device: a real thread, no device, no prompt

  MiniaudioIo* = ref object of AudioIo
    backend: AudioBackend
    ctx: pointer                ## an ma_context, made by a start, kept until close; calloc'd
    dev: pointer                ## the open stream's ma_device; nil when idle or starting; calloc'd
    job: StartJob               ## the start in flight while `starting` (it holds the context)
    gate: StartGate             ## a test's hold between the device's init and its start; nil

  StreamFormat* = tuple[rate, channels: int, s16: bool]
    ## A stream's client-side settings: what the callback is handed.

const ClipFormat: StreamFormat = (rate: ClipRate, channels: ClipChannels, s16: true)

proc newMiniaudioIo*(backend = abSystem, gate: StartGate = nil): MiniaudioIo =
  ## Opens nothing: the context is made by the first start, which only voice_record_start or
  ## voice_play makes (with the access policy off, any caller's, §13). `gate` is a test's: each
  ## start then waits on it after the device's init and read-back, before the device starts,
  ## where Core Audio may hold a start behind a microphone prompt (audio_io_null_test §7); the
  ## module never passes one.
  MiniaudioIo(backend: backend, gate: gate)

var deviceStarts: Atomic[int]           ## ma_device_start calls that started a device

proc devicesStarted*(): int = deviceStarts.load(moAcquire)
  ## How many devices this process has started (ma_device_start succeeded), on any io: what
  ## the tests count to see a start given up start nothing.

proc miniaudioVersion*(): string = $ma_version_string()

proc backendName*(io: MiniaudioIo): string =
  ## The backend the context runs on, as miniaudio names it ("Null", "Core Audio", …); "" until
  ## a start made the context.
  if io.ctx == nil: "" else: $ma_get_backend_name(cast[ptr MaContext](io.ctx).backend)

proc backendsOf(b: AudioBackend): tuple[at: array[2, MaBackend], n: int] =
  ## The context's backend list, in order: the first `n` of `at`. A fixed array, not a seq,
  ## so no generic hook over ma_backend leaves this module (the header note). `n` is 0 only
  ## off macOS and Linux, where no backend is compiled in for abSystem.
  case b
  of abNull:
    result.at[0] = ma_backend_null
    result.n = 1
  of abSystem:
    when defined(macosx):
      result.at[0] = ma_backend_coreaudio
      result.n = 1
    elif defined(linux):
      result.at[0] = ma_backend_pulseaudio
      result.at[1] = ma_backend_alsa
      result.n = 2

proc backendNames*(b: AudioBackend): seq[string] =
  ## The backends a context for `b` lists, in order, as miniaudio names them. Pure: it makes
  ## no context and opens no device, so it prompts nothing. abSystem never lists Null and, on
  ## macOS and Linux, is never empty (audio_io_null_test §5).
  let list = backendsOf(b)
  for i in 0 ..< list.n: result.add $ma_get_backend_name(list.at[i])

proc cCalloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>", gcsafe, raises: [].}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>", gcsafe, raises: [].}
  # C's heap: a start thread frees what the module thread made when its start was let go

type
  MaStart = object
    ## One start's own memory, calloc'd on the module thread, freed by whoever finishes the
    ## start (maDispose): the context (the io's, handed over, or a new one) and the device.
    ctx: ptr MaContext
    dev: ptr MaDevice
    backends: array[2, MaBackend]
    n: int
    ctxUp, devUp: bool          ## initialised (ctxUp: by this start, or handed over so)
    gate: StartGate             ## the io's test hold, or nil

# ── The start thread's half (audio_io's start job): no GC, no raise, checks off ─────────────
{.push stackTrace: off, checks: off.}

proc formatOf(dev: ptr MaDevice, s: AudioStream): StreamFormat {.gcsafe, raises: [].} =
  ## Read back from an initialised device: the client side of stream `s`.
  case s
  of asCapture:
    (rate: int(dev.sampleRate), channels: int(dev.capture.channels),
     s16: dev.capture.format == ma_format_s16)
  of asPlayback:
    (rate: int(dev.sampleRate), channels: int(dev.playback.channels),
     s16: dev.playback.format == ma_format_s16)
  of asIdle: (rate: 0, channels: 0, s16: false)

proc playbackTail(dev: ptr MaDevice): int {.gcsafe, raises: [].} =
  ## The frames a playback device still holds once the callback has handed a frame over, at
  ## the client rate: miniaudio's intermediary buffer, then the device's own periods at its
  ## rate, rounded up. ma_device_uninit drops them, so `done` waits for this much silence.
  ## The resampler's few frames, when the rates differ, are not counted.
  let rate = (if dev.playback.internalSampleRate > 0: int(dev.playback.internalSampleRate)
              else: ClipRate)
  let held = int(dev.playback.internalPeriods) * int(dev.playback.internalPeriodSizeInFrames)
  int(dev.playback.intermediaryBufferCap) + (held * ClipRate + rate - 1) div rate

proc maRelease(m: ptr MaStart) {.gcsafe, raises: [].} =
  ## Uninitialise what this start holds: the device (miniaudio stops it and waits for its
  ## thread), then the context.
  if m.devUp:
    ma_device_uninit(m.dev)
    m.devUp = false
  if m.ctxUp:
    discard ma_context_uninit(m.ctx)
    m.ctxUp = false

proc maRun(job: StartJob): int {.cdecl, gcsafe, raises: [].} =
  ## The blocking half of a start, on its start thread: the context (unless handed over), the
  ## device, its read-back, then its start, unless the module thread let the start go
  ## meanwhile (StartLetGo: nothing started, all of it released). Core Audio can hold a start
  ## while a microphone prompt stands (S11); in which call is not known. A failure releases
  ## all of it, a handed-over context included.
  let m = cast[ptr MaStart](job.data)
  if not m.ctxUp:
    if ma_context_init(addr m.backends[0], uint32(m.n), nil, m.ctx) != MA_SUCCESS:
      return StartNoDevice
    m.ctxUp = true
  var cfg: MaDeviceConfig
  if job.stream == asCapture:
    cfg = ma_device_config_init(ma_device_type_capture)
    cfg.capture.format = ma_format_s16
    cfg.capture.channels = uint32(ClipChannels)
    cfg.dataCallback = cast[MaDataProc](onCapture)
  else:
    cfg = ma_device_config_init(ma_device_type_playback)
    cfg.playback.format = ma_format_s16
    cfg.playback.channels = uint32(ClipChannels)
    cfg.dataCallback = cast[MaDataProc](onPlayback)
  cfg.sampleRate = uint32(ClipRate)
  cfg.pUserData = job.buf
  if ma_device_init(m.ctx, addr cfg, m.dev) != MA_SUCCESS:
    maRelease(m)
    return StartNoDevice
  m.devUp = true
  if formatOf(m.dev, job.stream) != ClipFormat:    # read back before the stream starts
    maRelease(m)
    return StartDeviceFormat
  if job.stream == asCapture: job.buf.beginCapture()
  else: job.buf.beginPlayback(playbackTail(m.dev))
  if m.gate != nil:                     # a test's hold, where Core Audio may hold a start
    let held = gateWait(m.gate)
    if held != 0:
      maRelease(m)
      return held
  if wasLetGo(job):                     # given up while it initialised: start no stream
    maRelease(m)                        # (let go after this read, startMain stops it at once)
    return StartLetGo
  if ma_device_start(m.dev) != MA_SUCCESS:
    maRelease(m)
    return StartNoDevice
  discard deviceStarts.fetchAdd(1, moAcquireRelease)
  0

proc maStop(job: StartJob) {.cdecl, gcsafe, raises: [].} =
  ## A start let go while it ran, that started its stream: stop it and release it all.
  maRelease(cast[ptr MaStart](job.data))

proc freeMaStart(m: ptr MaStart) {.gcsafe, raises: [].} =
  ## Free a start's memory: what the io did not take (`ctx`, `dev` set nil) and the block.
  if m == nil: return
  if m.ctx != nil: cFree(m.ctx)
  if m.dev != nil: cFree(m.dev)
  cFree(m)

proc maDispose(job: StartJob) {.cdecl, gcsafe, raises: [].} =
  freeMaStart(cast[ptr MaStart](job.data))

{.pop.}

# ── The module thread's half ─────────────────────────────────────────────────────────────────

proc streamFormat*(io: MiniaudioIo): StreamFormat =
  ## The open stream's client-side settings, read back from the device miniaudio initialised;
  ## (0, 0, false) when idle or starting. A start refuses any but 48 kHz mono s16
  ## ("device-format").
  if io.dev == nil: (rate: 0, channels: 0, s16: false)
  else: formatOf(cast[ptr MaDevice](io.dev), io.stream)

proc closeStream(io: MiniaudioIo) =
  ## Uninitialise the open device: miniaudio stops it and waits for its thread. Module thread.
  if io.dev != nil:
    ma_device_uninit(cast[ptr MaDevice](io.dev))
    cFree(io.dev)
    io.dev = nil
  io.stream = asIdle
  io.buffer = nil

proc settle(io: MiniaudioIo): string =
  ## The start in flight: "" while pending, or once it runs (the io takes its context and
  ## device), or the failure's word, once, with the io idle and nothing open.
  case startPhase(io.job)
  of spPending: return ""
  of spRunning:
    let m = cast[ptr MaStart](io.job.data)
    io.ctx = m.ctx
    io.dev = m.dev
    m.ctx = nil
    m.dev = nil
    result = ""
  of spFailed, spLetGo:
    result = startFailure(io.job)
    io.stream = asIdle
    io.buffer = nil
  finishStart(io.job)
  io.job = nil
  io.starting = false

proc letGoStart(io: MiniaudioIo) =
  ## Stop or close while the start is in flight: never waits on it. Let go, its start thread
  ## stops whatever it started and frees it once its start returns; returned meanwhile, it is
  ## settled here and its device closed.
  if letGo(io.job):
    io.job = nil
    io.starting = false
  else:
    discard io.settle()
  io.closeStream()

proc openStream(io: MiniaudioIo, s: AudioStream, buf: AudioBuffer): string =
  # A nil reaching pUserData is dereferenced on miniaudio's thread with checks off: a SIGSEGV
  # in logos_host. Refused here, on the module thread, before a context or device is made.
  if buf == nil: return "no-buffer"
  if io.stream != asIdle: return "busy"
  let list = backendsOf(io.backend)
  if list.n == 0: return "no-device"
  let m = cast[ptr MaStart](cCalloc(1, csize_t(sizeof(MaStart))))
  m.backends = list.at
  m.n = list.n
  m.gate = io.gate
  if io.ctx != nil:                     # the context moves with the start, and back if it runs
    m.ctx = cast[ptr MaContext](io.ctx)
    m.ctxUp = true
    io.ctx = nil
  else:
    m.ctx = cast[ptr MaContext](cCalloc(1, csize_t(sizeof(MaContext))))
  m.dev = cast[ptr MaDevice](cCalloc(1, csize_t(sizeof(MaDevice))))
  let (job, why) = spawnStart(buf, s, maRun, maStop, maDispose, m)
  if job == nil:                        # nothing started: the io keeps its context
    if m.ctxUp:
      io.ctx = m.ctx
      m.ctx = nil
    freeMaStart(m)
    return why
  io.job = job
  io.stream = s
  io.buffer = buf
  io.starting = true
  ""

method startCapture*(io: MiniaudioIo, buf: AudioBuffer): string =
  ## "" once the start is on its way (`starting` until the pump sees it run), or at once
  ## "no-buffer", "busy", "no-device" (no backend listed for this platform), "no-thread", or
  ## "device-start-slow" (MaxStartsInFlight starts have not returned). The pump reports a
  ## start that failed: "no-device" (no backend initialised, or no capture device), or
  ## "device-format" (the device read back as other than 48 kHz mono s16).
  io.openStream(asCapture, buf)
method stopCapture*(io: MiniaudioIo): string =
  if io.stream == asCapture:
    if io.starting: io.letGoStart() else: io.closeStream()
  ""
method startPlayback*(io: MiniaudioIo, buf: AudioBuffer): string =
  io.openStream(asPlayback, buf)
method stopPlayback*(io: MiniaudioIo): string =
  if io.stream == asPlayback:
    if io.starting: io.letGoStart() else: io.closeStream()
  ""
method pump*(io: MiniaudioIo): string =
  ## A start in flight is settled here; nothing else to move: the device thread does it,
  ## and the voice pump reads the buffer.
  if io.starting: io.settle() else: ""
method close*(io: MiniaudioIo): string =
  if io.starting: io.letGoStart() else: io.closeStream()
  if io.ctx != nil:
    discard ma_context_uninit(cast[ptr MaContext](io.ctx))
    cFree(io.ctx)
    io.ctx = nil
  ""
