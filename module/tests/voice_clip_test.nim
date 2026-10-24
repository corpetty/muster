## The voice clip record (docs/design/voice-notes.md §3.2, §5): the CDE record a note's Opus
## packets travel in, read back strictly. Pure Nim, no libopus: the room's fold checks a
## clip's structure without linking a codec (§6), and libopus decodes room-supplied bytes
## only after this check passes, so every refusal here is a value, never a raise.

import std/[random, sequtils, strutils]
import ../src/audio/voice_clip
import ../src/dcbor/dcbor

proc fromHex(s: string): seq[byte] =
  let h = s.replace(" ", "")
  for i in countup(0, h.len - 2, 2): result.add byte(parseHexInt(h[i .. i + 1]))

proc clipOf(samples: int, preskip = 312, size = PacketBytes): VoiceClip =
  VoiceClip(preskip: preskip, samples: samples,
            packets: newSeqWith(packetCount(samples, preskip), newSeqWith(size, 0x5a'u8)))

proc baseFields(c: VoiceClip): seq[(string, CborValue)] =
  @[("v", cbUint(1)), ("codec", cbText("opus")), ("rate", cbUint(48000)), ("ch", cbUint(1)),
    ("frame", cbUint(960)), ("br", cbUint(16000)), ("preskip", cbUint(uint64(c.preskip))),
    ("samples", cbUint(uint64(c.samples))),
    ("packets", cbArray(c.packets.mapIt(cbBytes(it))))]

proc recordWith(c: VoiceClip, swap: seq[(string, CborValue)] = @[],
                drop: seq[string] = @[], add: seq[(string, CborValue)] = @[]): seq[byte] =
  ## A record built by hand (encodeRecord refuses an invalid clip): the base fields of `c`,
  ## with some replaced, dropped or added, in canonical CDE.
  var pairs: seq[(CborValue, CborValue)]
  for (k, v) in baseFields(c):
    if k in drop: continue
    var val = v
    for (sk, sv) in swap:
      if sk == k: val = sv
    pairs.add (cbText(k), val)
  for (k, v) in add: pairs.add (cbText(k), v)
  encode(cbMap(pairs))

proc refused(b: seq[byte], why: string): bool =
  let r = decodeRecord(b)
  doAssert not r.ok, "accepted what should be refused for " & why
  doAssert r.why == why, "refused for '" & r.why & "', wanted '" & why & "'"
  true

# 1. Round trip: a record decodes to the clip it was built from, and re-encodes to the same
#    bytes. One small record is held to hand-computed bytes (RFC 8949 §4.2.3 key order, the
#    shortest integers), so the field names, their order and the integer widths are pinned.
block:
  for samples in [0, 1, 959, 960, 24_000, 1_234_567, MaxSamples]:
    for preskip in [0, 312, MaxPreskip]:
      let c = clipOf(samples, preskip)
      let b = encodeRecord(c)
      let r = decodeRecord(b)
      doAssert r.ok, $samples & "/" & $preskip & ": " & r.why
      doAssert r.clip == c
      doAssert encodeRecord(r.clip) == b, "a re-encode is byte-identical"
      doAssert durationMs(r.clip) == samples div 48
  let golden = VoiceClip(preskip: 0, samples: 960, packets: @[@[0xf8'u8]])
  doAssert encodeRecord(golden) == fromHex(
    "a9" &
    "6176 01" &                               # "v": 1
    "626272 193e80" &                         # "br": 16000
    "626368 01" &                             # "ch": 1
    "6472617465 19bb80" &                     # "rate": 48000
    "65636f646563 646f707573" &               # "codec": "opus"
    "656672616d65 1903c0" &                   # "frame": 960
    "677061636b657473 8141f8" &               # "packets": [h'f8']
    "67707265736b6970 00" &                   # "preskip": 0
    "6773616d706c6573 1903c0"),               # "samples": 960
    "the golden record"
echo "1. round trip, byte-identical re-encode, golden bytes OK"

# 2. Refusals, each an error value naming what is wrong.
block:
  let c = clipOf(48_000)
  doAssert decodeRecord(recordWith(c)).ok, "the hand-built base record is valid"
  # the fixed codec settings
  doAssert refused(recordWith(c, swap = @[("v", cbUint(2))]), "version")
  doAssert refused(recordWith(c, swap = @[("codec", cbText("vorbis"))]), "codec")
  doAssert refused(recordWith(c, swap = @[("codec", cbUint(1))]), "codec")
  doAssert refused(recordWith(c, swap = @[("rate", cbUint(44100))]), "rate")
  doAssert refused(recordWith(c, swap = @[("ch", cbUint(2))]), "channels")
  doAssert refused(recordWith(c, swap = @[("frame", cbUint(480))]), "frame")
  doAssert refused(recordWith(c, swap = @[("br", cbUint(24000))]), "bitrate")
  # packet lengths: 1..1275 (opus.h: one frame is at most 1275 bytes)
  block:
    var z = c
    z.packets[3] = @[]
    doAssert refused(recordWith(z), "packet-length")
    var big = c
    big.packets[0] = newSeq[byte](MaxPacketBytes + 1)
    doAssert refused(recordWith(big), "packet-length")
    var edge = c
    edge.packets[0] = newSeq[byte](MaxPacketBytes)
    edge.packets[1] = @[0x01'u8]
    doAssert decodeRecord(recordWith(edge)).ok, "1 and 1275 bytes are both a packet"
  # samples over the 60 s cap, the packet count held to its own rule
  let over = clipOf(MaxSamples + 1)
  doAssert refused(recordWith(over), "samples")
  doAssert refused(recordWith(c, swap = @[("samples", cbInt(-1))]), "samples")
  doAssert refused(recordWith(c, swap = @[("preskip", cbUint(uint64(ClipFrame)))]), "preskip")
  doAssert refused(recordWith(c, swap = @[("preskip", cbUint(high(uint64)))]), "preskip")
  doAssert refused(recordWith(c, swap = @[("samples", cbUint(high(uint64)))]), "samples")
  block:
    var short = c
    short.packets.setLen(c.packets.len - 1)
    doAssert refused(recordWith(short), "packet-count")
    var long = c
    long.packets.add c.packets[0]
    doAssert refused(recordWith(long), "packet-count")
  # the shape: a map of exactly these nine fields, packets an array of byte strings
  doAssert refused(recordWith(c, drop = @["preskip"]), "fields")
  doAssert refused(recordWith(c, add = @[("x", cbUint(0))]), "fields")
  doAssert refused(recordWith(c, swap = @[("samples", cbText("48000"))]), "samples")
  doAssert refused(recordWith(c, swap = @[("packets", cbBytes(@[1'u8]))]), "packets")
  doAssert refused(recordWith(c, swap = @[("packets",
    cbArray(c.packets.mapIt(cbBytes(it)) & @[cbText("x")]))]), "packets")
  # not a record at all: not CBOR, trailing bytes, not canonical, not a map
  doAssert refused(@[], "not-a-record")
  doAssert refused(recordWith(c) & @[0x00'u8], "not-a-record")
  doAssert refused(encode(cbArray(@[cbUint(1)])), "not-a-record")
  doAssert refused(encode(cbUint(7)), "not-a-record")
  block:
    var noncanon = recordWith(c)                        # a9 61 76 01 …: "v": 1 first
    doAssert noncanon[0 .. 3] == @[0xa9'u8, 0x61, 0x76, 0x01]
    noncanon[3] = 0x18
    noncanon.insert(0x01'u8, 4)                         # "v": 1 in two bytes, not one
    doAssert refused(noncanon, "not-a-record")
  # encodeRecord never writes a record decodeRecord would refuse
  doAssert (try: (discard encodeRecord(over); false) except ValueError: true)
  # fuzz: every mutation of a valid record is refused or round-trips, and nothing raises
  var rng = initRand(0x701ce)
  let good = encodeRecord(clipOf(9_600, 312))
  for trial in 0 ..< 3000:
    var b = good
    case trial mod 3
    of 0: b[rng.rand(b.high)] = byte(rng.rand(255))
    of 1: b.setLen(rng.rand(b.high))
    else: b.insert(byte(rng.rand(255)), rng.rand(b.len))
    let r = decodeRecord(b)
    if r.ok: doAssert encodeRecord(r.clip) == b, "an accepted mutation round-trips"
echo "2. refusals: codec settings, packet lengths, samples, packet count, shape, fuzz OK"

# 3. The size budget (§5): the largest record a clip of a given length can make. 60 s is
#    ceil((2,880,000 + preskip) / 960) = 3,001 packets of 42 bytes plus a 77-byte header;
#    500 ms is 26 packets, 1,166 bytes.
block:
  doAssert maxClipBytes(VoiceMaxMs) == 126_119, $maxClipBytes(VoiceMaxMs)
  doAssert maxClipBytes(500) == 1_166, $maxClipBytes(500)
  for ms in [0, 20, 500, 1_000, 30_000, VoiceMaxMs]:
    let worst = encodeRecord(clipOf(ms * 48, MaxPreskip)).len
    doAssert maxClipBytes(ms) == worst, $ms & ": " & $maxClipBytes(ms) & " vs " & $worst
    for preskip in [0, 1, 24, 312]:
      doAssert encodeRecord(clipOf(ms * 48, preskip)).len <= maxClipBytes(ms)
  # a length no clip can have is refused, never sized: a negative ms once wrapped through
  # cbUint to a 121-byte budget, and one past the cap would size a clip decodeRecord refuses
  for ms in [-1, -20, low(int), VoiceMaxMs + 1, high(int)]:
    let r = (try: $maxClipBytes(ms) except ValueError: "refused")
    doAssert r == "refused", "maxClipBytes(" & $ms & ") = " & r
echo "3. maxClipBytes(60 s) = 126,119, (500 ms) = 1,166; a negative or over-cap length refused OK"

echo "voice_clip_test: all OK"
