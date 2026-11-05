## The voice codec (docs/design/voice-notes.md §3.1–§3.2): libopus at the fixed settings —
## 48 kHz mono, 20 ms frames, hard CBR at 16 kbps, DTX and FEC off — the clip record it
## fills, and a decode that checks the record without libopus, then reads each packet's
## length in samples off its first bytes (opus_packet_get_nb_samples), before libopus
## decodes any of it. Synthetic PCM only: no microphone, no device. Needs libopus
## (run-suite.sh links the builder pin's on macOS, the one the .lgx ships, and nixpkgs' on
## Linux); §1 prints the version opus_get_version_string reports.

import std/[math, random]
import ../src/audio/[opus, voice_clip, voice_codec]

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

proc correlation(a, b: openArray[int16], lag: int): float =
  ## Normalised correlation of a[i] with b[i + lag], over the samples both cover.
  var ab, aa, bb = 0.0
  for i in max(0, -lag) ..< min(a.len, b.len - lag):
    ab += float(a[i]) * float(b[i + lag])
    aa += float(a[i]) * float(a[i])
    bb += float(b[i + lag]) * float(b[i + lag])
  ab / sqrt(aa * bb)

let seconds3 = 3 * ClipRate
let tone = sine(1000.0, seconds3)
let silence = newSeq[int16](seconds3)
var mixed = tone
for i in 0 ..< ClipRate: mixed[i] = 0                  # the first second silent

# 1. Every setting reads back as set. The ctl functions are C variadics; bound fixed-arity,
#    Apple arm64 passes the value in a register where libopus's va_arg reads the stack, so
#    what libopus gets is whatever is there. In the prototype (§3.1) SET_BITRATE(16000)
#    returned OPUS_OK and read back 300000; in this build a fixed-arity SET failed with
#    OPUS_BAD_ARG instead. Either way this goes red. CBR's packet size, and so the clip's
#    fixed size, follows from the bitrate.
block:
  let e = newClipEncoder()
  doAssert e.readBack(OPUS_GET_BITRATE_REQUEST) == VoiceBitrate, $e.readBack(OPUS_GET_BITRATE_REQUEST)
  doAssert e.readBack(OPUS_GET_VBR_REQUEST) == 0, "hard CBR"
  doAssert e.readBack(OPUS_GET_DTX_REQUEST) == 0
  doAssert e.readBack(OPUS_GET_INBAND_FEC_REQUEST) == 0
  doAssert e.readBack(OPUS_GET_COMPLEXITY_REQUEST) == 5
  doAssert e.readBack(OPUS_GET_SIGNAL_REQUEST) == OPUS_SIGNAL_VOICE
  doAssert e.readBack(OPUS_GET_MAX_BANDWIDTH_REQUEST) == OPUS_BANDWIDTH_WIDEBAND
  doAssert e.readBack(OPUS_GET_LOOKAHEAD_REQUEST) == e.preskip
  doAssert e.preskip in 0 .. MaxPreskip, $e.preskip
  echo "   ", opusVersion(), ", preskip ", e.preskip      # opus_get_version_string
echo "1. ctl read-back: bitrate 16000, VBR 0, DTX 0, FEC 0, complexity 5, voice, wideband OK"

# 2. Hard CBR: every packet is exactly 40 bytes for a tone, for silence and for the two mixed,
#    straight from the encoder (none needed opus_packet_pad). Fed in ragged chunks, the
#    encoder makes the same packets as in one piece.
block:
  for (name, pcm) in [("tone", tone), ("silence", silence), ("mixed", mixed)]:
    let e = newClipEncoder()
    doAssert e.feed(pcm) == ""
    doAssert e.finish() == ""
    let c = e.clip()
    doAssert c.samples == pcm.len
    doAssert c.packets.len == packetCount(pcm.len, e.preskip), name
    for p in c.packets: doAssert p.len == PacketBytes, name & ": a " & $p.len & "-byte packet"
    doAssert e.paddedPackets == 0, name & ": " & $e.paddedPackets & " packets needed padding"
    let chunked = newClipEncoder()
    var i = 0
    for n in [1, 7, 959, 961, 4_800, 1, 960, 23_999]:
      doAssert chunked.feed(pcm[i ..< i + n]) == ""
      i += n
    doAssert chunked.feed(pcm[i .. ^1]) == ""
    doAssert chunked.finish() == ""
    doAssert chunked.clip() == c, name & ": chunked feeding changed the packets"
    doAssert chunked.feed(pcm[0 ..< 960]) == "finished"
echo "2. every packet 40 B for tone, silence and mixed; chunked == whole OK"

# 3. Encode then decode a 1 kHz sine: exactly the samples that went in come out once the
#    preskip is trimmed, still in phase (a trim off by the 312-sample preskip lands 6.5
#    periods out, in antiphase), and the tone keeps its power against an off-tone band.
block:
  let r = encodeClip(tone)
  doAssert r.ok, r.why
  let d = decodeClip(encodeRecord(r.clip))
  doAssert d.ok, d.why
  doAssert d.pcm.len == tone.len, $d.pcm.len & " samples back for " & $tone.len
  let body = d.pcm[ClipRate div 10 .. ^1]              # past the encoder's warm-up
  let p1k = goertzel(body, 1000.0)
  let p3k = goertzel(body, 3100.0)
  doAssert p1k >= 100.0 * p3k, "P(1 kHz) " & $p1k & " vs P(3.1 kHz) " & $p3k
  let c0 = correlation(tone, d.pcm, 0)
  doAssert c0 > 0.5, "in phase at lag 0: " & $c0
  doAssert c0 > correlation(tone, d.pcm, 24) and c0 > correlation(tone, d.pcm, -24)
  echo "   P(1k)/P(3.1k) = ", p1k / p3k, ", correlation at lag 0 = ", c0
echo "3. 1 kHz round trip: exact length, in phase, P(1k) >= 100 x P(3.1k) OK"

# 4. Decode refuses, as a value: a packet that does not carry 20 ms of audio (960 samples,
#    as opus_packet_get_nb_samples reads them off its TOC byte, and a code-3 packet's frame
#    count: a 10 ms packet, a two-frame 40 ms one), bytes that are not a record. Random
#    packet bytes inside a valid record never crash libopus: they are refused, or decode to
#    exactly the clip's length.
block:
  var err: cint
  let st = opus_encoder_create(ClipRate.int32, ClipChannels.cint, OPUS_APPLICATION_VOIP, addr err)
  doAssert err == OPUS_OK
  var pcm10 = sine(1000.0, 480)
  var buf: array[MaxPacketBytes, byte]
  let n = opus_encode(st, addr pcm10[0], 480, addr buf[0], MaxPacketBytes.int32)
  opus_encoder_destroy(st)
  doAssert n > 0
  let ten = @(buf[0 ..< n])
  doAssert opus_packet_get_nb_samples(unsafeAddr ten[0], ten.len.int32, ClipRate.int32) == 480
  let good = encodeClip(sine(1000.0, 4_800)).clip
  var c10 = good
  c10.packets[2] = ten
  let r10 = decodeClip(encodeRecord(c10))
  doAssert not r10.ok and r10.why == "packet-frame", r10.why
  var c40 = good
  c40.packets[0] = @[0x49'u8, 0x00, 0x00]                # TOC: SILK WB 20 ms, code 1 (two frames)
  let r40 = decodeClip(encodeRecord(c40))
  doAssert not r40.ok and r40.why == "packet-frame", r40.why
  var rng = initRand(0xc0dec)
  for trial in 0 ..< 200:
    var junk = newSeq[byte](rng.rand(1 .. 300))
    for b in junk.mitems: b = byte(rng.rand(255))
    let rj = decodeClip(junk)
    doAssert not rj.ok, "random bytes are not a record"
    # built fresh: `mitems` over a copy of `good` crashes nim 2.2.4's top-level code (SIGSEGV
    # with no libopus in it), so the packets are made, not overwritten in place
    var cr = VoiceClip(preskip: good.preskip, samples: good.samples)
    for _ in 0 ..< good.packets.len:
      var p = newSeq[byte](rng.rand(1 .. 120))
      for k in 0 ..< p.len: p[k] = byte(rng.rand(255))
      cr.packets.add p
    let rr = decodeClip(encodeRecord(cr))
    if rr.ok: doAssert rr.pcm.len == cr.samples
    else: doAssert rr.why in ["packet-frame", "decode"], rr.why
echo "4. decode refuses non-20 ms packets and non-records; random packets never crash OK"

# 5. The 60 s cap: one frame over is refused, whole or fed in pieces; 60 s exactly encodes,
#    within the size budget of §5.
block:
  let over = encodeClip(newSeq[int16](MaxSamples + ClipFrame))
  doAssert not over.ok and over.why == "too-long", over.why
  let r = encodeClip(newSeq[int16](MaxSamples))
  doAssert r.ok, r.why
  doAssert r.clip.samples == MaxSamples
  doAssert encodeRecord(r.clip).len <= maxClipBytes(VoiceMaxMs), $encodeRecord(r.clip).len
  let e = newClipEncoder()
  doAssert e.feed(newSeq[int16](MaxSamples - ClipRate)) == ""
  doAssert e.feed(newSeq[int16](ClipRate)) == ""
  doAssert e.feed(newSeq[int16](1)) == "too-long"
  doAssert e.samples == MaxSamples, "a refused feed takes nothing"
  doAssert e.finish() == ""
  doAssert e.clip() == r.clip
echo "5. 60 s plus one frame refused; 60 s exactly within ", maxClipBytes(VoiceMaxMs), " B OK"

echo "voice_codec_test: all OK"
