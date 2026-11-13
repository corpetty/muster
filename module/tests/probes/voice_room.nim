## A shared fixture for voice notes' spec probes (docs/design/voice-notes.md §3.3, §6, §7;
## S5): four members — Alice, Bob, Carol and Mallory — each with a keystore, one room and
## another, synthetic clip records, and builders for genuine and tampered `voice/` parts.
## A synthetic clip is a real CDE record (voice_clip) of fake 40-byte packets: the fold
## checks a record's structure and digest and never decodes audio, so no probe links
## libopus, and probes/config.nims and grade-specs.sh need nothing new. Every probe reads
## the room the way the hosted module does: `authenticEvents` (authorship.nim), then
## `reduceVoice` or `threadRows` (voice.nim). Not a probe itself.

import std/json
import ../../src/log/log
import ../../src/crypto/keystore
import ../../src/crypto/curve25519
import ../../src/audio/voice_clip
import ../../src/coordination/authorship
import ../../src/coordination/intent_events
import ../../src/coordination/voice
export log, keystore, curve25519, voice_clip, authorship, intent_events, voice

proc seedOf(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hx*(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs* = newInMemoryKeystore(seedOf(0x91), seedOf(0xa1))
let bobKs* = newInMemoryKeystore(seedOf(0x92), seedOf(0xa2))
let carolKs* = newInMemoryKeystore(seedOf(0x93), seedOf(0xa3))
let malloryKs* = newInMemoryKeystore(seedOf(0x94), seedOf(0xa4))
proc idOf*(ks: Keystore): string = hx(ks.encIdentity().toBytes())
let alice* = idOf(aliceKs)
let bob* = idOf(bobKs)
let carol* = idOf(carolKs)
let mallory* = idOf(malloryKs)

const Room* = "/muster/1/room-voice-probe/proto"
const OtherRoom* = "/muster/1/another-room/proto"
const Preskip* = 312             ## libopus's lookahead at 48 kHz (§3.2)

proc synthClip*(ms: int, salt: byte): VoiceClip =
  ## A clip of `ms` milliseconds as the encoder would shape it: 40-byte packets, one per
  ## 20 ms, the encoder flushed through its lookahead. The bytes are not Opus; `salt` makes
  ## two clips of one length differ.
  let samples = ms * (ClipRate div 1000)
  result = VoiceClip(preskip: Preskip, samples: samples)
  for i in 0 ..< packetCount(samples, Preskip):
    var p = newSeq[byte](PacketBytes)
    for j in 0 ..< PacketBytes: p[j] = byte((i * 31 + j * 7 + int(salt) * 13) and 0xFF)
    result.packets.add p

type Note* = tuple[nid: string, record: seq[byte], parts: seq[Event]]

proc note*(ks: Keystore, ms: int, ts: int64, salt: byte): Note =
  ## A genuine note: `ks`'s clip of `ms` ms at `ts`, its two parts signed by `ks` for Room.
  let clip = synthClip(ms, salt)
  let (nid, evs) = voiceEvents(idOf(ks), clip, ts)
  var signed: seq[Event]
  for e in evs: signed.add signAuthored(ks, Room, e)
  (nid, encodeRecord(clip), signed)

proc signedBy*(ks: Keystore, e: Event, room = Room): Event =
  ## `e` with an author signature made by `ks`, for `room`, whoever `e`'s key names. When
  ## `ks` is the named author and `room` is Room, this is the genuine event; otherwise a
  ## forgery whose signature is well-formed but not the named author's, or not this room's.
  var j = parseJson(e.value)
  if j.hasKey(AuthorSigField): j.delete(AuthorSigField)
  let unsigned = Event(parents: e.parents, key: e.key, value: $j)
  j[AuthorSigField] = %hx(ks.edSign(authorDigest(room, unsigned)))
  Event(parents: e.parents, key: e.key, value: $j)

proc stripped*(e: Event): Event =
  ## `e` with its author signature removed.
  var j = parseJson(e.value)
  if j.hasKey(AuthorSigField): j.delete(AuthorSigField)
  Event(parents: e.parents, key: e.key, value: $j)

proc edited*(e: Event, field: string, value: JsonNode): Event =
  ## `e` with one value field changed AFTER it was signed.
  var j = parseJson(e.value)
  j[field] = value
  Event(parents: e.parents, key: e.key, value: $j)

proc rekeyed*(e: Event, key: string): Event =
  ## `e` under another log key, its value and signature untouched.
  Event(parents: e.parents, key: key, value: e.value)

proc view*(events: seq[Event], room = Room): seq[VoiceNote] =
  ## The room's notes as the hosted module reads them.
  reduceVoice(authenticEvents(events, room))

proc rows*(events: seq[Event], room = Room): seq[ThreadRow] =
  ## The room's thread as the hosted module reads it.
  threadRows(authenticEvents(events, room))

proc noteById*(notes: seq[VoiceNote], nid: string): (bool, VoiceNote) =
  for n in notes:
    if n.nid == nid: return (true, n)
