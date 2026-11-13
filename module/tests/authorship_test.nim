## exo-f76 — an author-bearing log event counts only when its author signed it.
##
## Epoch sealing proves a member sent an event, not which one, so before this any
## member could post a chat message, a decline, a material share, an account
## disclosure or a FROST ceremony join in another member's name, and every view named
## the victim (invariant 9: "members know who approved, declined, or shared"). Now each
## of those kinds carries its author's Ed25519 signature over a domain-separated record
## of (room, key, parents, author, the value's dCBOR), and the room's read path drops
## any whose signature does not verify. Other kinds pass through untouched: approvals
## are verified by their driver, and the rest name no author.
##
## §11 (voice-notes.md §3.3): a voice note's part names its author in its key, so its
## author is read off the key and every `voice` shape is author-bearing.
##
## §12 (voice-notes.md §4): a re-announce of an author-signed event re-seals the copy whose
## `after` its author signed, never a copy another member planted that the log keeps, for an
## account disclosure as for a voice part; every member, a later joiner included, converges.
##
## Needs $SECP + $STINT + libsodium (tests/README.md; run-suite.sh supplies them).

import std/[json, strutils, algorithm, sequtils]
import ../src/log/log
import ../src/drivers/driver
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/accounts
import ../src/coordination/authorship

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let victorKs  = newInMemoryKeystore(seed(0x11), seed(0x21))
let malloryKs = newInMemoryKeystore(seed(0x12), seed(0x22))
let aliceKs   = newInMemoryKeystore(seed(0x13), seed(0x23))
let victor  = hex(victorKs.encIdentity().toBytes())
let mallory = hex(malloryKs.encIdentity().toBytes())

const roomA = "/muster/1/room-a/proto"
const roomB = "/muster/1/room-b/proto"

let effectJson = """{"to":"0xabc","value":5}"""
let intentId = intentIdFor(effectJson)
let stub: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 2, verifyResult = true)

proc decliners(events: seq[Event]): seq[string] =
  for v in reduceIntentViews(events, stub):
    if v.id == intentId: return v.decliners

proc account(): RoomAccount =
  RoomAccount(family: "evm.safe", chain: "eip155:31337",
              address: "0xeb4520e32862d2adfa2af042f0b5ea2041dee841", label: "the Safe",
              signers: @["0xf39fd6e51aad88f6f4ce6aa8827279cfffb92266"], threshold: 1)

proc frostJoin(cid, who: string): Event =
  Event(key: "frost/" & cid & "/join/" & who, value: $(%*{"host": "02" & "ab".repeat(32)}))

proc forgedBy(ks: Keystore, room: string, e: Event): Event =
  ## A member signs a claim that names someone else: the signature is well-formed,
  ## but it is not the named author's.
  var j = (try: parseJson(e.value) except CatchableError: newJObject())
  if j.kind != JObject: j = newJObject()
  j[AuthorSigField] = %hex(ks.edSign(authorDigest(room, e)))
  Event(parents: e.parents, key: e.key, value: $j)

let propose = proposeEvent(intentId, effectJson)
let (_, victorMsg) = newMessageEvent(victor, ts = 100, body = "I approve", nonce = 1)
let genuine = @[
  signAuthored(victorKs, roomA, declineEvent(intentId, victor)),
  signAuthored(victorKs, roomA, victorMsg),
  signAuthored(victorKs, roomA, materialShareEvent(intentId, "payee", victor,
                                                   "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
                                                   "evm-address", "address", "to")),
  signAuthored(victorKs, roomA, accountDiscloseEvent(account(), victor)),
  signAuthored(victorKs, roomA, frostJoin("c1", victor))]

# ── 1. the author's own signed events all count ──────────────────────────────────
block:
  for e in genuine:
    doAssert authorOf(e).authored and authorOf(e).author == victor, e.key
    doAssert authorVerified(roomA, e), "genuine " & e.key
  let evs = authenticEvents(@[propose] & genuine, roomA)
  doAssert evs.len == genuine.len + 1, "nothing genuine is dropped"
  doAssert decliners(evs) == @[victor]
  doAssert reduceMessages(evs).mapIt(it.author) == @[victor]
  doAssert reduceShares(evs, intentId).mapIt(it.who) == @[victor]
  doAssert reduceAccounts(evs)[0].disclosedBy == @[victor]
  echo "1. the author's own signed decline, message, share, disclosure and join all count OK"

# ── 2. an unsigned event naming another member is dropped ─────────────────────────
let (_, forgedMsg) = newMessageEvent(victor, ts = 101, body = "send it all to mallory", nonce = 2)
let unsigned = @[declineEvent(intentId, victor), forgedMsg,
                 materialShareEvent(intentId, "payee", victor, "0xmallory", "evm-address", "address", "to"),
                 accountDiscloseEvent(account(), victor), frostJoin("c1", victor)]
block:
  for e in unsigned:
    doAssert authorOf(e).authored, "classified as author-bearing: " & e.key
    doAssert not authorVerified(roomA, e), "unsigned " & e.key
  let evs = authenticEvents(@[propose] & unsigned, roomA)
  doAssert evs.len == 1, "only the propose survives (" & $evs.len & ")"
  doAssert decliners(evs).len == 0 and reduceMessages(evs).len == 0
  doAssert reduceShares(evs, intentId).len == 0 and reduceAccounts(evs).len == 0
  echo "2. unsigned decline / message / share / disclosure / join in another's name: dropped OK"

# ── 3. a member's own signature over a claim naming someone else is dropped ───────
block:
  let forged = unsigned.mapIt(forgedBy(malloryKs, roomA, it))
  for e in forged:
    doAssert not authorVerified(roomA, e), "signed by the wrong member: " & e.key
  doAssert authenticEvents(forged, roomA).len == 0
  doAssertRaises(CatchableError):
    discard signAuthored(malloryKs, roomA, declineEvent(intentId, victor))
  echo "3. signed by a member other than the one it names: dropped; signAuthored refuses OK"

# ── 4. a genuine event replayed into another room is dropped ─────────────────────
block:
  for e in genuine:
    doAssert not authorVerified(roomB, e), "replayed into room B: " & e.key
  doAssert authenticEvents(genuine, roomB).len == 0
  echo "4. cross-room replay of a genuine signed event: dropped OK"

# ── 5. tampering with the body or the parents breaks the signature ───────────────
block:
  let signed = signAuthored(victorKs, roomA, victorMsg)
  var j = parseJson(signed.value)
  j["body"] = %"I approve sending everything to mallory"
  doAssert not authorVerified(roomA, Event(parents: signed.parents, key: signed.key, value: $j))
  let moved = Event(parents: @["deadbeef"], key: signed.key, value: signed.value)
  doAssert not authorVerified(roomA, moved), "parents are part of the claim"
  echo "5. an edited body or re-parented event fails verification OK"

# ── 6. malformed signatures and values are rejected, never raised (exo-cf7) ──────
block:
  let base = declineEvent(intentId, victor)
  for bad in [$(%*{AuthorSigField: "zz"}), $(%*{AuthorSigField: "00"}),
              $(%*{AuthorSigField: 42}), "1", "not json", "[]",
              $(%*{AuthorSigField: "ab".repeat(64), "x": 1.5})]:
    doAssert not authorVerified(roomA, Event(key: base.key, value: bad)), bad
  doAssert not authorVerified(roomA, Event(key: "intent/" & intentId & "/decline/zz",
                                           value: $(%*{AuthorSigField: "ab".repeat(64)})))
  echo "6. malformed signature / value / author: rejected without raising OK"

# ── 7. key shapes a fold reads cannot slip past the classification ───────────────
block:
  for k in ["intent/" & intentId & "/decline/" & victor & "/extra",
            "intent/" & intentId & "/decline",
            "intent/" & intentId & "/material/payee/" & victor & "/extra",
            "account/eip155:1:0xabc/disclose/" & victor & "/x",
            "frost/c1/join/" & victor & "/x", "message/abc"]:
    doAssert authorOf(Event(key: k, value: "{}")).authored, "author-bearing shape: " & k
    doAssert authenticEvents(@[Event(key: k, value: "{}")], roomA).len == 0, k
  echo "7. every key shape a fold reads as author-bearing is classified and dropped unsigned OK"

# ── 8. kinds that name no author pass through untouched ──────────────────────────
block:
  let others = @[propose, policyDeclEvent(intentId, "stub"), contributeEvent(intentId, victor, "aa"),
                 submitEvent(intentId), finalEvent(intentId), membershipEvent(1, victor)]
  for e in others: doAssert not authorOf(e).authored, e.key
  doAssert authenticEvents(others, roomA).mapIt(it.key) == others.mapIt(it.key)
  echo "8. propose / policy / contribute / submit / final / membership pass through OK"

# ── 9. convergence: the filter is a pure function of the event set (inv 4) ───────
block:
  let mixed = @[propose] & genuine & unsigned
  var shuffled = mixed.reversed()
  shuffled.add genuine[0]
  doAssert decliners(authenticEvents(mixed, roomA)) == decliners(authenticEvents(shuffled, roomA))
  doAssert reduceMessages(authenticEvents(mixed, roomA)).mapIt(it.id) ==
           reduceMessages(authenticEvents(shuffled, roomA)).mapIt(it.id)
  echo "9. reorder + duplicate → identical authentic view (inv 4) OK"

# ── 10. the room's read path: a member forges over the wire, the others drop it ──
block:
  let net = newLocalNetwork()
  let vMem = victorKs.encIdentity()
  let mMem = malloryKs.encIdentity()
  let aliceCrypto = newEpochCrypto(aliceKs, roomA, @[vMem, mMem])
  let victorCrypto = newEpochJoiner(victorKs)
  let malloryCrypto = newEpochJoiner(malloryKs)
  victorCrypto.ingestGrant(aliceCrypto.grantFor(0, vMem))
  malloryCrypto.ingestGrant(aliceCrypto.grantFor(0, mMem))
  let a = newCoordinationSession(newLocalTransport(net), aliceCrypto, roomA)
  let v = newCoordinationSession(newLocalTransport(net), victorCrypto, roomA)
  let m = newCoordinationSession(newLocalTransport(net), malloryCrypto, roomA)
  a.publish(propose)
  m.publish(declineEvent(intentId, victor))                         # Mallory, in Victor's name
  m.publish(forgedBy(malloryKs, roomA, forgedMsg))                  # …and with her own key
  v.publishAuthored(victorKs, materialShareEvent(intentId, "payee", victor, "0x7099", "evm-address", "address", "to"))
  let (_, hello) = newMessageEvent(victor, ts = 5, body = "hello", nonce = 3)
  v.publishAuthored(victorKs, hello)
  a.poll()
  doAssert a.log.allEvents().len == 5, "the log keeps everything it received (" & $a.log.allEvents().len & ")"
  let seen = a.roomEvents()
  doAssert decliners(seen).len == 0, "the forged decline never names Victor"
  doAssert reduceMessages(seen).mapIt(it.body) == @["hello"], "only Victor's own message"
  doAssert reduceShares(seen, intentId).mapIt(it.who) == @[victor]
  echo "10. over the wire: the log keeps the forgeries, the room's reads drop them OK"

# ── 11. a voice note's part names its author in its key (voice-notes.md §3.3) ────
# authorOf reads the key, never the value (a part's value is about 84 KB of base64), so a
# value naming someone else changes nothing, and every shape under `voice` is author-bearing:
# one too short to name an author can never verify. `voicemail/` is another kind.
block:
  let nid = "0f".repeat(16)
  let part = "voice/" & nid & "/" & victor & "/0/2"
  for k in [part, "voice/" & nid, "voice/" & nid & "/" & victor & "/x", "voice/", "voice"]:
    let e = Event(key: k, value: "{}")
    doAssert authorOf(e).authored, "author-bearing shape: " & k
    doAssert authenticEvents(@[e], roomA).len == 0, "dropped unsigned: " & k
  doAssert authorOf(Event(key: part, value: "not json")).author == victor
  doAssert authorOf(Event(key: "voice/" & nid, value: "{}")).author == ""
  doAssert not authorOf(Event(key: "voicemail/" & nid, value: "{}")).authored
  let claim = Event(key: part, value: $(%*{"v": 1, "author": mallory}))
  doAssert authorOf(claim).author == victor, "the key names the author, not the value"
  let signed = signAuthored(victorKs, roomA, claim)
  doAssert authorVerified(roomA, signed) and authenticEvents(@[signed], roomA).len == 1
  doAssert not authorVerified(roomB, signed), "bound to its room"
  doAssert not authorVerified(roomA, forgedBy(malloryKs, roomA, claim)), "Mallory's signature under Victor's key"
  doAssertRaises(CatchableError):
    discard signAuthored(malloryKs, roomA, claim)
  echo "11. a voice/ part names its author in its key: every shape is author-bearing, only that member's signature counts OK"

# ── 12. a re-announce re-seals the author's own copy, for every author-signed kind ────
# publishAuthored for an event the log already holds seals the copy whose `after` its author
# signed (authorship.copyToSeal), not the copy the log keeps (the smallest afterDigest),
# which any member who received the event can plant. Voice notes needed it (voice-notes.md
# §4; voice_live_test §24); it holds for every kind publishAuthored signs, an account
# disclosure here, re-announced for a member admitted later.
block:
  const roomC = "/muster/1/room-c/proto"
  let carolKs = newInMemoryKeystore(seed(0x14), seed(0x24))
  let carol = carolKs.encIdentity()
  let net = newLocalNetwork()
  let (vMem, mMem) = (victorKs.encIdentity(), malloryKs.encIdentity())
  let aliceCrypto = newEpochCrypto(aliceKs, roomC, @[vMem, mMem])
  let victorCrypto = newEpochJoiner(victorKs)
  let malloryCrypto = newEpochJoiner(malloryKs)
  victorCrypto.ingestGrant(aliceCrypto.grantFor(0, vMem))
  malloryCrypto.ingestGrant(aliceCrypto.grantFor(0, mMem))
  let a = newCoordinationSession(newLocalTransport(net), aliceCrypto, roomC)
  let v = newCoordinationSession(newLocalTransport(net), victorCrypto, roomC)
  let m = newCoordinationSession(newLocalTransport(net), malloryCrypto, roomC)
  a.publish(propose)
  let disclose = accountDiscloseEvent(account(), victor)
  v.publishAuthored(victorKs, disclose)
  let id = eventId(signAuthored(victorKs, roomC, disclose))
  let own = v.log.find(id).event
  doAssert own.after.len > 0 and afterVerified(roomC, own), "Victor's copy names what he had seen, signed"
  # Mallory, who received it, sends a copy of her own: the same event, an `after` of ids she
  # made up and nobody signed, ground until it sorts first, so every log keeps her copy
  var planted = m.log.find(id).event
  var n = 0
  while true:
    inc n
    planted.after = @["ab".repeat(31) & ($n).align(2, '0'), "cd".repeat(32)]
    planted.afterSig = ""
    if afterDigest(planted) < afterDigest(own): break
  var j = %*{"parents": planted.parents, "key": planted.key, "value": planted.value}
  j["after"] = %planted.after
  var plain: seq[byte]
  for c in $j: plain.add byte(c)
  discard newLocalTransport(net).publish(roomC, @[0x00'u8] & malloryCrypto.seal(plain))
  doAssert v.log.find(id).event.after == planted.after, "Victor's log keeps Mallory's copy"
  doAssert a.log.find(id).event.after == planted.after
  # Carol is admitted: a new epoch she alone opens from here on, and Victor discloses the
  # account again for her, as a re-announce does
  aliceCrypto.addMember(carol)
  victorCrypto.ingestGrant(aliceCrypto.grantFor(1, vMem))
  malloryCrypto.ingestGrant(aliceCrypto.grantFor(1, mMem))
  let carolCrypto = newEpochJoiner(carolKs)
  carolCrypto.ingestGrant(aliceCrypto.grantFor(1, carol))
  let c = newCoordinationSession(newLocalTransport(net), carolCrypto, roomC)
  doAssert not c.log.find(id).found, "nothing from before Carol's epoch opens"
  v.publishAuthored(victorKs, disclose)
  let got = c.log.find(id)
  doAssert got.found, "Carol receives the re-announce"
  doAssert got.event.after == own.after and got.event.afterSig == own.afterSig,
           "the author's own copy, not the one the log keeps: " & $got.event.after
  # and the members converge: each reads Victor's disclosure, with Victor's own order
  for (who, s) in {"Alice": a, "Victor": v, "Mallory": m, "Carol": c}:
    var seen: seq[Event]
    for e in s.roomEvents(): (if eventId(e) == id: seen.add e)
    doAssert seen.len == 1 and seen[0].after == own.after and seen[0].afterSig == own.afterSig, who & ": " & $seen
    doAssert reduceAccounts(s.roomEvents()).mapIt(it.disclosedBy) == @[@[victor]], who
  echo "12. a re-announced account disclosure re-seals the author's own copy, not a member's planted ",
       "one the log keeps; every member, a later joiner included, reads it with the author's order OK"

echo "authorship_test: all OK"
