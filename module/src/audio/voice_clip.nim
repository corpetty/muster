## The clip record of a voice note (docs/design/voice-notes.md §3.2): a note's Opus packets in
## one CDE record, built with src/dcbor (invariant 5), with no Ogg — no CRCs, no random serial
## numbers, no libopusenc. A CDE array of byte strings is length-prefixed framing for free.
##
##   { v: 1, codec: "opus", rate: 48000, ch: 1, frame: 960, br: 16000,
##     preskip: <the encoder's lookahead>, samples: <exact count>, packets: [ * bstr ] }
##
## `preskip` and `samples` let the decoder trim the lookahead and the zero-filled last frame.
## Pure: this module links no codec, so the room's fold (§6) checks a clip's structure without
## libopus, and libopus decodes room-supplied bytes only after `decodeRecord` accepted them
## (voice_codec.nim). A refusal is an error value, never a raise and never a Defect: every
## integer is bounded as a uint64 before it is used as an int.

import ../dcbor/dcbor

const
  ClipVersion* = 1
  ClipCodec* = "opus"
  ClipRate* = 48_000            ## Hz; mono, s16 PCM in and out
  ClipChannels* = 1
  ClipFrame* = 960              ## samples per packet: 20 ms at 48 kHz
  VoiceBitrate* = 16_000        ## b/s, hard CBR (§3.1)
  VoiceMaxMs* = 60_000          ## the cap the device callback enforces (§3.4, §9)
  MaxSamples* = VoiceMaxMs * (ClipRate div 1000)    ## 2,880,000
  PacketBytes* = VoiceBitrate * 20 div 8000         ## 40: one CBR packet of 20 ms
  MaxPacketBytes* = 1275        ## the largest Opus frame (RFC 6716 §3.2.1). A single-frame
                                ## packet is its TOC byte plus the frame, so up to 1,276
                                ## (opus.h, opus_repacketizer_out_range), but §3.2 refuses a
                                ## packet over 1,275; this encoder's are 40
  MaxPreskip* = ClipFrame - 1   ## a lookahead under one frame: libopus's is 312 at 48 kHz
  RecordFields = ["v", "codec", "rate", "ch", "frame", "br", "preskip", "samples", "packets"]

type
  VoiceClip* = object
    preskip*: int                ## samples of encoder lookahead at the head of the decode
    samples*: int                ## the recording's exact length in samples
    packets*: seq[seq[byte]]     ## one Opus packet per 20 ms frame

proc packetCount*(samples, preskip: int): int =
  ## How many 20 ms packets carry `samples` once the encoder is flushed through its
  ## lookahead: ceil((samples + preskip) / 960). A record with any other count is refused.
  (samples + preskip + ClipFrame - 1) div ClipFrame

proc durationMs*(c: VoiceClip): int = c.samples div (ClipRate div 1000)

proc checkClip*(c: VoiceClip): string =
  ## "" when `c` is a clip this version reads, else the word naming what is wrong.
  if c.preskip < 0 or c.preskip > MaxPreskip: return "preskip"
  if c.samples < 0 or c.samples > MaxSamples: return "samples"
  for p in c.packets:
    if p.len < 1 or p.len > MaxPacketBytes: return "packet-length"
  if c.packets.len != packetCount(c.samples, c.preskip): return "packet-count"
  ""

proc recordValue(c: VoiceClip): CborValue =
  var packets = newSeq[CborValue](c.packets.len)
  for i, p in c.packets: packets[i] = cbBytes(p)
  cbMap(@[
    (cbText("v"), cbUint(ClipVersion)), (cbText("codec"), cbText(ClipCodec)),
    (cbText("rate"), cbUint(ClipRate)), (cbText("ch"), cbUint(ClipChannels)),
    (cbText("frame"), cbUint(ClipFrame)), (cbText("br"), cbUint(VoiceBitrate)),
    (cbText("preskip"), cbUint(uint64(c.preskip))), (cbText("samples"), cbUint(uint64(c.samples))),
    (cbText("packets"), cbArray(packets))])

proc encodeRecord*(c: VoiceClip): seq[byte] =
  ## The clip's one CDE encoding. Raises ValueError on a clip `decodeRecord` would refuse,
  ## so muster never writes a record a member's client cannot read.
  let bad = checkClip(c)
  if bad.len > 0: raise newException(ValueError, "not a valid voice clip: " & bad)
  encode(recordValue(c))

proc isUint(v: CborValue, want: uint64): bool = v.kind == ckUint and v.u == want

proc decodeRecord*(b: openArray[byte]): tuple[ok: bool, clip: VoiceClip, why: string] =
  ## Read a clip record strictly: the canonical CDE of exactly the nine fields, this
  ## version's fixed codec settings, packets of 1..1275 bytes, at most 60 s of samples, and
  ## ceil((samples + preskip) / 960) packets. Anything else is refused by name.
  var m: CborValue
  try: m = decode(@b)
  except CborError: return (false, VoiceClip(), "not-a-record")
  if m.kind != ckMap: return (false, VoiceClip(), "not-a-record")
  if m.pairs.len != RecordFields.len: return (false, VoiceClip(), "fields")
  for (k, _) in m.pairs:
    if k.kind != ckText or k.t notin RecordFields: return (false, VoiceClip(), "fields")
  # every field is present: nine distinct text keys (CDE refuses duplicates), each a field
  if not m.field("v").isUint(ClipVersion): return (false, VoiceClip(), "version")
  let codec = m.field("codec")
  if codec.kind != ckText or codec.t != ClipCodec: return (false, VoiceClip(), "codec")
  if not m.field("rate").isUint(ClipRate): return (false, VoiceClip(), "rate")
  if not m.field("ch").isUint(ClipChannels): return (false, VoiceClip(), "channels")
  if not m.field("frame").isUint(ClipFrame): return (false, VoiceClip(), "frame")
  if not m.field("br").isUint(VoiceBitrate): return (false, VoiceClip(), "bitrate")
  let preskip = m.field("preskip")
  if preskip.kind != ckUint or preskip.u > uint64(MaxPreskip): return (false, VoiceClip(), "preskip")
  let samples = m.field("samples")
  if samples.kind != ckUint or samples.u > uint64(MaxSamples): return (false, VoiceClip(), "samples")
  let packets = m.field("packets")
  if packets.kind != ckArray: return (false, VoiceClip(), "packets")
  var c = VoiceClip(preskip: int(preskip.u), samples: int(samples.u),
                    packets: newSeq[seq[byte]](packets.arr.len))
  for i, p in packets.arr:
    if p.kind != ckBytes: return (false, VoiceClip(), "packets")
    c.packets[i] = p.b
  let bad = checkClip(c)
  if bad.len > 0: return (false, VoiceClip(), bad)
  (true, c, "")

proc headBytes(n: int): int =
  ## The length of a CBOR head carrying argument `n` (shortest form, any major type).
  if n < 24: 1 elif n <= 0xFF: 2 elif n <= 0xFFFF: 3 elif n <= 0xFFFF_FFFF: 5 else: 9

proc maxClipBytes*(ms: int): int =
  ## The largest record a clip of `ms` milliseconds encodes to, at any preskip this version
  ## reads: MaxPreskip gives the most packets and the widest preskip head. §5's budget: 60 s
  ## is 3,001 packets of 42 bytes (a 2-byte bstr head on 40 bytes) plus a 77-byte header.
  ## Raises ValueError for `ms` outside 0..VoiceMaxMs: no clip has that length, and a
  ## negative one would wrap through cbUint into a budget that sizes nothing.
  if ms < 0 or ms > VoiceMaxMs:
    raise newException(ValueError, "no voice clip is " & $ms & " ms long (0.." & $VoiceMaxMs & ")")
  let samples = ms * (ClipRate div 1000)
  let packets = packetCount(samples, MaxPreskip)
  # the header is every byte but the packets array: encode it with no packets (a 1-byte
  # array head), then add the real array's head and its packets
  let header = encode(recordValue(VoiceClip(preskip: MaxPreskip, samples: samples))).len - 1
  header + headBytes(packets) + packets * (headBytes(PacketBytes) + PacketBytes)
