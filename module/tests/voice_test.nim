## Voice notes in the room (docs/design/voice-notes.md §3.3, §4, §6, §7; S5). A note is
## exactly two author-signed `voice/<nid>/<author>/<i>/2` events, each one half of a clip
## record, folded by `reduceVoice` over the room's authentic view into notes that are
## complete, arriving or broken, and merged with the room's messages into thread rows by
## `threadRows`, which alone sets a row's `voice` field.
##   1. noteIdOf is deterministic, is 16 bytes of a `muster.voice.note-id.v1` hash-input
##      record, and changes with the author, the clip digest and ts; the clip digest is a
##      `muster.voice.clip.v1` record over the record's bytes
##   2. voiceEvents gives exactly two events: the documented keys, no parents, integer-only
##      values, the record's two halves (the larger first) as canonical base64
##   3. Alice publishes a note; Bob's fold holds one complete note, Alice's, her clip byte
##      for byte
##   4. every frame a note leaves in is 90,153 B, for clips of 0.5 s, 10 s and 60 s
##   5. a part forged (Mallory signs under Alice's key segment), unsigned, replayed from
##      another room or edited drops out of the authentic view, so the note is never
##      complete; over the wire too, where the raw log keeps the forgery
##   6. squatting: a part under a note id that is not noteIdOf(author, digest, ts) is
##      dropped, whoever signed it
##   7. a key with n other than 2, i out of range or a malformed author, a part that is not
##      canonical base64 (whitespace in it above all: std/base64's decode reads past the end
##      of "    AB", an IndexDefect), a durMs no clip has, a float or any other malformed
##      value: dropped, never raised; any string at all as the half is a part only when it
##      is the one base64 spelling of its bytes
##   8. states: one part reads arriving; parts that disagree on ts, length or digest, a
##      record that misses its digest, fails the structural checks or is not its own length,
##      read broken, whichever part is the odd one; of two equivocating copies of a part,
##      the first by canonical order stands, whichever order they arrived in
##   9. every permutation and duplication of a room's voice events folds identically
##      (invariant 4), notes and thread rows alike
##  10. threadRows merges messages and notes by (ts, id), a note and a message of one ts
##      ordered by id either way round; a voice row's body is "", its `voice` field is
##      metadata under 300 B and carries no clip; the newest row's ts counts a note; a
##      `message/` whose body claims kind `voice-note` with another member's note id is a
##      plain row of its author's, never a voice row (§7)
##  11. a member admitted after a note cannot fold it (F-16, invariant 7); a note sent in
##      their epoch they can
##  12. a memo of verdicts (§6): a fold given one returns what a fold without it does, in
##      any order; it holds one verdict per pair of standing parts, keyed by their ids, so
##      a part that comes to stand in another's place is judged afresh; threadLastTs, which
##      judges no clip, is the newest row's ts
##  13. the information-flow view (§10): each part tells the room members who held its
##      epoch's key `voice-note` and `voice-note-length`, and the store node `timing`,
##      `topic` and `fixed-size`; no other observer, and no other row. An entry under
##      voice/ that is no note's part (a key the fold refuses, a value it refuses, an
##      equivocating later copy, a squatted note id) tells the store node `timing`, `topic`
##      and `fixed-size` and the room nothing: "a part" is what the fold stands, everywhere
##  14. the room map (§10): each part is an entry of kind `voice`, author-signed, credited
##      to the member its key names, with the facets an author-signed note has, the store
##      node's naming the one fixed size; it is counted exactly when the fold names it in a
##      note's parts, so an entry under voice/ that is no note's part (the four above) is
##      still its signer's, uncounted, with a facet that says so and names its signer; its
##      content is v, ts, durMs and digest at most, never `part`: no 48-character stretch of
##      a half, at each 24-character step or its end, is in the map coordinate_graph serves
##  15. provenance (§10): each part is a peer message of kind `voice`, "a voice note (part i
##      of 2)", in its author's name, accountable, on the guarantee a message carries, at
##      the epoch whose key opened it; an entry under voice/ that is no note's part (the
##      four above) is none
##  16. the memo keeps each part's header fields by event id, never its half: every fold
##      output (reduceVoice, threadRows, threadLastTs, voiceStanding, voiceRecordOf,
##      voiceNoteOf) is the memo-less one, in any order, duplicated, and as the set grows;
##      each part is parsed once (`voiceParses`), a warm memo parses none, a new part alone
##      is parsed, and an equivocating later copy or a key of no part's shape never is
##  17. reduceFlow, logProvenance and reduceRoomGraph take the memo too (coordinate_flow and
##      coordinate_graph poll): each output is the memo-less one, byte for byte, in any order;
##      a cold memo parses each part once across them, a warm one none, the map's content of
##      a part read off its header; only an entry under voice/ that holds no part's value is
##      parsed again, by the map, for its content
## Clips are synthetic CDE records of 40-byte packets: the fold checks structure and digest
## and never decodes audio, so this test links no codec. LocalTransport + epoch crypto;
## needs libsecp256k1 + libsodium.

import std/[json, strutils, base64, algorithm, random, sequtils, tables, sets]
import ../src/log/log
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/hashing/hash_input
import ../src/dcbor/dcbor
import ../src/audio/voice_clip
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/intent_events
import ../src/coordination/voice
import ../src/coordination/intents
import ../src/coordination/flow
import ../src/coordination/room_graph
import ../src/drivers/driver
import ../src/intents/disclosure

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc unhex(s: string): seq[byte] =
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))
proc bytesOf(s: string): seq[byte] = (for c in s: result.add byte(c))

let aliceKs = newInMemoryKeystore(seed(0x51), seed(0x61))
let bobKs   = newInMemoryKeystore(seed(0x52), seed(0x62))
let carolKs = newInMemoryKeystore(seed(0x53), seed(0x63))
let malKs   = newInMemoryKeystore(seed(0x54), seed(0x64))
let alice   = hex(aliceKs.encIdentity().toBytes())
let bob     = hex(bobKs.encIdentity().toBytes())
let mallory = hex(malKs.encIdentity().toBytes())

const topic = "/muster/1/room-voice/proto"
const otherTopic = "/muster/1/another-room/proto"
const WireBytes = 1 + 24 + 16 + 90_112       ## kind byte, secretbox nonce and MAC, the pad

type Wire = ref object
  frames: seq[seq[byte]]   ## every frame the topic carries, as a store node holds them

proc tap(net: LocalNetwork, topic: string): Wire =
  let w = Wire()
  newLocalTransport(net).subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} =
    w.frames.add m.payload)
  w

proc dataFrames(w: Wire): seq[seq[byte]] =
  for f in w.frames: (if f.len > 0 and f[0] == 0x00'u8: result.add f)

let net = newLocalNetwork()
let aliceCrypto = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity(), malKs.encIdentity()])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobKs.encIdentity()))
let malCrypto = newEpochJoiner(malKs)
malCrypto.ingestGrant(aliceCrypto.grantFor(0, malKs.encIdentity()))
let aliceS = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bobS = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)
let malS = newCoordinationSession(newLocalTransport(net), malCrypto, topic)
let wire = tap(net, topic)

proc synthClip(ms: int, salt: byte): VoiceClip =
  ## A clip as the encoder shapes one: a 40-byte packet per 20 ms, flushed through a 312-
  ## sample lookahead. The bytes are not Opus; the fold never decodes them.
  let samples = ms * (ClipRate div 1000)
  result = VoiceClip(preskip: 312, samples: samples)
  for i in 0 ..< packetCount(samples, 312):
    var p = newSeq[byte](PacketBytes)
    for j in 0 ..< PacketBytes: p[j] = byte((i * 31 + j * 7 + int(salt) * 13) and 0xFF)
    result.packets.add p

proc signedNote(ks: Keystore, clip: VoiceClip, ts: int64, room = topic): (string, seq[Event]) =
  let (nid, evs) = voiceEvents(hex(ks.encIdentity().toBytes()), clip, ts)
  (nid, evs.mapIt(signAuthored(ks, room, it)))

proc signedBy(ks: Keystore, e: Event, room = topic): Event =
  ## `e` signed by `ks` for `room`, whoever its key names: a forgery unless `ks` is its author.
  var j = parseJson(e.value)
  if j.hasKey(AuthorSigField): j.delete(AuthorSigField)
  let unsigned = Event(parents: e.parents, key: e.key, value: $j)
  j[AuthorSigField] = %hex(ks.edSign(authorDigest(room, unsigned)))
  Event(parents: e.parents, key: e.key, value: $j)

proc stripped(e: Event): Event =
  var j = parseJson(e.value)
  if j.hasKey(AuthorSigField): j.delete(AuthorSigField)
  Event(parents: e.parents, key: e.key, value: $j)

proc withField(e: Event, field: string, v: JsonNode): Event =
  ## `e`'s value with one field set, its signature (if any) untouched.
  var j = parseJson(e.value)
  j[field] = v
  Event(parents: e.parents, key: e.key, value: $j)

proc view(events: seq[Event]): seq[VoiceNote] = reduceVoice(authenticEvents(events, topic))

proc noteIn(notes: seq[VoiceNote], nid: string): VoiceNote =
  var found = 0
  for n in notes:
    if n.nid == nid: (result = n; inc found)
  doAssert found == 1, "one note " & nid & ", not " & $found

proc only(notes: seq[VoiceNote]): VoiceNote =
  doAssert notes.len == 1, "one note, not " & $notes.len
  notes[0]

# ── 1. the note id and the clip digest ───────────────────────────────────────────
block:
  let dg = "ab".repeat(32)
  let ts = 1_792_000_000'i64
  let id = noteIdOf(alice, dg, ts)
  doAssert id.len == 32 and id.allCharsInSet({'0' .. '9', 'a' .. 'f'}), id
  doAssert noteIdOf(alice, dg, ts) == id, "deterministic"
  let want = digest(hashInput("muster.voice.note-id.v1", @[
    ("author", cbText(alice)), ("clip", cbBytes(unhex(dg))), ("ts", cbInt(ts))]))
  doAssert id == hex(want[0 ..< 16]), "16 bytes of the note-id hash-input record"
  doAssert noteIdOf(bob, dg, ts) != id, "another author"
  doAssert noteIdOf(alice, "cd".repeat(32), ts) != id, "another clip"
  doAssert noteIdOf(alice, dg, ts + 1) != id, "another ts"
  let record = encodeRecord(synthClip(500, 1))
  doAssert clipDigest(record) == digest(hashInput("muster.voice.clip.v1", @[("clip", cbBytes(record))]))
  doAssert clipDigest(record) != clipDigest(encodeRecord(synthClip(500, 2)))
  echo "1. noteIdOf is 16 bytes of a hash-input record over (author, clip digest, ts); the clip digest is a record too OK"

# ── 2. voiceEvents: two parts, the documented keys, integers only ─────────────────
block:
  let clip = synthClip(10_000, 2)
  let record = encodeRecord(clip)
  let ts = 1_792_000_100'i64
  let (nid, evs) = voiceEvents(alice, clip, ts)
  doAssert VoiceParts == 2 and evs.len == VoiceParts, $evs.len
  doAssert nid == noteIdOf(alice, hex(clipDigest(record)), ts)
  var joined: seq[byte]
  for i, e in evs:
    doAssert e.key == "voice/" & nid & "/" & alice & "/" & $i & "/2", e.key
    doAssert e.parents.len == 0, "a part names no parents: its order rides `after`"
    let j = parseJson(e.value)
    var fields: seq[string]
    for k, v in j:
      fields.add k
      doAssert v.kind in {JInt, JString}, k & " is a " & $v.kind & ": integers and strings only"
    doAssert fields.sorted() == @["digest", "durMs", "part", "ts", "v"], $fields
    doAssert j["v"].getInt() == 1 and j["ts"].getBiggestInt() == ts
    doAssert j["durMs"].getInt() == 10_000 and clip.durationMs == 10_000
    doAssert j["digest"].getStr() == hex(clipDigest(record))
    let raw = decode(j["part"].getStr())
    doAssert encode(raw) == j["part"].getStr(), "canonical base64"
    doAssert raw.len == (if i == 0: (record.len + 1) div 2 else: record.len div 2), "halves, the larger first"
    joined.add bytesOf(raw)
  doAssert joined == record, "the two parts are the record, in order"
  # signed as its author: dCBOR takes every value (a float would refuse), the key names her
  for e in evs:
    let s = signAuthored(aliceKs, topic, e)
    doAssert authorOf(s).author == alice and authorVerified(topic, s)
  doAssertRaises(ValueError): discard voiceEvents("not-an-identity", clip, ts)
  echo "2. voiceEvents: two parts under voice/<nid>/<author>/<i>/2, integer-only values, the record's halves OK"

# ── 3. Alice publishes; Bob folds her note whole ─────────────────────────────────
let clip3 = synthClip(3_000, 3)
let (nid3, parts3) = voiceEvents(alice, clip3, 1_792_000_200)
block:
  for e in parts3: aliceS.publishAuthored(aliceKs, e)
  for (who, s) in {"alice": aliceS, "bob": bobS}:
    let n = only(reduceVoice(s.roomEvents()))
    doAssert n.nid == nid3 and n.author == alice, who
    doAssert n.ts == 1_792_000_200 and n.durMs == 3_000 and n.state == vsComplete, who & ": " & $n
    let (ok, record) = voiceRecordOf(s.roomEvents(), nid3)
    doAssert ok and record == encodeRecord(clip3), who & ": Alice's clip, byte for byte"
  doAssert not voiceRecordOf(bobS.roomEvents(), "00".repeat(16)).ok, "no record for a note the room lacks"
  echo "3. Alice publishes a note; Bob holds it complete, her clip byte-identical OK"

# ── 4. every voice frame is one size ─────────────────────────────────────────────
block:
  for (ms, salt) in [(500, 41'u8), (10_000, 42'u8), (60_000, 43'u8)]:
    let before = wire.dataFrames().len
    let (nid, evs) = voiceEvents(alice, synthClip(ms, salt), 1_792_000_300 + int64(ms))
    for e in evs: aliceS.publishAuthored(aliceKs, e)
    let sent = wire.dataFrames()[before .. ^1]
    doAssert sent.len == 2, $sent.len
    for f in sent: doAssert f.len == WireBytes, $ms & " ms: a " & $f.len & " B frame"
    let n = noteIn(reduceVoice(bobS.roomEvents()), nid)
    doAssert n.state == vsComplete and n.durMs == ms, $n
  echo "4. a note of 0.5 s, 10 s or 60 s leaves as two frames of ", WireBytes, " B OK"

# ── 5. forged, unsigned, replayed and edited parts drop out ──────────────────────
block:
  let ts = 1_792_000_400'i64
  let (nid, parts) = signedNote(aliceKs, synthClip(2_000, 5), ts)
  let (_, elsewhere) = signedNote(aliceKs, synthClip(2_000, 5), ts, otherTopic)
  let (_, another) = signedNote(aliceKs, synthClip(2_000, 6), ts)
  for i in 0 .. 1:
    let tampered = @[
      ("forged", signedBy(malKs, parts[i])),
      ("unsigned", stripped(parts[i])),
      ("cross-room", elsewhere[i]),
      ("edited", withField(parts[i], "part", parseJson(another[i].value)["part"])),
      ("edited ts", withField(parts[i], "ts", %(ts + 1)))]
    for (what, t) in tampered:
      doAssert t.key == parts[i].key, what
      doAssert not authorVerified(topic, t), what
      let n = only(view(@[parts[1 - i], t]))
      doAssert n.nid == nid and n.author == alice, what
      doAssert n.state == vsArriving, what & ", part " & $i & ": " & $n.state
      doAssert n.parts[i] == "" and n.parts[1 - i] == eventId(parts[1 - i]), what
      doAssert view(@[t]).len == 0, what & " alone names no note"
  doAssert only(view(parts)).state == vsComplete
  # over the wire: Mallory, a member, sends a part in Alice's name; every member drops it
  let (nidW, partsW) = signedNote(aliceKs, synthClip(1_000, 7), 1_792_000_450)
  let forged = signedBy(malKs, partsW[1])
  malS.publish(forged)
  aliceS.publishAuthored(aliceKs, partsW[0])
  doAssert bobS.log.find(eventId(forged)).found, "the raw log keeps the forgery"
  doAssert noteIn(reduceVoice(bobS.roomEvents()), nidW).state == vsArriving, "the forged part does not count"
  aliceS.publishAuthored(aliceKs, partsW[1])
  doAssert noteIn(reduceVoice(bobS.roomEvents()), nidW).state == vsComplete
  echo "5. forged, unsigned, cross-room and edited parts never complete a note; over the wire too OK"

# ── 6. squatting ─────────────────────────────────────────────────────────────────
block:
  let ts = 1_792_000_500'i64
  let (nid, parts) = signedNote(aliceKs, synthClip(2_000, 8), ts)
  let base = view(parts)
  doAssert only(base).state == vsComplete
  var squats: seq[Event]
  for i in 0 .. 1:
    let k = "voice/" & nid & "/" & mallory & "/" & $i & "/2"
    # Mallory claims Alice's note as hers: Alice's parts, Alice's nid, Mallory's segment
    squats.add signAuthored(malKs, topic, Event(key: k, value: stripped(parts[i]).value))
    # Mallory's own clip, posted under Alice's note id
    let (_, mine) = voiceEvents(mallory, synthClip(2_000, 9), ts)
    squats.add signAuthored(malKs, topic, Event(key: k, value: mine[i].value))
    # Alice's own part under a note id her clip does not derive
    let wrong = "voice/" & "0f".repeat(16) & "/" & alice & "/" & $i & "/2"
    squats.add signAuthored(aliceKs, topic, Event(key: wrong, value: stripped(parts[i]).value))
  let evs = authenticEvents(parts & squats, topic)
  doAssert evs.len == parts.len + squats.len, "every squat is genuinely signed"
  doAssert reduceVoice(evs) == base, "no squat names a note: " & $reduceVoice(evs)
  doAssert view(squats).len == 0
  echo "6. a part under a note id that is not noteIdOf(author, digest, ts) is dropped OK"

# ── 7. malformed keys and values: dropped, never raised ──────────────────────────
block:
  let ts = 1_792_000_600'i64
  let (nid, parts) = signedNote(aliceKs, synthClip(1_000, 10), ts)
  let p1 = stripped(parts[1])
  let pre = "voice/" & nid & "/" & alice & "/"
  proc arriving(evs: seq[Event], what: string) =
    let n = only(reduceVoice(evs))
    doAssert n.nid == nid and n.state == vsArriving and n.parts[1] == "", what & ": " & $n
  # authentic, since Alice signed each, yet not a part: the fold's own checks drop them
  for k in [pre & "1/3", pre & "1/02", pre & "1/1", pre & "2/2", pre & "-1/2", pre & "x/2",
            pre & "01/2", pre & "1/2/x", pre & "1", "voice/" & nid & "/" & alice.toUpperAscii & "/1/2",
            "voice/" & nid.toUpperAscii & "/" & alice & "/1/2"]:
    let e = signAuthored(aliceKs, topic, Event(key: k, value: p1.value))
    doAssert authorVerified(topic, e), k
    arriving(authenticEvents(@[parts[0], e], topic), k)
  var noDigest = parseJson(p1.value)
  noDigest.delete("digest")
  for (what, field, v) in [("base64 garbage", "part", %"!!not base64!!"), ("unpadded base64", "part", %"QQ"),
                           ("a number", "part", %42), ("v 2", "v", %2),
                           # std/base64's decode (Nim 2.2.4) skips whitespace inside its loop and
                           # reads past the end of each of these: an IndexDefect, which no
                           # `except CatchableError` catches
                           ("spaces, then base64", "part", %"    AB"), ("spaces inside", "part", %"AAAA    A"),
                           ("two spaces, then base64", "part", %"  ABC"), ("newlines inside", "part", %"AAAA\n\n\n\nAB"),
                           # and of these, though each is a multiple of 4 long
                           ("five spaces inside", "part", %"AAAA     AAA"), ("five newlines inside", "part", %"AAAA\n\n\n\n\nAAA"),
                           ("spaces it skips", "part", %"    AAAA"),
                           ("URL-safe base64", "part", %"-_-_"), ("padding bits set", "part", %"QR=="),
                           ("a padding bit set", "part", %"QUJ="), ("padding inside", "part", %"QQ==QQ=="),
                           ("padding alone", "part", %"===="),
                           ("durMs -1", "durMs", %(-1)), ("durMs over the cap", "durMs", %(VoiceMaxMs + 1))]:
    let e = signAuthored(aliceKs, topic, withField(p1, field, v))
    doAssert authorVerified(topic, e), what
    arriving(authenticEvents(@[parts[0], e], topic), what)
  # a part whose durMs no clip has is not a part, even alone: no note reads that length
  for dur in [-1, VoiceMaxMs + 1]:
    let e = signAuthored(aliceKs, topic, withField(stripped(parts[0]), "durMs", %dur))
    doAssert authorVerified(topic, e)
    doAssert reduceVoice(authenticEvents(@[e], topic)).len == 0, "a part of " & $dur & " ms names no note"
  # any string at all as the half: a part only when it is the one spelling `encode` gives
  # its bytes (then the bytes miss the digest: broken), anything else dropped (arriving);
  # and the fold never raises
  block:
    const alphabet = "ABQRgw+/=-_ \n\r"
    var rs = initRand(0xb64)
    var spellings, others = 0
    for _ in 0 ..< 4000:
      var s = ""
      for _ in 0 ..< rs.rand(12): s.add alphabet[rs.rand(alphabet.high)]
      # the reference, std/base64 itself, handed only what it cannot read past the end of
      let canonical = not s.anyIt(it in {' ', '\n', '\r'}) and
                      (try: encode(decode(s)) == s except ValueError: false)
      let n = only(reduceVoice(@[parts[0], withField(p1, "part", %s)]))
      doAssert n.nid == nid and n.state == (if canonical: vsBroken else: vsArriving), s.escape & ": " & $n.state
      if canonical: inc spellings else: inc others
    doAssert spellings > 200 and others > 200, $spellings & " canonical, " & $others & " not"
  block:
    let e = signAuthored(aliceKs, topic, withField(p1, "author", %mallory))
    arriving(authenticEvents(@[parts[0], e], topic), "a field no part has")
  # not even signable, so never authentic; the fold drops them alone as well
  var raw: seq[(string, Event)]
  for (what, value) in [("a float", p1.value.replace("\"durMs\":1000", "\"durMs\":1000.5")),
                        ("ts as a string", withField(p1, "ts", %"1792000600").value),
                        ("no digest", $noDigest),
                        ("not json", "not json"), ("an array", "[]"), ("a number", "1"), ("empty", "")]:
    raw.add (what, Event(key: pre & "1/2", value: value))
  doAssert "1000.5" in raw[0][1].value
  for i in 0 ..< 2:
    raw.add ("an author that is not hex", Event(key: "voice/" & nid & "/" & "zz".repeat(64) & "/" & $i & "/2", value: stripped(parts[i]).value))
    raw.add ("a short author", Event(key: "voice/" & nid & "/" & alice[0 ..< 64] & "/" & $i & "/2", value: stripped(parts[i]).value))
    raw.add ("a short nid", Event(key: "voice/" & nid[0 ..< 30] & "/" & alice & "/" & $i & "/2", value: stripped(parts[i]).value))
  for (what, e) in raw:
    doAssert not authorVerified(topic, e), what
    arriving(@[parts[0], e], what)
    arriving(authenticEvents(@[parts[0], e], topic), what)
  for k in ["voice", "voice/", "voice/" & nid, "voice/" & nid & "/" & alice]:
    doAssert reduceVoice(@[Event(key: k, value: p1.value)]).len == 0, k
  echo "7. a wrong n or i, a malformed author or nid, bad base64 (whitespace in it too), a durMs no clip has, a float or a ",
       "malformed value: dropped, never raised; any string is a part only as canonical base64 OK"

# ── 8. arriving, broken, and the first copy standing ─────────────────────────────
block:
  let ts = 1_792_000_700'i64
  let clipX = synthClip(2_000, 11)
  let clipY = synthClip(2_000, 12)
  let (nidX, x) = signedNote(aliceKs, clipX, ts)
  let (_, y) = signedNote(aliceKs, clipY, ts)
  let x1 = stripped(x[1])
  proc partOne(value: string): Event = signAuthored(aliceKs, topic, Event(key: x[1].key, value: value))
  proc stateOf(evs: seq[Event]): VoiceState = noteIn(view(evs), nidX).state
  doAssert stateOf(@[x[0]]) == vsArriving and stateOf(@[x[1]]) == vsArriving, "one part reads arriving"
  doAssert stateOf(x) == vsComplete
  let yPart = parseJson(y[1].value)["part"]
  let yDigest = parseJson(y[1].value)["digest"]
  for (what, p) in [("another digest", partOne(withField(withField(x1, "digest", yDigest), "part", yPart).value)),
                    ("another ts", partOne(withField(x1, "ts", %(ts + 1)).value)),
                    ("another length", partOne(withField(x1, "durMs", %2_020).value)),
                    ("bytes that miss the digest", partOne(withField(x1, "part", yPart).value))]:
    let n = noteIn(view(@[x[0], p]), nidX)
    doAssert n.state == vsBroken, what & ": " & $n.state
    doAssert n.author == alice and n.ts == ts and n.durMs == 2_000, what & ": the note is read off the part its id derives from"
  # the odd one out is part 0: when it no longer derives the note id, part 1 does, and the
  # note is read off part 1
  let x0 = stripped(x[0])
  let y0Part = parseJson(y[0].value)["part"]
  proc partZero(value: string): Event = signAuthored(aliceKs, topic, Event(key: x[0].key, value: value))
  for (what, p) in [("part 0 at another ts", partZero(withField(x0, "ts", %(ts + 1)).value)),
                    ("part 0 of another clip", partZero(withField(withField(x0, "digest", yDigest), "part", y0Part).value)),
                    ("part 0's bytes miss the digest", partZero(withField(x0, "part", y0Part).value))]:
    let n = noteIn(view(@[p, x[1]]), nidX)
    doAssert n.state == vsBroken, what & ": " & $n.state
    doAssert n.author == alice and n.ts == ts and n.durMs == 2_000, what & ": " & $n
    doAssert n.parts[0] == eventId(p) and n.parts[1] == eventId(x[1]), what
  # the digest matches, but what it names is not a clip record, or not of the length it claims
  for (what, record, durMs) in [("not a record", newSeq[byte](300), 1_000),
                                ("a truncated record", encodeRecord(synthClip(500, 13))[0 .. ^2], 500),
                                ("the wrong length", encodeRecord(clipX), 2_020)]:
    let (nid, evs) = voicePartEvents(alice, record, ts, durMs)
    let n = noteIn(view(evs.mapIt(signAuthored(aliceKs, topic, it))), nid)
    doAssert n.state == vsBroken, what & ": " & $n.state
  let (nidGood, good) = voicePartEvents(alice, encodeRecord(clipX), ts, 2_000)
  doAssert nidGood == nidX and good.mapIt(signAuthored(aliceKs, topic, it)) == x
  # equivocation: Alice signs a second part 1 for the same note (the same ts, length and
  # digest, other bytes). Of the two, the one first in canonical order stands: neither names
  # a parent, so the smaller event id. Copies that sort before and after hers, in both orders.
  var before, after: seq[Event]
  for salt in 20'u8 .. 120'u8:
    let other = parseJson(signedNote(aliceKs, synthClip(2_000, salt), ts)[1][1].value)["part"]
    let e = partOne(withField(x1, "part", other).value)
    if eventId(e) < eventId(x[1]): (if before.len == 0: before.add e)
    elif after.len == 0: after.add e
    if before.len > 0 and after.len > 0: break
  doAssert before.len == 1 and after.len == 1
  for evs in [@[x[0], x[1], before[0]], @[before[0], x[0], x[1]]]:
    let n = noteIn(view(evs), nidX)
    doAssert n.state == vsBroken and n.parts[1] == eventId(before[0]), "the first copy stands: " & $n
  for evs in [@[x[0], x[1], after[0]], @[after[0], x[1], x[0]]]:
    let n = noteIn(view(evs), nidX)
    doAssert n.state == vsComplete and n.parts[1] == eventId(x[1]), "the first copy stands: " & $n
  echo "8. one part arriving; disagreeing parts (either one odd), a digest miss, a bad record or length broken; ",
       "the first copy stands OK"

# ── 9. order-free and idempotent (invariant 4) ───────────────────────────────────
block:
  let ts = 1_792_000_800'i64
  let (_, a) = signedNote(aliceKs, synthClip(1_500, 30), ts)
  let (_, b) = signedNote(bobKs, synthClip(2_500, 31), ts)
  let (_, c) = signedNote(aliceKs, synthClip(700, 32), ts + 5)
  let (_, d) = signedNote(aliceKs, synthClip(900, 33), ts + 6)
  let bad = signAuthored(aliceKs, topic, withField(stripped(d[1]), "part", parseJson(c[1].value)["part"]))
  let (_, hello) = newMessageEvent(alice, ts + 1, "hello", 1)
  var evs = a & b & @[c[0], d[0], bad, signedBy(malKs, a[0]), signAuthored(aliceKs, topic, hello)]
  evs = authenticEvents(evs, topic)
  let notes = reduceVoice(evs)
  let rows = threadRows(evs)
  doAssert notes.len == 4 and notes.mapIt(it.state).sorted() == @[vsArriving, vsComplete, vsComplete, vsBroken].sorted(),
           $notes.mapIt(it.state)
  var r = initRand(5)
  for _ in 0 ..< 40:
    var shuffled = evs & evs[0 .. r.rand(evs.len - 1)]
    r.shuffle(shuffled)
    doAssert reduceVoice(shuffled) == notes
    doAssert threadRows(shuffled) == rows
  doAssert reduceVoice(evs.reversed() & evs) == notes
  echo "9. any order, any duplication: the same notes and the same thread OK"

# ── 10. thread rows ──────────────────────────────────────────────────────────────
block:
  let (_, m100) = newMessageEvent(alice, 100, "first", 1)
  let (_, m300) = newMessageEvent(bob, 300, "later", 1)
  let (nid200, n200) = signedNote(bobKs, synthClip(1_000, 40), 200)
  let (nid100, n100) = signedNote(aliceKs, synthClip(1_000, 41), 100)
  let evs = authenticEvents(@[signAuthored(aliceKs, topic, m100), signAuthored(bobKs, topic, m300)] &
                            n200 & n100, topic)
  let rows = threadRows(evs)
  let m100id = m100.key["message/".len .. ^1]
  let m300id = m300.key["message/".len .. ^1]
  var want = @[(100'i64, m100id), (100'i64, nid100), (200'i64, nid200), (300'i64, m300id)]
  want.sort(proc(x, y: (int64, string)): int = (if x[0] != y[0]: cmp(x[0], y[0]) else: cmp(x[1], y[1])))
  doAssert rows.mapIt((it.ts, it.id)) == want, $rows.mapIt((it.ts, it.id))
  doAssert rows.mapIt(it.isVoice).countIt(it) == 2
  for row in rows:
    let j = rowJson(row)
    var keys: seq[string]
    for k, _ in j: keys.add k
    if row.isVoice:
      doAssert row.body == "" and j["body"].getStr() == "", "a voice row's body is empty"
      doAssert row.author == (if row.id == nid200: bob else: alice), "the fold's author"
      doAssert keys.sorted() == @["author", "body", "id", "ts", "voice"], $keys
      let v = j["voice"]
      var vkeys: seq[string]
      for k, _ in v: vkeys.add k
      doAssert vkeys.sorted() == @["durationMs", "note", "state", "v"], $vkeys
      doAssert v["v"].getInt() == 1 and v["note"].getStr() == row.id and v["durationMs"].getInt() == 1_000
      doAssert v["state"].getStr() == "complete"
      doAssert ($v).len < 300, "the voice field is metadata: " & $($v).len & " B"
      doAssert ($j).len < 512 and "part" notin $j, "no clip rides the row: " & $($j).len & " B"
    else:
      doAssert keys.sorted() == @["author", "body", "id", "ts"], "a message row has no voice field: " & $keys
  doAssert reduceMessages(evs)[^1].ts == 300 and threadLastTs(evs) == 300
  let (_, n900) = signedNote(aliceKs, synthClip(1_000, 42), 900)
  doAssert reduceMessages(evs & n900)[^1].ts == 300, "messages alone miss the note"
  doAssert threadLastTs(evs & n900) == 900, "the newest row's ts counts a note"
  doAssert threadLastTs(@[]) == 0
  # a forged row (§7): Mallory, in her own name, posts a message whose body is a voice-note
  # card naming Alice's note, and one whose value also carries a `voice` field. Each is her
  # own plain row; the only voice rows are the fold's; nothing names her on Alice's note.
  let body = $(%*{"kind": "voice-note", "v": 1, "note": nid100, "durationMs": 1_000, "state": "complete"})
  let (_, f1) = newMessageEvent(mallory, 150, body, 1)
  let (_, f2) = newMessageEvent(mallory, 151, body, 2)
  let f2v = withField(f2, "voice", %*{"v": 1, "note": nid100, "durationMs": 1_000, "state": "complete"})
  let (_, f3) = newMessageEvent(alice, 152, body, 3)            # in Alice's name, unsigned
  let forged = authenticEvents(evs & @[signAuthored(malKs, topic, f1), signAuthored(malKs, topic, f2v), f3], topic)
  let frows = threadRows(forged)
  doAssert frows.filterIt(it.isVoice).mapIt((it.id, it.author)) == rows.filterIt(it.isVoice).mapIt((it.id, it.author)),
           "the voice rows are the fold's, unchanged"
  let hers = frows.filterIt(it.author == mallory)
  doAssert hers.len == 2, $hers.len
  for row in hers:
    doAssert not row.isVoice and row.body == body, "her raw JSON, as text"
    doAssert not rowJson(row).hasKey("voice"), "no message puts a voice field on a row"
  doAssert frows.filterIt(it.ts == 152).len == 0, "a message in Alice's name she did not sign is dropped"
  # at one ts the id decides, whichever kind of row it is: Bob's message and two of Alice's
  # notes of the same second, one whose nid sorts before the message id and one after
  # (clips tried until they do; a message id is "0x" and hex, so a nid sorts first only
  # when it starts with "0")
  block:
    let (mid, m400) = newMessageEvent(bob, 400, "the same second", 9)
    var lo, hi: seq[(string, seq[Event])]
    for salt in 44'u8 .. 250'u8:
      let (nid, evs) = signedNote(aliceKs, synthClip(1_000, salt), 400)
      if nid < mid: (if lo.len == 0: lo.add((nid, evs)))
      elif hi.len == 0: hi.add((nid, evs))
      if lo.len > 0 and hi.len > 0: break
    doAssert lo.len == 1 and hi.len == 1
    let at = threadRows(authenticEvents(hi[0][1] & @[signAuthored(bobKs, topic, m400)] & lo[0][1], topic))
    doAssert at.mapIt((it.ts, it.id, it.isVoice)) ==
             @[(400'i64, lo[0][0], true), (400'i64, mid, false), (400'i64, hi[0][0], true)],
             $at.mapIt((it.ts, it.id, it.isVoice))
  echo "10. threadRows: messages and notes by (ts, id), either kind first at one ts, a metadata-only voice field, ",
       "lastTs counts a note, a forged voice-note body stays its author's plain row OK"

# ── 11. a later joiner cannot fold an earlier note (F-16) ────────────────────────
block:
  let earlier = reduceVoice(bobS.roomEvents())
  doAssert earlier.len == 5 and earlier.allIt(it.state == vsComplete), $earlier.len
  aliceCrypto.addMember(carolKs.encIdentity())
  bobCrypto.ingestGrant(aliceCrypto.grantFor(1, bobKs.encIdentity()))
  let carolCrypto = newEpochJoiner(carolKs)
  carolCrypto.ingestGrant(aliceCrypto.grantFor(1, carolKs.encIdentity()))
  let carolS = newCoordinationSession(newLocalTransport(net), carolCrypto, topic)
  carolS.catchUp()
  doAssert carolS.log.allEvents().len == 0, "nothing from before Carol's epoch opens"
  doAssert reduceVoice(carolS.roomEvents()).len == 0 and threadRows(carolS.roomEvents()).len == 0
  let clip = synthClip(1_200, 50)
  let (nid, evs) = voiceEvents(alice, clip, 1_792_001_000)
  for e in evs: aliceS.publishAuthored(aliceKs, e)
  let n = only(reduceVoice(carolS.roomEvents()))
  doAssert n.nid == nid and n.state == vsComplete and n.author == alice
  let (ok, record) = voiceRecordOf(carolS.roomEvents(), nid)
  doAssert ok and record == encodeRecord(clip)
  doAssert reduceVoice(bobS.roomEvents()).len == earlier.len + 1, "Bob holds both epochs"
  echo "11. a member admitted after a note cannot fold it; one sent in their epoch they hold OK"

# ── 12. a memo of verdicts, keyed by the standing parts' ids (§6) ─────────────────
block:
  let ts = 1_792_002_000'i64
  let (nidA, a) = signedNote(aliceKs, synthClip(1_500, 60), ts)
  let (nidB, b) = signedNote(bobKs, synthClip(2_500, 61), ts + 1)
  let (_, c) = signedNote(aliceKs, synthClip(700, 62), ts + 2)
  let (nidD, d) = signedNote(aliceKs, synthClip(900, 63), ts + 3)
  let (_, e) = signedNote(aliceKs, synthClip(800, 64), ts + 9)
  let bad = signAuthored(aliceKs, topic, withField(stripped(d[1]), "part", parseJson(c[1].value)["part"]))
  let notAPart = signAuthored(aliceKs, topic, withField(stripped(e[0]), "part", %"    AB"))
  let (_, hello) = newMessageEvent(alice, ts + 4, "hello", 7)
  # A and B complete, C arriving, D broken, E's only part no part at all, and a message
  let evs = authenticEvents(a & b & @[c[0], d[0], bad, notAPart, signAuthored(aliceKs, topic, hello)], topic)
  doAssert evs.len == 9, "every event is genuinely signed: " & $evs.len
  let plain = reduceVoice(evs)
  let rows = threadRows(evs)
  doAssert plain.mapIt(it.state) == @[vsComplete, vsComplete, vsArriving, vsBroken], $plain.mapIt(it.state)
  doAssert threadLastTs(evs) == ts + 4 and rows[^1].ts == ts + 4, "E names no row, so not the newest"
  let memo = newVoiceMemo()
  doAssert memo.len == 0 and memo.hits == 0
  doAssert reduceVoice(evs, memo) == plain
  doAssert memo.len == 3 and memo.hits == 0, "one verdict per note of two parts: " & $memo.len
  doAssert threadRows(evs, memo) == rows and memo.hits == 3
  var r = initRand(12)
  for _ in 0 ..< 20:
    var shuffled = evs & evs[0 .. r.rand(evs.len - 1)]
    r.shuffle(shuffled)
    doAssert reduceVoice(shuffled, memo) == plain and threadRows(shuffled, memo) == rows
    doAssert threadLastTs(shuffled) == rows[^1].ts
  doAssert memo.len == 3 and memo.hits == 3 + 20 * 2 * 3, $memo.hits
  # Bob signs a second part 1 for B, other bytes, that sorts before his first: it stands
  # now, so B is judged afresh (broken), never served the verdict on the pair it replaced
  var early: seq[Event]
  for salt in 70'u8 .. 200'u8:
    let other = parseJson(signedNote(bobKs, synthClip(2_500, salt), ts + 1)[1][1].value)["part"]
    let x = signAuthored(bobKs, topic, withField(stripped(b[1]), "part", other))
    if eventId(x) < eventId(b[1]): (early.add x; break)
  doAssert early.len == 1 and early[0].key == b[1].key
  let before = memo.hits
  let now = reduceVoice(authenticEvents(evs & early, topic), memo)
  let nb = noteIn(now, nidB)
  doAssert nb.state == vsBroken and nb.parts[1] == eventId(early[0]), "not the old pair's verdict: " & $nb
  doAssert noteIn(now, nidA).state == vsComplete and noteIn(now, nidD).state == vsBroken
  doAssert memo.len == 4 and memo.hits == before + 2, $memo.len & " " & $(memo.hits - before)
  doAssert now == reduceVoice(authenticEvents(evs & early, topic)), "the memo changes no verdict"
  echo "12. a memo of verdicts keyed by the standing parts' ids changes no fold; another part standing is judged afresh; ",
       "threadLastTs is the newest row's ts OK"

# ── 13. the information-flow view: what each part tells whom (§10) ───────────────
let stub: DriverFor = proc(kind: string): Driver = newStubDriver(rounds = 1, threshold = 1, verifyResult = true)
let carol = hex(carolKs.encIdentity().toBytes())
let founders = @[alice, bob, mallory]
# the room as the hosted layer records it: Carol's admission (§11) as the admitting
# member's log event, sealed under the epoch it opened, and a note of Bob's in that epoch
aliceS.publish(membershipEvent(1, carol))
let (bobNid, bobParts) = voiceEvents(bob, synthClip(1_500, 80), 1_792_003_000)
for e in bobParts: bobS.publishAuthored(bobKs, e)
doAssert noteIn(reduceVoice(bobS.roomEvents()), bobNid).state == vsComplete
# Beside the room's notes, four entries under voice/ that are no note's part, each genuinely
# signed: one of Alice's whose key the fold refuses (an i of "x"); one of hers whose value it
# refuses (the digest field carries her half of the clip in place of a digest); a second copy
# of Bob's part 0, other bytes under his own digest, ts and length, that sorts after his first,
# so the fold ignores it (§6 rule 3): an equivocating copy; and Mallory's own clip under Bob's
# note id, which her clip does not derive (§6 rule 4): a squatted note id
let (extraNid, extraParts) = voiceEvents(alice, synthClip(800, 81), 1_792_003_100)
let notAPart = signAuthored(aliceKs, topic,
  Event(key: "voice/" & extraNid & "/" & alice & "/x/2", value: extraParts[0].value))
let stuffed = signAuthored(aliceKs, topic,
  withField(extraParts[1], "digest", parseJson(extraParts[0].value)["part"]))
let bobPart0 = bobS.roomEvents().filterIt(it.key == bobParts[0].key)
doAssert bobPart0.len == 1
var equivocal: Event
for salt in 90'u8 .. 250'u8:
  let other = parseJson(voiceEvents(bob, synthClip(1_500, salt), 1_792_003_000)[1][0].value)["part"]
  let x = signAuthored(bobKs, topic, withField(stripped(bobPart0[0]), "part", other))
  if eventId(x) > eventId(bobPart0[0]): (equivocal = x; break)
doAssert equivocal.key == bobParts[0].key and equivocal.value != bobPart0[0].value
let squatted = signAuthored(malKs, topic, Event(key: "voice/" & bobNid & "/" & mallory & "/1/2",
  value: voiceEvents(mallory, synthClip(1_500, 82), 1_792_003_000)[1][1].value))
let extras = @[notAPart, stuffed, equivocal, squatted]
var extraIds = initHashSet[EventId]()
for x in extras: extraIds.incl eventId(x)
block:
  let evs = bobS.roomEvents()
  let rows = reduceFlow(evs, stub, founders, bobS.sealedIn)
  proc fields(to: Observer): seq[string] =
    for r in rows:
      if r.kind == "voice" and r.to == to and r.field notin result: result.add r.field
    result.sort()
  doAssert fields(obRoomMember) == @["voice-note", "voice-note-length"], $fields(obRoomMember)
  doAssert fields(obStoreNode) == @["fixed-size", "timing", "topic"], $fields(obStoreNode)
  for o in Observer:
    if o notin {obRoomMember, obStoreNode}: doAssert fields(o).len == 0, $o & " learns of a voice note"
  # each part: exactly those five rows, at the epoch whose key opened it, its room-member
  # rows naming the members who held that key
  let ordered = canonicalOrder(evs)
  var perEpoch: array[2, int]
  for i, e in ordered:
    if not e.key.startsWith("voice/"): continue
    let ep = bobS.sealedIn[eventId(e)]
    inc perEpoch[ep]
    let mine = rows.filterIt(it.seq == i)
    doAssert mine.mapIt(($it.to, it.field)).sorted() == @[("room-member", "voice-note"),
      ("room-member", "voice-note-length"), ("store-node", "fixed-size"), ("store-node", "timing"),
      ("store-node", "topic")], e.key & ": " & $mine.mapIt(($it.to, it.field))
    let holders = (if ep == 0: sorted(founders) else: sorted(founders & carol))
    for r in mine:
      doAssert r.kind == "voice" and r.intentId == "" and r.declared and r.epoch == ep, $r
      doAssert r.members == (if r.to == obRoomMember: holders else: newSeq[string]()), $r
  doAssert perEpoch == [10, 4], "Alice's five notes in epoch 0, hers and Bob's in epoch 1: " & $perEpoch
  doAssert rows.observerMatrix()["store-node"] == %["fixed-size", "timing", "topic"]
  # an entry under voice/ that is no note's part tells the room nothing: the store node
  # keeps its envelope and sees the one size every voice/ frame a client sends is padded to
  let withExtras = authenticEvents(evs & extras, topic)
  doAssert withExtras.len == evs.len + extras.len, "each extra is genuinely signed"
  let rowsX = reduceFlow(withExtras, stub, founders, bobS.sealedIn)
  var seen = 0
  for i, e in canonicalOrder(withExtras):
    if not e.key.startsWith("voice/"): continue
    let mine = rowsX.filterIt(it.seq == i).mapIt(($it.to, it.field)).sorted()
    if eventId(e) in extraIds:
      doAssert mine == @[("store-node", "fixed-size"), ("store-node", "timing"), ("store-node", "topic")],
               e.key & ", no note's part: " & $mine
      inc seen
    else:
      doAssert mine.len == 5 and ("room-member", "voice-note") in mine, e.key & ": " & $mine
  doAssert seen == 4, $seen
  echo "13. the flow: each part tells its epoch's members a voice note and its length, the store node ",
       "its timing, topic and one fixed size, and no one else anything; an entry that is no note's part ",
       "tells the room nothing OK"

# ── 14. the room map: each part credited to its author, its content metadata alone (§10) ──
block:
  let evs = authenticEvents(bobS.roomEvents() & extras, topic)
  doAssert evs.len == bobS.roomEvents().len + extras.len, "each extra is genuinely signed"
  let g = reduceRoomGraph(evs, stub, founders, bob, bobS.sealedIn)
  var nodeOf = initTable[string, GraphNode]()
  for n in g.nodes: nodeOf[n.id] = n
  # counted is the fold's word: exactly the parts it names in a note, whatever the note's state
  var standing = initHashSet[EventId]()
  for note in reduceVoice(evs):
    for id in note.parts:
      if id.len > 0: standing.incl id
  doAssert standing.len == 14 and standing.disjoint(extraIds), $standing.len
  var credited = 0
  var bobPart0Counted: seq[EventId]
  for e in evs:
    if not e.key.startsWith("voice/"): continue
    let n = nodeOf["e:" & eventId(e)]
    let who = e.key.split('/')[2]
    let part = eventId(e) in standing
    doAssert n.attrs["kind"].getStr() == "voice", $n.attrs
    doAssert n.attrs["basis"].getStr() == "author-signed", e.key & ": " & $n.attrs["basis"]
    doAssert n.attrs{"account"}.getStr() == "m:" & who, e.key & ": " & $n.attrs{"account"}
    doAssert g.edges.anyIt(it.kind == "authored" and it.src == "m:" & who and it.dst == n.id), e.key
    doAssert n.attrs["counted"].getBool() == part, e.key & ": counted " & $n.attrs["counted"]
    doAssert part == (eventId(e) notin extraIds), e.key
    if e.key == bobParts[0].key and n.attrs["counted"].getBool(): bobPart0Counted.add eventId(e)
    if eventId(e) in bobS.sealedIn: doAssert n.epoch == bobS.sealedIn[eventId(e)], e.key
    var abouts: seq[string]
    for f in n.attrs["facets"]: abouts.add f["about"].getStr()
    doAssert abouts == (if part: @["who could read it", "that it exists", "who sent it", "what it says"]
                        else: @["who could read it", "that it exists", "this entry"]), e.key & ": " & $abouts
    # the store node sees one fixed size, which marks a voice note but not its length
    let exists = n.attrs["facets"][1]
    doAssert exists["class"].getStr() == "exposed" and exists["party"].getStr() == "the store node"
    doAssert "one fixed size" in exists["mechanism"].getStr() and
             "not its length" in exists["mechanism"].getStr(), e.key & ": " & $exists
    if not part:
      # uncounted, yet its signer's: the facet says both, never that it names no one
      let f = n.attrs["facets"][2]
      doAssert f["class"].getStr() == "not-applicable" and
               f["mechanism"].getStr() == "the fold counts it for nothing; its author signed it, bound to this room",
               e.key & ": " & $f
    # field by field: v, ts, durMs and the digest, each as the part states it, and nothing
    # else; a digest that is no digest is left out, whatever it holds
    let j = parseJson(e.value)
    var keys: seq[string]
    for k, v in n.attrs["content"]:
      keys.add k
      doAssert v == j[k], e.key & ": " & k
    doAssert keys.sorted() == (if eventId(e) == eventId(stuffed): @["durMs", "ts", "v"]
                               else: @["digest", "durMs", "ts", "v"]), e.key & ": " & $keys
    inc credited
  doAssert credited == 18, "Alice's 12 parts, Bob's 2, and the four extras: " & $credited
  doAssert bobPart0Counted == @[eventId(bobPart0[0])],
           "of Bob's two part 0s, only the first by canonical order counts: " & $bobPart0Counted.len
  # the map as coordinate_graph serves it holds no half of any clip, nor any stretch of one:
  # every 48-character window of every half, at a 24-character step and at its end, is looked
  # up among all the served map's 48-character windows, so a stretch of 71 characters or more
  # from anywhere in a half would be found
  let served = $g.toJson()
  const W = 48
  var windows = initHashSet[string]()
  for k in 0 .. served.len - W: windows.incl served[k ..< k + W]
  var looked = 0
  for e in evs:
    if not e.key.startsWith("voice/"): continue
    let half = parseJson(e.value)["part"].getStr()
    doAssert half.len >= W and half notin served, e.key & ": the clip rides the room map"
    var k = 0
    while k + W <= half.len:
      doAssert half[k ..< k + W] notin windows, e.key & ": the clip from " & $k & " rides the room map"
      inc looked
      k += W div 2
    doAssert half[^W .. ^1] notin windows, e.key & ": the clip's end rides the room map"
  doAssert looked > 9_000, $looked
  echo "14. the room map: each part author-signed in its author's name, counted exactly when the fold ",
       "stands it, its content v, ts, durMs and digest alone, no stretch of a clip anywhere in the map; ",
       "an entry that is no note's part is still its signer's, uncounted OK"

# ── 15. provenance: each part a peer message in its author's name (§10) ──────────
block:
  let evs = authenticEvents(bobS.roomEvents() & extras, topic)
  let items = logProvenance(evs, stub, bobS.sealedIn)
  let (_, hello) = newMessageEvent(bob, 1_792_003_200, "hello", 11)
  let said = logProvenance(@[signAuthored(bobKs, topic, hello)], stub)
  doAssert said.len == 1 and said[0].kind == "message"
  var listed = 0
  var epochs: seq[int]
  for i, e in canonicalOrder(evs):
    if not e.key.startsWith("voice/"): continue
    let mine = items.filterIt(it.seq == i)
    if eventId(e) in extraIds:
      doAssert mine.len == 0, e.key & ", no note's part, is none: " & $mine
      continue
    doAssert mine.len == 1, e.key & ": " & $mine.len
    let it = mine[0]
    let p = e.key.split('/')
    doAssert it.cls == icPeerMessage and it.kind == "voice" and it.intentId == "", $it
    doAssert it.account == p[2] and it.accountable, $it
    doAssert it.what == "a voice note (part " & $(parseInt(p[3]) + 1) & " of 2)", it.what
    doAssert it.detail == "" and it.attestation == "", $it
    doAssert it.guarantee == said[0].guarantee, "a message's guarantee: " & it.guarantee
    if eventId(e) in bobS.sealedIn:
      doAssert it.epoch == bobS.sealedIn[eventId(e)], $it
      if it.epoch notin epochs: epochs.add it.epoch
    inc listed
  doAssert listed == 14 and epochs.sorted() == @[0, 1], $listed & " " & $epochs
  echo "15. provenance: each part a peer message in its author's name, accountable as a message is, ",
       "at the epoch that opened it; an entry that is no note's part is none OK"

# ── 16. the memo keeps each part's header: no output changes, no part is parsed twice ─
# What a warm memo saved was the verdicts; the header pass still parsed every part's value
# (about 84 KB of JSON for a 60 s note) on every read (PR 340's review). Now the memo keeps
# each part's header fields by event id, never its half: every fold output is the one a
# fold with no memo gives, in any order and as the set grows, and a part already read is
# never parsed again (voiceParses, the header pass's count on this thread).
block:
  let ts = 1_792_004_000'i64
  let (nidA, a) = signedNote(aliceKs, synthClip(1_500, 80), ts)
  let (nidB, b) = signedNote(bobKs, synthClip(2_500, 81), ts + 1)
  let (nidC, c) = signedNote(aliceKs, synthClip(700, 82), ts + 2)
  let (nidD, d) = signedNote(aliceKs, synthClip(900, 83), ts + 3)
  let (_, e) = signedNote(aliceKs, synthClip(800, 84), ts + 9)
  let bad = signAuthored(aliceKs, topic, withField(stripped(d[1]), "part", parseJson(c[1].value)["part"]))
  let notAPart = signAuthored(aliceKs, topic, withField(stripped(e[0]), "part", %"    AB"))
  let squat = signAuthored(aliceKs, topic, Event(key: "voice/" & "0f".repeat(16) & "/" & alice & "/0/2",
                                                 value: stripped(a[0]).value))
  let wrongN = signAuthored(aliceKs, topic, Event(key: "voice/" & nidA & "/" & alice & "/0/3",
                                                  value: stripped(a[0]).value))
  # an equivocating part 1 of A's that sorts after hers: a later copy, never parsed
  var later: Event
  for salt in 90'u8 .. 220'u8:
    let other = parseJson(signedNote(aliceKs, synthClip(1_500, salt), ts)[1][1].value)["part"]
    let x = signAuthored(aliceKs, topic, withField(stripped(a[1]), "part", other))
    if eventId(x) > eventId(a[1]): (later = x; break)
  doAssert later.key == a[1].key
  let (_, hello) = newMessageEvent(alice, ts + 4, "hello", 8)
  # A and B complete, C arriving, D broken, E's only part no part, a squat, a wrong n, a later copy
  let all = authenticEvents(a & b & @[c[0], d[0], bad, notAPart, squat, wrongN, later,
                                      signAuthored(aliceKs, topic, hello)], topic)
  doAssert all.len == 12, $all.len
  let reached = 9          # the parts the header pass reads: not wrongN (no part's key), not `later`
  let nids = @[nidA, nidB, nidC, nidD, "00".repeat(16)]
  proc outputs(evs: seq[Event], memo: VoiceMemo): string =
    ## every fold output, as text
    var j = %*{"notes": $reduceVoice(evs, memo), "rows": $threadRows(evs, memo),
               "lastTs": threadLastTs(evs, memo)}
    var st: seq[string]
    for id, p in voiceStanding(evs, memo): st.add id & " " & $p
    j["standing"] = %st.sorted()
    for n in nids:
      j["record " & n] = %($voiceRecordOf(evs, n, memo))
      j["note " & n] = %($voiceNoteOf(evs, n, memo))
    $j
  let want = outputs(all, nil)
  doAssert reduceVoice(all).mapIt(it.state) == @[vsComplete, vsComplete, vsArriving, vsBroken]
  # cold: each part read once, whatever the folds; then nothing again
  let memo = newVoiceMemo()
  var p0 = voiceParses()
  doAssert outputs(all, memo) == want
  doAssert voiceParses() - p0 == reached and memo.headers == reached,
           "each part parsed once: " & $(voiceParses() - p0) & ", headers " & $memo.headers
  p0 = voiceParses()
  doAssert outputs(all, memo) == want and voiceParses() == p0, "warm: no part parsed"
  # any order, any duplication, through the warm memo: the same outputs, nothing parsed
  var r = initRand(16)
  for _ in 0 ..< 20:
    var shuffled = all & all[0 .. r.rand(all.len - 1)]
    r.shuffle(shuffled)
    doAssert outputs(shuffled, memo) == want
  doAssert voiceParses() == p0, "a warm memo parses no part in any order: " & $(voiceParses() - p0)
  # as the set grows, one event at a time with one memo throughout: always the memo-less outputs
  let grow = newVoiceMemo()
  for k in 1 .. all.len:
    doAssert outputs(all[0 ..< k], grow) == outputs(all[0 ..< k], nil), "after " & $k & " events"
  doAssert grow.headers == reached
  # a new part: exactly that one is parsed
  let (_, f) = signedNote(bobKs, synthClip(600, 85), ts + 20)
  p0 = voiceParses()
  let grown = outputs(all & f[0 .. 0], memo)
  doAssert voiceParses() - p0 == 1, "the new part alone: " & $(voiceParses() - p0)
  doAssert grown == outputs(all & f[0 .. 0], nil) and memo.headers == reached + 1
  echo "16. a memo of part headers changes no fold output, in any order or as the set grows; ",
       "a part is parsed once, and a new part alone is OK"

# ── 17. the flow, provenance and the room map take the memo too ───────────────────
# PR 340's review, again: coordinate_flow (on the room's 5 s tick) and coordinate_graph (every
# 2 s while the map is open) folded with no memo, so each poll parsed every part's value again,
# once in the flow and twice in the map (its provenance and its flow), and the map once more
# for each entry's content. Each takes the room's memo now. Its output is the memo-less one,
# byte for byte, in any order; a cold memo parses each part's value once, whichever fold reads
# it first, and a warm one parses none. The map's content of a part comes from the header the
# memo holds. An entry under voice/ that holds no part's value (a key of no part's shape, a
# value the fold refuses, an equivocating later copy) the map parses on every call, as it
# parses a message, to show its fields.
block:
  let clean = bobS.roomEvents()
  let parts = clean.countIt(it.key.startsWith("voice/"))
  doAssert parts == 14 and voiceStanding(clean).len == parts, $parts
  proc flowOf(evs: seq[Event], memo: VoiceMemo): string =
    $reduceFlow(evs, stub, founders, bobS.sealedIn, memo)
  proc provOf(evs: seq[Event], memo: VoiceMemo): string =
    $logProvenance(evs, stub, bobS.sealedIn, memo)
  proc mapOf(evs: seq[Event], memo: VoiceMemo): string =
    $reduceRoomGraph(evs, stub, founders, bob, bobS.sealedIn, memo).toJson()
  var p0 = 0
  proc parsed(): int = voiceParses() - p0
  # the room's view: the map first, then each again
  let want = (flowOf(clean, nil), provOf(clean, nil), mapOf(clean, nil))
  let memo = newVoiceMemo()
  p0 = voiceParses()
  doAssert mapOf(clean, memo) == want[2], "the map with a memo is the map without one"
  doAssert parsed() == parts,
           "the map, cold: each part's value once, for its provenance, its flow and its content: " & $parsed()
  p0 = voiceParses()
  doAssert mapOf(clean, memo) == want[2] and flowOf(clean, memo) == want[0] and provOf(clean, memo) == want[1]
  doAssert parsed() == 0, "warm: a second map, the flow and provenance parse 0 parts: " & $parsed()
  doAssert memo.headers == parts
  # the flow alone, from a cold memo, then again
  let fresh = newVoiceMemo()
  p0 = voiceParses()
  doAssert flowOf(clean, fresh) == want[0] and parsed() == parts, "the flow, cold: " & $parsed()
  p0 = voiceParses()
  doAssert flowOf(clean, fresh) == want[0] and parsed() == 0, "the flow, warm: " & $parsed()
  # beside §13's four entries under voice/ that are no note's part
  let evs = authenticEvents(clean & extras, topic)
  let wantX = (flowOf(evs, nil), provOf(evs, nil), mapOf(evs, nil))
  let mx = newVoiceMemo()
  p0 = voiceParses()
  doAssert flowOf(evs, mx) == wantX[0] and provOf(evs, mx) == wantX[1]
  doAssert parsed() == parts + 2,
           "cold: the parts and the two extras of a part's key shape (a refused value, a squatted id), once: " & $parsed()
  p0 = voiceParses()
  doAssert mapOf(evs, mx) == wantX[2] and flowOf(evs, mx) == wantX[0] and provOf(evs, mx) == wantX[1]
  doAssert parsed() == 3,
           "warm: the map parses only the three entries that hold no part's value, for their content: " & $parsed()
  # any order, through the warm memo: the memo-less outputs
  var r = initRand(17)
  for _ in 0 ..< 6:
    var shuffled = evs
    r.shuffle(shuffled)
    doAssert flowOf(shuffled, mx) == wantX[0] and provOf(shuffled, mx) == wantX[1] and
             mapOf(shuffled, mx) == wantX[2]
  echo "17. the flow, provenance and the room map take the memo: each output is the memo-less one, in ",
       "any order; a cold memo parses each part once, a warm one none, and the map parses only an entry ",
       "that holds no part's value OK"

echo "voice_test: all OK"
