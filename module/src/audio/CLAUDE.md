# module/src/audio/

Voice notes' audio (`docs/design/voice-notes.md`): a short clip recorded, encoded, decoded and
played inside `muster_module`. Audio plaintext never leaves the module: no method returns PCM
or a clip, and nothing here writes a file except `FileAudioIo`'s sink, to the one path it is
given (`MUSTER_VOICE_SINK`, the offscreen self-test) (§7, §9).

- `voice_clip.nim`: the clip record (§3.2), a CDE record of Opus packets built with
  `src/dcbor` (invariant 5), and its strict reader. Pure: it links no codec. The clip
  constants (48 kHz mono, 20 ms frames, 16 kbps, the 60 s cap) live here, and
  `maxClipBytes` is §5's size budget.
- `opus.nim`: the libopus binding, `importc` with no header (as `crypto/sodium.nim`), linked
  through `metadata.json` (`codegen.nim.link` "opus", `nix.packages.runtime` "libopus").
- `voice_codec.nim`: PCM to a clip record and back at one fixed set of settings (§3.1):
  an incremental encoder (`feed` / `finish` / `clip`) and `decodeClip`.
- `audio_io.nim`: the device seam (§9), shaped like `Transport` and `BlobStore`. `AudioBuffer`
  is the only thing a device thread touches: `calloc`'d (C's heap, so any thread may free
  it), counted by reference, sized to its cap, linear, two `Atomic` indices, `capped`, `done`
  and the peak. `captureInto` / `playFrom` are the device side. `AudioIo`'s methods
  (`startCapture`, `stopCapture`, `startPlayback`, `stopPlayback`, `pump`, `close`) return
  `""` or a refusal word; a start may return with the stream `starting`, its blocking half on
  a start thread (`spawnStart`, the start job), and `pump` settles it. `SyntheticAudioIo` (a
  virtual clock, a collecting sink; with a `StartGate`, a start held on its start thread
  until the test releases it) and `FileAudioIo` (a 48 kHz mono s16 WAV source, a raw PCM
  sink; its start is synchronous: no device) are the in-process stand-ins; their `pump`
  drives the same device side 10 ms at a time.
- `miniaudio.nim`: `MiniaudioIo`, miniaudio 0.11.23 behind the seam, on the platform's
  backends (`abSystem`: CoreAudio; PulseAudio, then ALSA) or the null device (`abNull`). The C
  comes from the `codegen.nim.packages` pin and is `{.compile.}`d from the `--path`, so no C is
  tracked (`scripts/check-no-cpp.py`).

Rules (the traps behind them, and how each was found: `docs/labbook/voice-notes-audio-stack.md`):
- The ctl functions stay `{.varargs.}`, every SET value a `cint`, every GET argument a
  `ptr cint`. A fixed-arity binding hands libopus whatever is on the stack on Apple arm64: in
  the prototype a silent 300000 bitrate (§3.1), in this build `OPUS_BAD_ARG`. Every setting is
  read back after it is set (`newClipEncoder`, `voice_codec_test` §1).
- libopus decodes room-supplied bytes only after `voice_clip.decodeRecord` accepted the
  record and every packet carries 20 ms of audio: 960 samples, as `opus_packet_get_nb_samples`
  reads them off the TOC byte (and a code-3 packet's frame count). That is a sample count, not
  one frame: several frames adding up to 20 ms pass. A refusal is a value naming why, never a
  raise.
- The room's fold and thread rows (`coordination/voice.nim`) import `voice_clip` only, never
  `opus` or `voice_codec`: the fold must not link a codec (§6). The hosted half,
  `coordination/voice_live.nim` (`VoiceRecorder`, the state machine of the seven voice
  methods, S7), is the one coordination file that links the codec: it imports `voice_codec`
  and the `AudioIo` seam. It drains the capture buffer into the incremental encoder on every
  pump, and closes the `AudioIo` at the first pump after a stream ends (Stop, the cap's
  `capped`, playback's `done`), so between streams no device and no miniaudio context is
  open. Nothing on the device side stops a stream: past the cap a capture keeps its device
  open, dropping frames, and past `done` a playback plays silence, until the next voice
  method or `coordinate_intents` call pumps (voice-notes.md §9, §15).
- A change to any clip constant or the record's fields strands notes already sent: it is a
  new `v`, never an edit (§3.4).
- **The device thread.** miniaudio calls back on a thread Nim does not own
  (`transport/inbound_queue.nim:1-11`'s rule): the callbacks and `captureInto` / `playFrom`
  stay `cdecl` / `gcsafe` / `raises: []` under `{.push stackTrace: off, checks: off.}`, with no
  GC allocation, no raise, an explicit `min()` on every index, and only the buffer's atomics
  shared. Only that side holds the 60 s cap: the module has no clock.
- **The start thread** (PR 340's review: a start held the module thread behind a microphone
  prompt). No device start runs on the module thread: `ma_context_init`, `ma_device_init`,
  the read-back and `ma_device_start` run on a detached pthread per start (`spawnStart`,
  `MiniaudioIo`'s `maRun`), which Nim does not own, so it keeps the device thread's rule
  above: `{.push stackTrace: off, checks: off.}`, `cdecl` / `noconv`, `gcsafe`, `raises: []`,
  no GC allocation (no string, no seq, no ref, no closure), C's heap (`calloc` / `free`)
  and atomics only. Never `allocShared` / `deallocShared` there: under ORC that is the
  calling thread's own heap. The module thread makes the job and everything in it (the
  buffer's extra reference, the context the io held or a new one, the device's memory)
  before the thread starts; after that the two meet only at the job's `phase`, by
  compare-and-swap: the start thread swaps pending → running or failed; the module thread,
  at a stop or close before then, swaps pending → let go and forgets the job, never waiting.
  Whoever loses the swap's race does not touch the job again: a let-go start's own thread
  stops what it started (`stop`), lets go of its buffer reference, frees the rest
  (`dispose`) and the job; otherwise the module thread's `pump` settles it (`finishStart`),
  or a stop or close does, when the start returned before any pump saw it. `MiniaudioIo`'s
  start reads the let-go (`wasLetGo`) just before `ma_device_start`, so a start let go while
  it initialised never starts its device (`StartLetGo`; audio_io_null_test §7, through a
  test's `StartGate` held between the device's init and its start, and `devicesStarted`).
  A start that fails releases everything it initialised before it reports. At most
  `MaxStartsInFlight` (4) start threads wait at once: past them a start is refused
  `device-start-slow`. A start that never returns holds its own thread, job and buffer until
  the process ends: `close` lets it go, and the hosted exit proc waits for start threads
  `waitStarts(2_000)`, at most 2 s, never longer (voice-notes.md §9).
- Devices stop on the module thread, never from a callback, except a start let go before it
  returned, which its own start thread stops; one stream per `AudioIo` at a time (a second
  start, a starting one's included, is `busy`). Every start refuses a nil buffer
  (`no-buffer`) on the module thread, before anything opens or any thread starts. A caller
  lets go of a buffer (`freeAudioBuffer`) only after the stream using it stopped
  (`ma_device_uninit` waits for the device thread); a start let go holds its own reference,
  so the buffer is freed when its thread is done with it. `close` runs before unload.
- `done` means heard, not handed over: `playFrom` sets it once the buffer's `tail` of silence
  has followed the last sample. The tail is what the implementation counts as still queued
  past the callback: 0 for the in-process sinks; for `MiniaudioIo`, the intermediary buffer
  plus the device's own periods, read back at start (1,920 frames on the null device). So the
  voice pump (S7), which has no clock, stops the stream as soon as it sees `done`.
- Every device stream is read back after `ma_device_init` (S1's rule): anything but 48 kHz mono
  s16 on the callback's side is refused, `device-format` (`streamFormat`, audio_io_null_test
  §1, §3).
- `abSystem` never lists Null, and never an empty list (miniaudio's default order ends in Null):
  no backend means `no-device`, never a recording of zeros. `backendNames` reads the lists
  with no context (audio_io_null_test §5).
- Nothing outside this directory imports `miniaudio` but the hosted module
  (`nim-lib/muster_module.nim`), which makes the one `AudioIo` on the first voice call, as
  `voice_live.voiceIoChoice` picks it: `FileAudioIo` when MUSTER_VOICE_SOURCE or
  MUSTER_VOICE_SINK is set, `MiniaudioIo(abNull)` for MUSTER_VOICE_BACKEND=null, else
  `MiniaudioIo(abSystem)`, and hands it to `voice_live`. That opens nothing: the context is
  made on the first start. It registers an exit proc that closes the recorder, then waits up to
  2 s for start threads (`waitStarts`), since the generated surface has no unload hook. `voice_live` codes against `AudioIo` only. Every
  miniaudio header type stays in `miniaudio.nim`, never inside a generic (a `seq` of one put
  miniaudio.h into system's C: use a fixed array), and the `-D` backend flags stay one global
  `passC` (they change struct layouts).
- No test in the default run opens a real device: `abNull` only. The real-device test,
  `module/tests/voice_device_e2e.nim` (S11), sits behind `MUSTER_VOICE_REAL`, in run-suite's
  E2E list, and skips without it. It prints a capture's peak and RMS and nothing else from the
  audio, writes no file, and plays digital silence unless `MUSTER_VOICE_REAL_AUDIBLE=1`. On
  macOS a first capture start blocks while a microphone prompt stands unanswered, where the
  app macOS holds responsible can prompt, as for a test run from a shell (seen: still not
  returned after 20 s; that it returns on an answer is inferred; the labbook, §9); Basecamp
  0.3.2's `logos_host` is never prompted and captures zeros (voice-notes.md §11). The
  start now returns at once and blocks its start thread instead, so the test pumps until it
  lands, and a watchdog thread ends the test when it has not landed after 20 s, or a stop
  or close has not returned after 10 s.
- Tests: `module/tests/voice_clip_test.nim` (pure), `module/tests/voice_codec_test.nim`
  (libopus; `run-suite.sh` links the builder pin's, the .lgx's 1.5.2, on macOS and, since PR
  340's review, on Linux, where §1 printed 1.5.2 on both arches in the fork's CI at
  `08dfcb3`; `MUSTER_OPUS` picks another; §1 prints the version),
  `module/tests/audio_io_test.nim` (the seam with no device; §7–§9 a start held by a
  `StartGate`: stopped after the pump saw it run, let go, returned before any pump saw it
  (§8b), failed, the in-flight cap, the buffers counted),
  `module/tests/audio_io_null_test.nim` (miniaudio's null device thread, its starts on the
  start thread, §6 stopping and closing 80 of them at once, §6b stopping and closing ones that
  returned before any pump, §7 one let go before its device started starting none;
  `run-suite.sh` puts the pin's checkout on `--path`),
  `module/tests/voice_device_e2e.nim` (the real devices, gated, above), and
  `module/tests/voice_live_test.nim` (the recorder over
  `SyntheticAudioIo`, `FileAudioIo` and the null device, two members over `LocalTransport`).
  `probes/probe_return_marshalling_host.nim` (exo-526) builds the whole module into a host,
  so it links libopus (`opusTokens`, `MUSTER_OPUS_LIB`) and compiles miniaudio from the
  closure's checkout; its `voice_status` call must name the libopus linked, with both
  devices still "unknown", and the six other voice methods, called with no room joined,
  must each reply exactly what that state gives, opening no device.
