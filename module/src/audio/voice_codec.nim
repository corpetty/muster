## The voice codec (docs/design/voice-notes.md §3.1–§3.2): s16 48 kHz mono PCM to the clip
## record and back, through libopus at one fixed set of settings — OPUS_APPLICATION_VOIP,
## SIGNAL_VOICE, hard CBR (VBR 0) at 16 kbps, DTX 0, in-band FEC 0, complexity 5, wideband at
## most. CBR makes a clip's size a pure function of its length (RFC 6562 §5, RFC 7587
## §3.1.2), which is what lets every note be padded to one fixed frame size (§4, §5).
##
## Encoding is incremental, so the module thread encodes a recording 20 ms at a time as the
## voice pump drains it (§9): `feed` encodes every whole frame and holds a partial one,
## `finish` flushes the encoder through its lookahead, `clip` hands back the record. A packet
## shorter than the CBR size is brought up to it with `opus_packet_pad` (RFC 7587 §3.1.2:
## Opus's own padding); a longer one means CBR did not hold, and the encoder refuses it.
## Every setting is read back after it is set, so a binding that silently set the wrong
## value (opus.nim) refuses to encode rather than make clips of the wrong size.
##
## Decoding reads bytes another member wrote, inside the core: `decodeClip` checks the record
## with voice_clip first, then requires every packet to carry 20 ms of audio, 960 samples as
## `opus_packet_get_nb_samples` counts them (it reads only the TOC byte, and a code-3
## packet's frame count; several frames that add up to 20 ms pass, and opus_decode takes any
## packet of 960 samples or fewer), and only then lets libopus decode. A refusal is a value
## naming why. Audio plaintext stays in this process: nothing here writes a file or returns
## PCM across IPC (§7, §9).

import ./opus
import ./voice_clip

const VoiceComplexity* = 5

type
  VoiceCodecError* = object of CatchableError
    ## libopus refused its own setup (out of memory, a setting that did not hold): never
    ## the result of a room input, which is refused as a value instead.

  EncoderHandle = object
    p: ptr OpusEncoder

  ClipEncoder* = ref object
    h: EncoderHandle
    preskip: int                 ## the encoder's lookahead, the record's preskip
    samples: int                 ## PCM samples taken so far
    pending: seq[int16]          ## a partial frame, waiting for more PCM or `finish`
    packets: seq[seq[byte]]
    padded: int                  ## packets opus_packet_pad brought up to PacketBytes
    finished: bool
    failed: string               ## the encoder's own failure; every later call returns it

proc `=destroy`(h: EncoderHandle) =
  if h.p != nil: opus_encoder_destroy(h.p)
proc `=copy`(a: var EncoderHandle, b: EncoderHandle) {.error.}
proc `=dup`(b: EncoderHandle): EncoderHandle {.error.}

const Settings = [
  # (SET request, GET request, value): set in this order, then every one read back
  (OPUS_SET_SIGNAL_REQUEST, OPUS_GET_SIGNAL_REQUEST, OPUS_SIGNAL_VOICE),
  (OPUS_SET_VBR_REQUEST, OPUS_GET_VBR_REQUEST, 0.cint),
  (OPUS_SET_BITRATE_REQUEST, OPUS_GET_BITRATE_REQUEST, VoiceBitrate.cint),
  (OPUS_SET_COMPLEXITY_REQUEST, OPUS_GET_COMPLEXITY_REQUEST, VoiceComplexity.cint),
  (OPUS_SET_INBAND_FEC_REQUEST, OPUS_GET_INBAND_FEC_REQUEST, 0.cint),
  (OPUS_SET_DTX_REQUEST, OPUS_GET_DTX_REQUEST, 0.cint),
  (OPUS_SET_MAX_BANDWIDTH_REQUEST, OPUS_GET_MAX_BANDWIDTH_REQUEST, OPUS_BANDWIDTH_WIDEBAND)]

proc setCtl(st: ptr OpusEncoder, request, value: cint) =
  let rc = opus_encoder_ctl(st, request, value)
  if rc != OPUS_OK:
    raise newException(VoiceCodecError, "opus ctl " & $request & ": " & $opus_strerror(rc))

proc getCtl(st: ptr OpusEncoder, request: cint): int =
  var v: cint
  let rc = opus_encoder_ctl(st, request, addr v)
  if rc != OPUS_OK:
    raise newException(VoiceCodecError, "opus ctl " & $request & ": " & $opus_strerror(rc))
  int(v)

proc opusVersion*(): string = $opus_get_version_string()

proc newClipEncoder*(): ClipEncoder =
  ## An encoder at the fixed settings, each read back. Raises VoiceCodecError when libopus
  ## cannot make one, or a setting does not read back as set.
  var err: cint
  let st = opus_encoder_create(ClipRate.int32, ClipChannels.cint, OPUS_APPLICATION_VOIP, addr err)
  if st == nil or err != OPUS_OK:
    raise newException(VoiceCodecError, "opus_encoder_create: " & $opus_strerror(err))
  result = ClipEncoder(h: EncoderHandle(p: st))   # owns st: a raise below frees it
  for (setReq, _, value) in Settings: setCtl(st, setReq, value)
  for (_, getReq, value) in Settings:
    let got = getCtl(st, getReq)
    if got != int(value):
      raise newException(VoiceCodecError,
        "opus ctl " & $getReq & " read back " & $got & ", want " & $value)
  result.preskip = getCtl(st, OPUS_GET_LOOKAHEAD_REQUEST)
  if result.preskip notin 0 .. MaxPreskip:
    raise newException(VoiceCodecError, "opus lookahead " & $result.preskip & " is a frame or more")

proc readBack*(e: ClipEncoder, getRequest: cint): int =
  ## A setting as libopus holds it (an OPUS_GET_*_REQUEST).
  getCtl(e.h.p, getRequest)

proc preskip*(e: ClipEncoder): int = e.preskip
proc samples*(e: ClipEncoder): int = e.samples
proc paddedPackets*(e: ClipEncoder): int = e.padded

proc encodeFrame(e: ClipEncoder, frame: ptr int16): string =
  var buf: array[MaxPacketBytes, byte]
  let n = opus_encode(e.h.p, frame, ClipFrame.cint, addr buf[0], MaxPacketBytes.int32)
  if n < 1: return "encode"
  if n > PacketBytes: return "not-cbr"
  if n < PacketBytes:
    if opus_packet_pad(addr buf[0], n, PacketBytes.int32) != OPUS_OK: return "encode"
    inc e.padded
  e.packets.add buf[0 ..< PacketBytes]
  ""

proc feed*(e: ClipEncoder, pcm: openArray[int16]): string =
  ## Encode `pcm`, 20 ms at a time; a partial frame waits for the next feed or `finish`.
  ## "" or a refusal: "finished"; "too-long" past the 60 s cap, taking none of `pcm`; or the
  ## encoder's own failure ("encode", "not-cbr"), which every later call returns.
  if e.failed.len > 0: return e.failed
  if e.finished: return "finished"
  if pcm.len > MaxSamples - e.samples: return "too-long"
  e.samples += pcm.len
  var i = 0
  if e.pending.len > 0:
    i = min(ClipFrame - e.pending.len, pcm.len)
    e.pending.add pcm.toOpenArray(0, i - 1)
    if e.pending.len == ClipFrame:
      e.failed = e.encodeFrame(addr e.pending[0])
      e.pending.setLen(0)
  while e.failed.len == 0 and pcm.len - i >= ClipFrame:
    e.failed = e.encodeFrame(addr pcm[i])
    i += ClipFrame
  if e.failed.len == 0: e.pending.add pcm.toOpenArray(i, pcm.high)
  e.failed

proc finish*(e: ClipEncoder): string =
  ## Flush the encoder through its lookahead: zeros up to ceil((samples + preskip) / 960)
  ## frames in all, so the decoder returns every sample fed once it trims the preskip (§3.2).
  if e.failed.len > 0: return e.failed
  if e.finished: return ""
  var tail = move e.pending
  tail.setLen((packetCount(e.samples, e.preskip) - e.packets.len) * ClipFrame)   # zero-filled
  var i = 0
  while e.failed.len == 0 and i < tail.len:
    e.failed = e.encodeFrame(addr tail[i])
    i += ClipFrame
  e.finished = e.failed.len == 0
  e.failed

proc clip*(e: ClipEncoder): VoiceClip =
  ## The finished clip. Raises VoiceCodecError before `finish`, or after a failure.
  if not e.finished: raise newException(VoiceCodecError, "clip() before finish(): " & e.failed)
  VoiceClip(preskip: e.preskip, samples: e.samples, packets: e.packets)

proc encodeClip*(pcm: openArray[int16]): tuple[ok: bool, clip: VoiceClip, why: string] =
  ## A whole recording in one call: feed, finish, clip.
  let e = newClipEncoder()
  var why = e.feed(pcm)
  if why.len == 0: why = e.finish()
  if why.len > 0: return (false, VoiceClip(), why)
  (true, e.clip(), "")

proc decodeClip*(record: openArray[byte]): tuple[ok: bool, pcm: seq[int16], why: string] =
  ## The PCM a clip record carries, exactly `samples` long, or a refusal: any word
  ## voice_clip.decodeRecord refuses with, "packet-frame" for a packet whose TOC does not
  ## make 20 ms of audio (960 samples, opus_packet_get_nb_samples), "decode" when libopus
  ## refuses a packet.
  let r = decodeRecord(record)
  if not r.ok: return (false, @[], r.why)
  let c = r.clip
  for p in c.packets:                                # each 1..1275 bytes (decodeRecord)
    if opus_packet_get_nb_samples(addr p[0], int32(p.len), ClipRate.int32) != ClipFrame:
      return (false, @[], "packet-frame")
  var err: cint
  let st = opus_decoder_create(ClipRate.int32, ClipChannels.cint, addr err)
  if st == nil or err != OPUS_OK:
    raise newException(VoiceCodecError, "opus_decoder_create: " & $opus_strerror(err))
  defer: opus_decoder_destroy(st)
  var pcm = newSeq[int16](c.packets.len * ClipFrame)
  for k, p in c.packets:
    if opus_decode(st, addr p[0], int32(p.len), addr pcm[k * ClipFrame], ClipFrame.cint, 0) != ClipFrame:
      return (false, @[], "decode")
  (true, pcm[c.preskip ..< c.preskip + c.samples], "")
