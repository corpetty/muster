## Fixed-size sealed frames (docs/design/voice-notes.md §4, §5; S4).
##   1. every `voice/` frame is exactly 1 + 24 + 16 + 90,112 = 90,153 B, though no caller
##      passes a pad: for a 1 KB and a worst-case 84 KB value, with `after` holding 0, 1 and
##      8 (MaxHeads) heads, and on the held path (the same event published again, as a
##      retried Send would). Inside, the event's JSON and then ASCII spaces only. The
##      worst case's JSON is measured and printed (§5's budget is arithmetic). The key's
##      first segment decides: a bare `voice` key is padded, `voicemail/…` is not.
##   2. a padded frame opens and decodes through the unchanged ingest path, a member's live
##      receive and a replay of the journal, into the identical event (same id, `after`
##      and `afterSig`)
##   3. what does not fit raises before anything happens: a `voice/` event over 90,112 B
##      and an event over an explicit padTo raise FrameTooLarge, and a `voice/` key with
##      any other non-zero padTo (or any negative one) raises ValueError. Each time the log
##      does not hold it, its heads are unchanged, the journal saw nothing, the transport
##      published nothing and the other member holds nothing. At the boundary, a pad of
##      exactly the JSON's length fits with no space, one byte less raises.
##   4. padTo = 0, the default, is today's frame for every other key, byte for byte: the
##      plaintext is the event's JSON exactly, held to literals, and the frame 41 B more
##   5. a pad changes nothing anything signs: an author-signed message (publishAuthored's
##      steps: signAuthored, then the heads and signAfter) published with a pad reaches the
##      other member, whose roomEvents keeps it with its signed `after`, under the same id
## LocalTransport + epoch crypto; needs libsecp256k1 + libsodium.

import std/[base64, json, strutils]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/intent_events

const
  Seal = 1 + 24 + 16                ## kind byte, secretbox nonce and MAC
  WireBytes = Seal + 90_112         ## every voice frame on the wire

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc toStr(b: openArray[byte]): string = (for x in b: result.add char(x))

type
  Wire = ref object
    frames: seq[seq[byte]]   ## every frame published on the topic, as a store node holds them
  Room = ref object
    s: CoordinationSession
    c: EpochCrypto
    w: Wire
    journal: seq[seq[byte]]  ## every frame the session handed its journal (room_journal)

proc tap(net: LocalNetwork, topic: string): Wire =
  ## A plain subscriber on the topic: it sees every frame any member publishes.
  let w = Wire()
  newLocalTransport(net).subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} =
    w.frames.add m.payload)
  w

proc dataFrames(w: Wire): seq[seq[byte]] =
  for f in w.frames: (if f.len > 0 and f[0] == 0x00'u8: result.add f)

proc opened(c: EpochCrypto, frame: seq[byte]): seq[byte] = c.openedEpoch(frame[1 .. ^1]).plain

proc jsonEnd(plain: seq[byte]): int =
  ## The length of the event's JSON, found without trusting what follows it: the whole
  ## plaintext parsed as decodeEvent parses it, then written back out (encodeEvent's `$`).
  ## parseJson also takes trailing NULs, so stripping spaces would find nothing to check.
  let text = $parseJson(toStr(plain))
  doAssert toStr(plain[0 ..< text.len]) == text, "the frame opens with the event's JSON"
  text.len

proc jsonOf(plain: seq[byte]): JsonNode = parseJson(toStr(plain[0 ..< jsonEnd(plain)]))

proc voiceValue(partBytes: int): string =
  ## A part's value in §3.3's shape: every field present, the part `partBytes` of clip as
  ## base64. 63,060 B is the larger half of a 60 s clip (§5), 84,080 base64 characters.
  var raw = newSeq[byte](partBytes)
  for i in 0 ..< partBytes: raw[i] = byte((i * 131 + 7) and 0xFF)
  $(%*{"v": 1, "ts": 1_792_000_000, "durMs": 60_000, "digest": "ab".repeat(32),
        "part": encode(raw), "authorSig": "cd".repeat(64)})

let aliceKs = newInMemoryKeystore(seed(0x31), seed(0x41))
let bobKs = newInMemoryKeystore(seed(0x32), seed(0x42))
let aliceHex = hex(aliceKs.encIdentity().toBytes())
doAssert aliceHex.len == 128
let nid = "0f".repeat(16)
proc voiceKey(i: int): string = "voice/" & nid & "/" & aliceHex & "/" & $i & "/2"

proc withJournal(r: Room): Room =
  let rr = r
  r.s.setJournal(proc (f: seq[byte]) {.gcsafe.} = rr.journal.add f)
  r

proc lone(topic: string): Room =
  ## A founder alone in a fresh room: its log is empty, so its first event names no heads.
  let net = newLocalNetwork()
  let c = newEpochCrypto(aliceKs, topic)
  withJournal(Room(s: newCoordinationSession(newLocalTransport(net), c, topic), c: c, w: tap(net, topic)))

proc pair(topic: string): (Room, CoordinationSession) =
  ## Alice founds the room and admits Bob, so a frame she sends reaches a second member.
  let net = newLocalNetwork()
  let c = newEpochCrypto(aliceKs, topic)
  let alice = withJournal(Room(s: newCoordinationSession(newLocalTransport(net), c, topic), c: c))
  let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
  bob.requestJoin(bobKs.joinRequestFor(topic, high(uint64)))
  alice.s.admit(bobKs.encIdentity())
  doAssert bob.members().len == 2
  alice.w = tap(net, topic)
  (alice, bob)

proc publishSignedAfter(s: CoordinationSession, e: Event) =
  ## What publishAuthored does to a new event's order: the heads, signed (C5). A voice part
  ## carries both, so the worst case has them; S5 signs the part itself.
  var c = e
  c.after = s.heads()
  s.publish(signAfter(aliceKs, s.topic, c))

var worstJson = 0

block:
  doAssert VoiceFrameBytes == 90_112
  for (valueName, partBytes) in [("1 KB", 768), ("84 KB", 63_060)]:
    let value = voiceValue(partBytes)
    doAssert (if partBytes == 768: value.len in 1_000 .. 1_400 else: value.len in 84_080 .. 84_500), $value.len
    for heads in [0, 1, MaxHeads]:
      let r = lone("/muster/1/session-pad-" & $partBytes & "-" & $heads & "/proto")
      if heads == 1: r.s.publish(Event(key: "msg/before", value: "1"))
      # concurrent events, as from that many members at once: none names another, so the
      # log has more heads than a new event may name, and publish names MaxHeads of them
      if heads == MaxHeads:
        for k in 0 ..< MaxHeads + 4: r.s.log.ingest(Event(key: "msg/concurrent/" & $k, value: $k))
      doAssert r.s.heads().len == heads, $r.s.heads().len
      let before = r.w.dataFrames().len
      let ev = Event(key: voiceKey(1), value: value)
      if heads == 0: r.s.publish(ev) else: r.s.publishSignedAfter(ev)
      let sent = r.w.dataFrames()
      doAssert sent.len == before + 1, $sent.len
      let frame = sent[^1]
      doAssert frame.len == WireBytes, valueName & ", " & $heads & " heads: a " & $frame.len & " B frame"
      doAssert frame in r.journal, "the journal keeps the frame that was sent"
      let plain = r.c.opened(frame)
      doAssert plain.len == VoiceFrameBytes, $plain.len
      let n = jsonEnd(plain)
      for b in plain[n .. ^1]: doAssert b == byte(' ')
      let j = jsonOf(plain)
      doAssert j["key"].getStr() == ev.key and j["value"].getStr() == value
      doAssert (if heads == 0: not j.hasKey("after") else: j["after"].len == heads)
      doAssert (if heads == 0: not j.hasKey("afterSig") else: j["afterSig"].getStr().len == 128)
      if heads == MaxHeads and partBytes == 63_060: worstJson = n
      # the held path: the same note sent again (a retried Send, a re-announce) is
      # re-sealed as the stored copy, and is padded the same, since the key decides
      r.s.publish(ev)
      let again = r.w.dataFrames()
      doAssert again.len == sent.len + 1
      doAssert again[^1].len == WireBytes, "held path: a " & $again[^1].len & " B frame"
      doAssert jsonOf(r.c.opened(again[^1])) == j, "the held path re-seals the stored copy"
  doAssert worstJson > 0
  # the key's first segment decides, as authorOf classifies a kind (authorship.nim)
  let r = lone("/muster/1/session-pad-segment/proto")
  r.s.publish(Event(key: "voice", value: "{}"))
  doAssert r.w.dataFrames()[^1].len == WireBytes, "a bare voice key is a voice key"
  r.s.publish(Event(key: "voicemail/1", value: "{}"))
  doAssert r.w.dataFrames()[^1].len < 200, "voicemail/ is not a voice key"
  echo "1. every voice/ frame is ", WireBytes, " B: 1 KB and 84 KB values, 0, 1 and ",
       MaxHeads, " heads, the held path; worst-case event JSON ", worstJson,
       " B, margin ", VoiceFrameBytes - worstJson, " B OK"

block:
  let (alice, bob) = pair("/muster/1/session-pad-ingest/proto")
  let ev = Event(key: voiceKey(0), value: voiceValue(63_060))
  alice.s.publishSignedAfter(ev)
  doAssert alice.w.dataFrames().len == 1 and alice.w.dataFrames()[0].len == WireBytes
  let id = eventId(ev)
  let sent = alice.s.log.find(id)
  doAssert sent.found and sent.event.after.len > 0 and sent.event.afterSig.len == 128
  let got = bob.log.find(id)
  doAssert got.found, "a member reads a padded frame through the ingest path"
  doAssert eventId(got.event) == id
  doAssert got.event.key == sent.event.key and got.event.value == sent.event.value
  doAssert got.event.parents == sent.event.parents
  doAssert got.event.after == sent.event.after and got.event.afterSig == sent.event.afterSig
  # a relaunch replays the member's own copy through the same ingest
  let again = newCoordinationSession(newLocalTransport(newLocalNetwork()), alice.c, alice.s.topic)
  again.replay(alice.journal)
  let replayed = again.log.find(id)
  doAssert replayed.found and replayed.event.value == sent.event.value
  doAssert replayed.event.after == sent.event.after and replayed.event.afterSig == sent.event.afterSig
  echo "2. a padded frame decodes through the unchanged ingest path, live and replayed, into the same event OK"

proc refusedBefore(r: Room, peer: CoordinationSession, E: typedesc, ev: Event, pad: int, what: string) =
  ## publish(ev, padTo = pad) raises E, and nothing happened: the log, its heads, the
  ## journal, the topic and the other member (when there is one) are as they were.
  let logBefore = r.s.log.allEvents().len
  let headsBefore = r.s.heads()
  let wireBefore = r.w.frames.len
  let journalBefore = r.journal.len
  let peerBefore = (if peer == nil: 0 else: peer.log.allEvents().len)
  doAssertRaises(E): r.s.publish(ev, padTo = pad)
  doAssert not r.s.log.find(eventId(ev)).found, what & ": the log holds it"
  doAssert r.s.log.allEvents().len == logBefore and r.s.heads() == headsBefore, what & ": the log changed"
  doAssert r.journal.len == journalBefore, what & ": the journal saw it"
  doAssert r.w.frames.len == wireBefore, what & ": the transport published it"
  if peer != nil:
    doAssert peer.log.allEvents().len == peerBefore and not peer.log.find(eventId(ev)).found,
             what & ": the other member holds it"

block:
  let (alice, bob) = pair("/muster/1/session-pad-refuse/proto")
  # 70,000 B of clip is 93,336 base64 characters: past the pad whatever the heads
  refusedBefore(alice, bob, FrameTooLarge, Event(key: voiceKey(0), value: voiceValue(70_000)), 0,
                "a voice/ event over VoiceFrameBytes")
  refusedBefore(alice, bob, FrameTooLarge, Event(key: "msg/big", value: "x".repeat(5_000)), 4_096,
                "an event over its padTo")
  refusedBefore(alice, bob, ValueError, Event(key: voiceKey(0), value: voiceValue(768)), 4_096,
                "a voice/ key with another pad")
  refusedBefore(alice, bob, ValueError, Event(key: "msg/neg", value: "1"), -1, "a negative pad")
  # the one pad a voice/ key accepts is its own, said or not
  alice.s.publish(Event(key: voiceKey(1), value: voiceValue(768)), padTo = VoiceFrameBytes)
  doAssert alice.w.dataFrames()[^1].len == WireBytes
  doAssert bob.log.find(eventId(Event(key: voiceKey(1), value: voiceValue(768)))).found
  # the boundary, in three fresh rooms that each publish the same event with no heads
  let ev = Event(key: "msg/edge", value: "the boundary")
  let r0 = lone("/muster/1/session-pad-edge/proto")
  r0.s.publish(ev)
  let exact = r0.c.opened(r0.w.dataFrames()[^1])
  let r1 = lone("/muster/1/session-pad-edge/proto")
  r1.s.publish(ev, padTo = exact.len)
  doAssert r1.w.dataFrames()[^1].len == Seal + exact.len
  doAssert r1.c.opened(r1.w.dataFrames()[^1]) == exact, "a pad of exactly the JSON adds no space"
  let r2 = lone("/muster/1/session-pad-edge/proto")
  refusedBefore(r2, nil, FrameTooLarge, ev, exact.len - 1, "one byte over")
  echo "3. FrameTooLarge (and a wrong pad) raise before the log, the journal or the transport see anything; ",
       "a pad of exactly the JSON fits OK"

block:
  let r = lone("/muster/1/session-pad-zero/proto")
  let first = Event(key: "msg/golden", value: """{"a":1}""")
  r.s.publish(first)
  let f1 = r.w.dataFrames()[^1]
  const golden1 = """{"parents":[],"key":"msg/golden","value":"{\"a\":1}"}"""
  doAssert toStr(r.c.opened(f1)) == golden1, toStr(r.c.opened(f1))
  doAssert f1.len == Seal + golden1.len
  r.s.publish(Event(key: "voicemail/2", value: "2"), padTo = 0)
  let f2 = r.w.dataFrames()[^1]
  let golden2 = """{"parents":[],"key":"voicemail/2","value":"2","after":["""" & eventId(first) & """"]}"""
  doAssert toStr(r.c.opened(f2)) == golden2, toStr(r.c.opened(f2))
  doAssert f2.len == Seal + golden2.len
  r.s.publish(Event(parents: @[eventId(first)], key: "msg/child", value: "3"))
  let golden3 = """{"parents":["""" & eventId(first) & """"],"key":"msg/child","value":"3","after":["""" &
                eventId(Event(key: "voicemail/2", value: "2")) & """"]}"""
  doAssert toStr(r.c.opened(r.w.dataFrames()[^1])) == golden3, toStr(r.c.opened(r.w.dataFrames()[^1]))
  echo "4. padTo = 0 is today's frame for every other key, byte for byte OK"

block:
  let (alice, bob) = pair("/muster/1/session-pad-signed/proto")
  let topic = alice.s.topic
  let (_, msg) = newMessageEvent(aliceHex, 1_792_000_000, "padded, and still signed", 1)
  var signed = signAuthored(aliceKs, topic, msg)
  signed.after = alice.s.heads()
  signed = signAfter(aliceKs, topic, signed)
  alice.s.publish(signed, padTo = 8_192)
  let frame = alice.w.dataFrames()[^1]
  doAssert frame.len == Seal + 8_192
  doAssert toStr(alice.c.opened(frame)).endsWith("    ")
  var seen = false
  for e in roomEvents(bob):
    if eventId(e) == eventId(signed):
      seen = true
      doAssert e.value == signed.value and authorVerified(topic, e)
      doAssert e.after == signed.after, "the signed after is kept: its signature verified"
  doAssert seen, "the author signature verifies through the pad"
  echo "5. a padded author-signed event keeps its id and both signatures OK"
