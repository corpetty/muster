## Voice notes' hosted half (docs/design/voice-notes.md §8, §9): `VoiceRecorder`, the state
## machine muster_module's seven voice methods run, one per module instance. Audio and Opus
## live in the module only, and no method returns audio: every reply is a small JSON object
## of integers, strings, booleans and null (voice_live_test §8).
##
##          recordStart          the pump sees       recordStop, or the 60 s cap (`capped`)
##    idle ─────────────▶ starting ─────────────▶ recording ──────────────────────────▶ draft
##     ▲ ▲                   │  the device runs                                         │  │
##     │ └───────────────────┘ Stop (not-started), Discard, close; or the start failed, │  │
##     │                       or still pending after StartBoundMs (StartSlow)          │  │
##     ├────────────── draftSend: two author-signed parts published ────────────────────┘  │
##     └────────────── draftDiscard (also drops a recording in progress) ──────────────────┘
##
##    play(note | "draft") from idle or draft → playing (`starting` until its device runs)
##    → done (the pump sees it), or playStop → back where it was. Never while recording or
##    starting one; one stream at a time.
##
## A device's start can wait on the person (Core Audio held one behind an unanswered
## microphone prompt, S11), so it never runs on the module thread: recordStart and play answer
## at once while the AudioIo starts the device on a thread of its own (audio_io's start job),
## and the pump sees it land, fail (the device's word in ready.capture / ready.playback, and
## recording.error) or stay pending past StartBoundMs (StartSlow). Stop, Discard, close and a
## start past the bound let the start go: the io never waits on it, and the start's own thread
## closes what it opens if it ever returns. The recording's time and its cap count from the
## device's start, since only the device side fills the buffer.
##
## The module has no clock to run on (side-modules.md:66), so nothing here waits; the
## recorder reads one (`clock`) only to time a start against StartBoundMs. `pump` is the voice
## pump that voice_status and coordinate_intents drive: it moves what the device side has
## done since the last call, drains the capture buffer into the incremental Opus encoder (so
## Stop finds at most what arrived since the last pump to encode), notices the device side's
## `capped` (the 60 s cap, which only that side holds) and playback's `done`, and releases the
## device. Start, Stop, Send and Play each pump first, so each decides on what the device side
## has done by now, not on what the last read left. A device is opened only by recordStart or
## play, and with the access policy off any caller can make those calls (§13). Every stream is
## released by the first pump after it ends: the AudioIo is closed (for miniaudio, the device
## and the context), so between streams nothing is open. Nothing here runs without a call, so
## a capture past the cap, or a playback past done, keeps its device open (dropping frames,
## playing silence) until the next voice method or coordinate_intents call (§9, §15). `close` stops whatever runs; the hosted module calls it
## at exit (§9).
##
## The draft lives in this object's memory only: never on disk, never over IPC, lost with the
## process. It belongs to the room it was recorded in (its topic, taken at recordStart): Send
## through another room's session is `room-changed`. Send refuses a draft under 500 ms as
## `too-short` (a recording of nothing included), then an all-zero one as `silent` with the
## platform note (§11: on macOS, Basecamp 0.3.2's logos_host lacks the microphone
## permission), and publishes nothing then. Send signs, records and seals both parts before
## either frame goes out, then hands the two to the transport back to back
## (authorship.publishAuthoredTogether), so the gap between them does not grow with the
## note's length (§10). A note's ts is fixed at its first Send, so a Send retried after a
## transport raised between the frames re-sends the same note id: the log took both parts
## first, so the retry re-seals both on the held path, each as this member first sealed it,
## never a copy another member planted (§4); until then the sender's own fold calls the note
## complete while the room may hold half of it. `too-large` (FrameTooLarge) cannot happen for
## a draft under the cap (§5's worst case fits) and is refused before any frame leaves. On the
## hosted DeliveryTransport a failed send is not seen at all: its publish is fire-and-forget,
## so Send returns {note} and drops the draft, and a part the fleet lost leaves the note
## arriving for the others, with nothing that re-sends it (voice-notes.md §8, §15).
##
## The thread's rows (`rows`, and `messagesJson` as coordinate_messages serves them), the
## room's `lastTs` (coordinate_conversations), the flow (`flowRows`, coordinate_flow), the room
## map (`graphOf`, coordinate_graph), provenance (`provenanceOf`, coordinate_provenance) and
## Play go through one `VoiceMemo` per room, so a part's value is parsed once, not on every
## poll, and a clip is decoded and checked once per pair of standing parts (§6). The hosted
## methods call these procs rather than the folds, so the memo they pass is the one
## voice_live_test drives. Play reads the note from one header pass. A room's memo goes when
## the member leaves it (`forgetRoom`).
##
## `roomProof` is coordinate_proof while voice notes are in the tree: a log proof carries every
## raw value whole, a voice part's half of the clip with it, so it refuses a room whose
## authentic view holds a part the fold stands, and nothing else (§10, §18).
##
## This module codes against AudioIo, never against miniaudio, so voice_live_test runs it on
## SyntheticAudioIo. Which AudioIo the module makes is `voiceIoChoice`'s: MUSTER_VOICE_SOURCE
## or MUSTER_VOICE_SINK give FileAudioIo (the offscreen self-test, S9), MUSTER_VOICE_BACKEND=null
## miniaudio's null device, anything else the platform's own backends.

import std/[json, sequtils, tables]
import ../audio/[audio_io, voice_clip, voice_codec]
import ../crypto/[keystore, curve25519]
import ../log/[log, proof]
import ./session
import ./authorship
import ./voice
from ./contacts import normId
from ./intent_events import DriverFor
from ./intents import LogProvItem, logProvenance
from ./flow import FlowRow, reduceFlow
from ./room_graph import RoomGraph, reduceRoomGraph

const
  ProofRefusal* = "voice-notes-present"
    ## coordinate_proof's refusal for a room whose authentic view holds a part the fold
    ## stands (§10).
  ProofRefusalDetail* = "A log proof carries every event's value whole, and a voice note's " &
                        "value holds its audio, which never leaves the module. Until that is " &
                        "decided, a room with a voice note exports no proof."
  DeviceUnknown* = "unknown"
    ## A device's readiness before anything opened one, and while a start of it is on its
    ## way: never the word an earlier start left.
  DeviceOk* = "ok"
    ## The last open of that device succeeded.
  DraftNote* = "draft"
    ## voice_play's argument for the draft.
  MacMicNote* = "Basecamp 0.3.2 can't use the microphone on macOS yet: it lacks the " &
                "microphone permission."
    ## The platform note on macOS (§11): Basecamp 0.3.2's logos_host carries no audio-input
    ## entitlement and its Info.plist no NSMicrophoneUsageDescription.
  SamplesPerMs = ClipRate div 1000
  StartBoundMs* = 15_000
    ## How long a device start may stay pending before the recorder gives up on it: past it
    ## the recording (or the playback) ends with StartSlow, and the start is let go, its
    ## thread closing the device if it ever starts. A working device starts in well under a
    ## second; the one slow start seen is Core Audio waiting on a microphone prompt (S11, a
    ## test run from a shell), and 15 s leaves a person time to read and answer one, while
    ## "Starting the microphone…" does not stand for longer than someone would wait on it.
    ## Basecamp 0.3.2's logos_host is never prompted (tccd disallows it: no audio-input
    ## entitlement), so there a start does not wait (voice-notes.md §8, §9, §11).

type
  RecState* = enum
    rsIdle = "idle", rsStarting = "starting", rsRecording = "recording", rsDraft = "draft"

  VoiceIoKind* = enum
    vkSystem = "system"         ## the platform's own backends (MiniaudioIo abSystem)
    vkNull = "null"             ## miniaudio's null device (MiniaudioIo abNull)
    vkFile = "file"             ## a WAV source and a raw PCM sink (FileAudioIo)

  VoiceRecorder* = ref object
    io: AudioIo                 ## the device seam; nothing is opened until recordStart or play
    capture, playback: string   ## each device's readiness: DeviceUnknown until one opens
    note: string                ## ready.note: the platform note once a recording came back silent
    state: RecState
    capBuf: AudioBuffer         ## the capture buffer while starting or recording (60 s); else nil
    startedAt: int64            ## the clock when the capture's start was asked for
    enc: ClipEncoder            ## the recording's incremental encoder while recording
    draft: VoiceClip            ## the draft, in state rsDraft
    room: string                ## the topic of the room the recording or draft belongs to
    draftTs: int64              ## the ts its parts carry, fixed at its first Send
    draftTsSet: bool
    recPeak: int                ## the largest |sample| of the recording, or of the draft
    peakSince: int              ## …since the last voice_status read
    capped: bool                ## the recording, or the draft, hit the 60 s cap
    error: string               ## why the last recording ended without a draft
    playBuf: AudioBuffer        ## the decoded clip while playing; else nil
    playNote: string            ## what plays: a note id, or DraftNote; "" when nothing does
    playMs: int
    playStarting: bool          ## its device has not started yet
    playStartedAt: int64        ## the clock when its start was asked for
    memos: Table[string, VoiceMemo]   ## one per room topic (§6)
    clock: AudioClock                 ## ms; times a device start against StartBoundMs

proc platformNote*(os = hostOS): string =
  ## What the module says about a silent recording on `os` (§11), so every UI shows the same
  ## words: on macOS that Basecamp 0.3.2 cannot use the microphone yet; elsewhere nothing.
  if os == "macosx": MacMicNote else: ""

proc voiceIoChoice*(source, sink, backend: string): tuple[kind: VoiceIoKind, source, sink: string] =
  ## Which AudioIo the hosted module makes, from MUSTER_VOICE_SOURCE, MUSTER_VOICE_SINK and
  ## MUSTER_VOICE_BACKEND: a source or a sink gives FileAudioIo over them; else backend
  ## "null" gives miniaudio's null device; anything else the platform's own backends.
  if source.len > 0 or sink.len > 0: (vkFile, source, sink)
  elif backend == "null": (vkNull, "", "")
  else: (vkSystem, "", "")

proc newVoiceRecorder*(io: AudioIo, clock = monotonicClock()): VoiceRecorder =
  ## Opens nothing.
  VoiceRecorder(io: io, capture: DeviceUnknown, playback: DeviceUnknown, clock: clock)

proc refusal(why: string): JsonNode = %*{"error": why}

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# ── the streams ─────────────────────────────────────────────────────────────────────

proc releaseCapture(v: VoiceRecorder) =
  ## Stop the capture and release the device, never waiting on a start in flight (the io lets
  ## it go). The recorder lets go of its buffer only once the stream that wrote it stopped
  ## (ma_device_uninit waits for the device thread); a start let go holds a reference of its
  ## own, so its thread frees the buffer once its start returns.
  discard v.io.stopCapture()
  discard v.io.close()
  freeAudioBuffer(v.capBuf)
  v.capBuf = nil

proc releasePlayback(v: VoiceRecorder) =
  discard v.io.stopPlayback()
  discard v.io.close()
  freeAudioBuffer(v.playBuf)
  v.playBuf = nil
  v.playNote = ""
  v.playMs = 0
  v.playStarting = false

proc drain(v: VoiceRecorder): string =
  ## Encode what the device side captured since the last drain; keep the peak. "" or the
  ## encoder's refusal.
  let p = v.capBuf.takePeak()
  v.recPeak = max(v.recPeak, p)
  v.peakSince = max(v.peakSince, p)
  let pcm = v.capBuf.takeCaptured()
  if pcm.len > 0: v.enc.feed(pcm) else: ""

proc dropRecording(v: VoiceRecorder, why: string) =
  v.releaseCapture()
  v.enc = nil
  v.room = ""
  v.state = rsIdle
  v.error = why

proc finishRecording(v: VoiceRecorder) =
  ## Stop the capture, encode what is left, flush the encoder and hold the draft.
  discard v.io.stopCapture()          # nothing writes the buffer after this
  var why = v.drain()
  if why.len == 0: why = v.enc.finish()
  if why.len > 0:
    v.dropRecording(why)
    return
  v.releaseCapture()
  v.draft = v.enc.clip()
  v.enc = nil
  v.draftTsSet = false
  v.state = rsDraft
  # the microphone note only for a draft Send refuses as silent, never for one too short
  v.note = (if v.recPeak == 0 and v.draft.durationMs >= VoiceMinMs: platformNote() else: "")

proc silentDraft(v: VoiceRecorder): bool =
  ## The draft has samples and every one is exactly zero.
  v.draft.samples > 0 and v.recPeak == 0

proc dropDraft(v: VoiceRecorder) =
  v.draft = VoiceClip()
  v.room = ""
  v.draftTsSet = false
  v.state = rsIdle
  v.capped = false
  v.recPeak = 0

proc startTimedOut(v: VoiceRecorder, at: int64): bool =
  v.clock() - at >= StartBoundMs

proc pump*(v: VoiceRecorder): string =
  ## The voice pump (§8): see a device start land, fail or pass StartBoundMs; move what is
  ## due, drain and encode the capture, end a recording the cap filled, end a playback the
  ## device side has heard to the end, and release the device of every stream that ended.
  ## "" or the device seam's refusal.
  result = v.io.pump()
  if v.state == rsStarting:
    if result.len > 0:                # the start failed: the device's word
      v.capture = result
      v.dropRecording(result)
    elif not v.io.starting:           # the device runs: the recording starts now
      v.state = rsRecording
      v.capture = DeviceOk
    elif v.startTimedOut(v.startedAt):
      v.capture = StartSlow
      v.dropRecording(StartSlow)      # the start is let go; its thread closes what it opens
  if v.state == rsRecording:
    let capped = v.capBuf.capped      # read before the drain: everything up to it is drained
    let why = v.drain()
    if why.len > 0: v.dropRecording(why)
    elif capped:
      v.capped = true
      v.finishRecording()
  if v.playNote.len > 0:
    if result.len > 0:                # the start failed, or the sink refused a write
      v.playback = result
      v.releasePlayback()
    elif v.playStarting:
      if not v.io.starting:
        v.playStarting = false
        v.playback = DeviceOk
      elif v.startTimedOut(v.playStartedAt):
        v.playback = StartSlow
        v.releasePlayback()
    elif v.playBuf.done: v.releasePlayback()

# ── the methods ─────────────────────────────────────────────────────────────────────

proc voiceStatus*(v: VoiceRecorder): JsonNode =
  ## voice_status (§8), after a pump: integers, strings, booleans and null, never a float,
  ## never audio. `peak` is the largest |sample| captured since the last read, and is reset
  ## by reading it.
  discard v.pump()
  let elapsed = case v.state
    of rsRecording: v.capBuf.written div SamplesPerMs
    of rsDraft: v.draft.durationMs
    of rsIdle, rsStarting: 0
  let silent = case v.state
    of rsRecording: v.capBuf.written > 0 and v.recPeak == 0
    of rsDraft: v.silentDraft()
    of rsIdle, rsStarting: false
  let peak = v.peakSince
  v.peakSince = 0
  var playing = newJNull()
  if v.playNote.len > 0:
    playing = %*{"note": v.playNote,
                 "positionMs": (if v.playStarting: 0
                                else: min(v.playBuf.readIndex, v.playBuf.written) div SamplesPerMs),
                 "durationMs": v.playMs, "starting": v.playStarting}
  %*{"ready": {"capture": v.capture, "playback": v.playback, "codec": opusVersion(),
               "note": v.note},
     "recording": {"state": $v.state, "elapsedMs": elapsed, "capMs": VoiceMaxMs, "peak": peak,
                   "capped": v.capped and v.state != rsIdle, "silent": silent, "error": v.error},
     "playing": playing}

proc recordStart*(v: VoiceRecorder, s: CoordinationSession): JsonNode =
  ## voice_record_start: {ok} at once, the device's start on its way (state starting, and
  ## ready.capture unknown, until the pump sees it run, then recording and ok; a start that
  ## fails or passes StartBoundMs ends in idle with recording.error and ready.capture its
  ## word), or {error}: not-joined (no room:
  ## nothing opens), busy (a recording, a playback or a draft held), codec, or the device
  ## seam's own word at once (no-device, no-source, device-start-slow, …), which
  ## ready.capture then says. The recording, and its draft, belong to `s`'s room.
  discard v.pump()                    # a playback heard to its end is not busy
  if s == nil: return refusal("not-joined")
  if v.state != rsIdle or v.playNote.len > 0: return refusal("busy")
  var enc: ClipEncoder
  try: enc = newClipEncoder()
  except VoiceCodecError: return refusal("codec")
  let buf = newAudioBuffer(MaxSamples)
  let rc = v.io.startCapture(buf)
  if rc.len > 0:
    discard v.io.close()
    freeAudioBuffer(buf)
    v.capture = rc
    return refusal(rc)
  v.capBuf = buf
  v.enc = enc
  v.room = s.topic
  v.recPeak = 0
  v.peakSince = 0
  v.capped = false
  v.error = ""
  v.note = ""
  if v.io.starting:                   # the device starts on a thread of its own
    v.state = rsStarting
    v.startedAt = v.clock()
    v.capture = DeviceUnknown         # not known until it lands; never the last start's word
  else:
    v.state = rsRecording
    v.capture = DeviceOk
  %*{"ok": true}

proc draftJson(v: VoiceRecorder): JsonNode =
  %*{"draft": {"durationMs": v.draft.durationMs, "silent": v.silentDraft(), "peak": v.recPeak}}

proc recordStop*(v: VoiceRecorder): JsonNode =
  ## voice_record_stop: {draft: {durationMs, silent, peak}}, the draft the 60 s cap already
  ## made included, or {error}: not-recording; not-started (the device had not started, so
  ## nothing was recorded: its start is let go, never waited on); the word of a start that
  ## failed or was too slow; or why the recording could not be encoded.
  case v.state
  of rsIdle: refusal("not-recording")
  of rsDraft: v.draftJson()
  of rsStarting, rsRecording:
    discard v.pump()                  # what is due: the start may land, the cap may make the draft
    case v.state
    of rsStarting:
      v.dropRecording("")
      refusal("not-started")
    of rsRecording:
      v.finishRecording()
      if v.state == rsDraft: v.draftJson() else: refusal(v.error)
    of rsDraft: v.draftJson()
    of rsIdle: refusal(if v.error.len > 0: v.error else: "not-recording")

proc draftSend*(v: VoiceRecorder, s: CoordinationSession, ks: Keystore, ts: int64): JsonNode =
  ## voice_draft_send: publish the draft as its two author-signed parts at `ts` (fixed at the
  ## first Send of this draft), each padded to one fixed frame by the session (§4). {note},
  ## or {error}, the draft kept on each: no-draft; too-short (under 500 ms, a recording of
  ## nothing included); silent (every sample exactly zero; with `detail`, the platform note);
  ## not-joined; room-changed (`s` is another room than the one the draft was recorded in);
  ## too-large (a part did not fit its frame, FrameTooLarge, before any frame left; never for
  ## a draft under the cap). Both parts are sealed before either frame goes out, then sent
  ## back to back. A transport that raises between the frames raises out of here with the
  ## draft kept, and a retry sends the same note; DeliveryTransport never raises (the module
  ## header).
  discard v.pump()                    # a draft the cap made since the last read is a draft
  if v.state != rsDraft: return refusal("no-draft")
  if v.draft.durationMs < VoiceMinMs: return refusal("too-short")
  if v.silentDraft(): return %*{"error": "silent", "detail": platformNote()}
  if s == nil: return refusal("not-joined")
  if s.topic != v.room: return refusal("room-changed")
  if not v.draftTsSet:
    v.draftTs = ts
    v.draftTsSet = true
  let (nid, parts) = voiceEvents(hexOf(ks.encIdentity().toBytes()), v.draft, v.draftTs)
  try:
    s.publishAuthoredTogether(ks, parts)
  except FrameTooLarge:
    return refusal("too-large")
  if v.playNote == DraftNote: v.releasePlayback()
  v.dropDraft()
  %*{"note": nid}

proc draftDiscard*(v: VoiceRecorder): string =
  ## voice_draft_discard: drop the draft, or a recording in progress or starting (its start
  ## let go, never waited on), and the draft's playback. Always "ok".
  case v.state
  of rsStarting, rsRecording: v.dropRecording("")
  of rsDraft:
    if v.playNote == DraftNote: v.releasePlayback()
  of rsIdle: discard
  v.dropDraft()
  v.error = ""
  "ok"

proc memoFor*(v: VoiceRecorder, s: CoordinationSession): VoiceMemo =
  ## The room's memo of part headers and note verdicts, kept across reads (§6).
  v.memos.mgetOrPut(s.topic, newVoiceMemo())

proc forgetRoom*(v: VoiceRecorder, topic: string) =
  ## Drop the memo of a room this member left (coordinate_leave), so the memos grow with the
  ## rooms joined, never with every room ever read; each one is bounded by its room's log
  ## (voice.VoiceMemo). A room read again starts a fresh one.
  v.memos.del topic

proc memoRooms*(v: VoiceRecorder): int =
  ## How many rooms' memos the recorder holds.
  v.memos.len

proc lastTs*(v: VoiceRecorder, s: CoordinationSession, events: seq[Event]): int64 =
  ## The room's newest row's ts (coordinate_conversations' lastTs): `threadLastTs` over
  ## `events`, the room's authentic view as the method already read it for the room's other
  ## folds, with the room's memo, so a poll parses no part it has read before.
  threadLastTs(events, v.memoFor(s))

proc flowRows*(v: VoiceRecorder, s: CoordinationSession, events: seq[Event],
               driverFor: DriverFor, founders: seq[string]): seq[FlowRow] =
  ## coordinate_flow (polled on the room's 5 s tick): `reduceFlow` over `events`, the room's
  ## authentic view, with the room's memo.
  reduceFlow(events, driverFor, founders, s.sealedIn, v.memoFor(s))

proc graphOf*(v: VoiceRecorder, s: CoordinationSession, events: seq[Event],
              driverFor: DriverFor, founders: seq[string], viewer: string): RoomGraph =
  ## coordinate_graph (polled every 2 s while the room map is open): `reduceRoomGraph` over
  ## `events`, the room's authentic view, with the room's memo, which its provenance, its flow
  ## and each part's content read.
  reduceRoomGraph(events, driverFor, founders, viewer, s.sealedIn, v.memoFor(s))

proc provenanceOf*(v: VoiceRecorder, s: CoordinationSession, events: seq[Event],
                   driverFor: DriverFor): seq[LogProvItem] =
  ## coordinate_provenance: `logProvenance` over `events`, the room's authentic view, with the
  ## room's memo.
  logProvenance(events, driverFor, s.sealedIn, v.memoFor(s))

proc rows*(v: VoiceRecorder, s: CoordinationSession): seq[ThreadRow] =
  ## The room's thread (coordinate_messages): `threadRows` over its authentic view, with the
  ## room's memo.
  threadRows(s.roomEvents(), v.memoFor(s))

proc messagesJson*(v: VoiceRecorder, s: CoordinationSession,
                   aliasOf: proc (author: string): string): JsonNode =
  ## coordinate_messages (§7): the room's rows, oldest first, each `rowJson` ({id, author, ts,
  ## body}, and `voice` on a note's row only) with the author's `alias` (`aliasOf`, the
  ## address book's) and `self` for this member's own rows.
  let me = normId(hexOf(s.selfIdentity().toBytes()))
  result = newJArray()
  for r in v.rows(s):
    var row = rowJson(r)
    row["alias"] = %aliasOf(r.author)
    row["self"] = %(normId(r.author) == me)
    result.add row

proc roomProof*(s: CoordinationSession): JsonNode =
  ## coordinate_proof (M4) while voice notes are in the tree (§10, §18). A log proof carries
  ## every raw event's value whole, because its verifier recomputes each id from it, and a
  ## voice part's value holds its half of the clip. So a room whose authentic view holds a
  ## part the fold stands (`voiceStanding`: a part of a note complete, arriving or broken,
  ## which every member's own note is) exports no proof: {error: "voice-notes-present",
  ## detail}. An entry under `voice/` that is no note's part (unsigned, a forged author, a
  ## malformed value, a squatted note id, a key of the wrong shape) refuses nothing: the log
  ## is append-only, so a refusal for junk would let any one member switch the room's proof
  ## off for good. Such an entry leaves with the proof, as a message's body does; one that
  ## copies a note's bytes leaves with them when this member's view holds none of that note's
  ## parts (§10). Audio never leaves the module; the maintainer decides between naming the
  ## export an exception and a proof form that commits a part by digest. Any other room:
  ## buildProof's JSON over the raw log, from epoch 0 to the current one.
  let events = s.log.allEvents()
  if events.anyIt(isVoiceKey(it.key)) and voiceStanding(s.roomEvents()).len > 0:
    return %*{"error": ProofRefusal, "detail": ProofRefusalDetail}
  var epochTo = 0
  try: epochTo = s.epoch()
  except CatchableError: discard
  buildProof(events, 0, epochTo).toJson()   # the raw log: a proof accounts for every entry, forgeries included (exo-f76)

proc play*(v: VoiceRecorder, s: CoordinationSession, noteId: string): JsonNode =
  ## voice_play: play the draft (`noteId` "draft") or a complete note of the joined room,
  ## decoded whole in the module. {ok} at once, the device's start on its way (playing names
  ## the note, `starting`, and ready.playback unknown, until the pump sees the device run,
  ## then ok; a start that fails or passes StartBoundMs ends it, playing null and
  ## ready.playback its word), or {error}: busy (recording, starting one, or playing),
  ## no-draft, not-joined (a note with no room), unknown-note, incomplete (one part so far),
  ## broken (the fold's verdict, or a clip libopus refuses), codec, or the device seam's own
  ## word at once (no-device, device-start-slow while four earlier starts have not returned,
  ## …), which ready.playback then says.
  discard v.pump()                    # a playback heard to its end is not busy
  if v.state in {rsStarting, rsRecording} or v.playNote.len > 0: return refusal("busy")
  var pcm: seq[int16]
  var durMs: int
  try:
    if noteId == DraftNote:
      if v.state != rsDraft: return refusal("no-draft")
      let d = decodeClip(encodeRecord(v.draft))
      if not d.ok: return refusal("broken")
      pcm = d.pcm
      durMs = v.draft.durationMs
    else:
      if s == nil: return refusal("not-joined")
      # one header pass, through the room's memo: the note's state, and its record when complete
      let n = voiceNoteOf(s.roomEvents(), noteId, v.memoFor(s))
      if not n.found: return refusal("unknown-note")
      case n.note.state
      of vsArriving: return refusal("incomplete")
      of vsBroken: return refusal("broken")
      of vsComplete: discard
      let d = decodeClip(n.record)
      if not d.ok: return refusal("broken")
      pcm = d.pcm
      durMs = n.note.durMs
  except VoiceCodecError:
    return refusal("codec")
  let buf = newAudioBuffer(pcm.len)
  discard buf.loadPlayback(pcm)
  let rc = v.io.startPlayback(buf)
  if rc.len > 0:
    discard v.io.close()
    freeAudioBuffer(buf)
    v.playback = rc
    return refusal(rc)
  v.playBuf = buf
  v.playNote = noteId
  v.playMs = durMs
  v.playStarting = v.io.starting      # the device starts on a thread of its own
  if v.playStarting:
    v.playStartedAt = v.clock()
    v.playback = DeviceUnknown        # not known until it lands; never the last start's word
  else: v.playback = DeviceOk
  %*{"ok": true}

proc playStop*(v: VoiceRecorder): string =
  ## voice_play_stop: stop what plays, and release the device. Always "ok".
  if v.playNote.len > 0: v.releasePlayback()
  "ok"

proc encodedMs*(v: VoiceRecorder): int =
  ## How much of the recording the encoder has taken so far (the draft's length once it is
  ## one): what Stop no longer has to encode (§9).
  if v.enc != nil: v.enc.samples div SamplesPerMs
  elif v.state == rsDraft: v.draft.durationMs
  else: 0

proc close*(v: VoiceRecorder): string =
  ## Stop any recording (dropped) or playback and release the device, before the module
  ## unloads (§9). A start in flight is let go, never waited on: its thread closes what it
  ## opens if its start ever returns (the hosted exit proc then waits a bounded while for
  ## that, `waitStarts`). A draft stays in memory. Idempotent; always "ok".
  if v.state in {rsStarting, rsRecording}: v.dropRecording("")
  if v.playNote.len > 0: v.releasePlayback()
  discard v.io.close()
  "ok"
