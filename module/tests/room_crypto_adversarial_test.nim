## The room's crypto under attack (exo-3b3, the 2026-11-22 audit: P2-01, P2-03, P2-05,
## P2-06, P2-08, FS-2). Every frame here is built the way an attacker could build it and
## published on the topic; the room must not take it. Drives the shipped EpochCrypto and
## CoordinationSession over LocalTransport — no model (P2-09).
##
##   1. a stranger who knows a member's chat id hands them a signed grant of its own
##   2. a member (or ex-member) jumps the epoch far ahead, or to the wrap point
##   3. a removed member keeps writing under the key they held
##   4. a member re-seals someone else's event under an older epoch (back-dating)
##   5. an authored event signed by an identity the room never admitted
##   6. a stranger's grant to a founder alone in a room, and to an inbox
##   7. the journal keeps only what was accepted
##   8. an envelope with no signature (the old wire) is refused

import std/[strutils, sequtils]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/sodium
import ../src/log/log
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/intent_events

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b
proc bytesOf(s: string): seq[byte] = (for c in s: result.add byte(c))
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let carolKs = newInMemoryKeystore(key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"), seed(3))
let malKs   = newInMemoryKeystore(key("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(4))
let eveKs   = newInMemoryKeystore(key("0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"), seed(5))
let (alice, bob, carol, mal, eve) = (aliceKs.encIdentity(), bobKs.encIdentity(),
                                     carolKs.encIdentity(), malKs.encIdentity(), eveKs.encIdentity())

const FrameData = 0x00'u8
const FrameControl = 0x02'u8
const FrameBeaconRequest = 0x05'u8

proc said(s: CoordinationSession, body: string): bool =
  s.log.allEvents().anyIt(it.value == body)

proc room(topic: string, net: LocalNetwork): tuple[a, b, c, m: CoordinationSession] =
  ## Alice founds; Bob, Carol and Mallory ask and are admitted, each over the wire.
  let a = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
  a.announceBeacon()
  var others: seq[CoordinationSession]
  for ks in [bobKs, carolKs, malKs]:
    let s = newCoordinationSession(newLocalTransport(net), newEpochCrypto(ks, topic), topic)
    doAssert s.requestJoin(ks.joinRequestFor(topic, high(uint64)))
    a.admit(ks.encIdentity())
    others.add s
  doAssert others.allIt(it.members().len == 4), "everyone admitted over the wire"
  (a, others[0], others[1], others[2])

# ── 1. a stranger's signed grant to a member: not taken ─────────────────────────
block:
  let topic = "/muster/1/adv-grant/proto"
  let net = newLocalNetwork()
  let (a, b, _, _) = room(topic, net)
  let wire = newLocalTransport(net)                  # Eve: publishes, holds no key of the room
  let before = b.epoch()
  let eveKey = randomKey()
  # the next epoch, a far one, and the wrap point; her roster names Bob and herself
  for ep in [before + 1, before + 5, 0x7fffffff]:
    discard wire.publish(topic, @[FrameControl] &
      grantFrameAs(eveKs, topic, ep, default(array[32, byte]), @[bob, eve], eveKey, bob))
  doAssert b.epoch() == before, "a stranger's grant never moves a member (epoch " & $b.epoch() & ")"
  doAssert eve notin b.members()
  b.publish(Event(key: "msg/after-eve", value: "bob after eve"))
  # whatever Bob sends next is sealed under the room's key, not Eve's
  var eveReads = false
  for m in wire.storeQuery(topic):
    if m.payload.len > 0 and m.payload[0] == FrameData:
      try: (discard secretboxOpen(eveKey, m.payload[1 .. ^1]); eveReads = true)
      except CatchableError: discard
  doAssert not eveReads, "Eve reads nothing Bob sends"
  doAssert a.said("bob after eve"), "the room still reads Bob"
  echo "1. a stranger's signed grant (next, far, and wrap epochs) is refused OK"

# ── 2. epoch jumps and the wrap point, even from a member ───────────────────────
block:
  let topic = "/muster/1/adv-jump/proto"
  let net = newLocalNetwork()
  let (a, b, c, m) = room(topic, net)
  let wire = newLocalTransport(net)
  let cur = b.epoch()
  let malKey = randomKey()
  let prev = keyIdOf(EpochCrypto(m.crypto).heldKey(cur))
  for ep in [cur + 100, 0x7fffffff]:
    for who in [alice, bob, carol]:
      discard wire.publish(topic, @[FrameControl] &
        grantFrameAs(malKs, topic, ep, prev, @[alice, bob, carol, mal], malKey, who))
  doAssert a.epoch() == cur and b.epoch() == cur and c.epoch() == cur,
    "no member jumps past the gap a missed grant allows"
  # an honest admit afterwards still lands everywhere
  a.admit(eve)
  doAssert b.epoch() == cur + 1 and c.epoch() == cur + 1, "the room keeps re-keying normally"
  echo "2. a member's jump far ahead or to the wrap point is refused; the room re-keys after OK"

# ── 3. a removed member keeps writing under the key they held ──────────────────
block:
  let topic = "/muster/1/adv-removed/proto"
  let net = newLocalNetwork()
  let (a, b, c, m) = room(topic, net)
  let held = m.epoch()
  let heldKey = EpochCrypto(m.crypto).heldKey(held)
  a.expel(mal)
  doAssert mal notin c.members() and mal notin b.members()
  # her grant for the next epoch (she was a member of the one it follows) is refused too
  let wire = newLocalTransport(net)
  for who in [bob, carol]:
    discard wire.publish(topic, @[FrameControl] &
      grantFrameAs(malKs, topic, c.epoch() + 1, keyIdOf(heldKey), @[alice, bob, carol, mal], randomKey(), who))
  doAssert mal notin c.members(), "a removed member cannot re-key herself back in"
  # within the grace a frame in flight is taken; past it, nothing she seals is
  RemovalGraceS = -1.0
  let ev = Event(key: "msg/ghost", value: "posted after removal")
  m.publish(ev)                                      # sealed under the key she still holds
  doAssert not c.said("posted after removal") and not b.said("posted after removal"),
    "FS-2: nothing a removed member seals is ingested"
  # signed by her, for the epoch she held, sealed by hand: still refused
  discard wire.publish(topic, @[FrameData] &
    envelopeAs(malKs, topic, held, heldKey, bytesOf("""{"parents":[],"key":"msg/ghost2","value":"by hand"}""")))
  doAssert not c.said("by hand")
  RemovalGraceS = 300.0
  echo "3. a removed member's grant and envelopes are refused (FS-2) OK"

# ── 4. re-sealing someone else's event under an older epoch ────────────────────
block:
  let topic = "/muster/1/adv-backdate/proto"
  let net = newLocalNetwork()
  let (a, b, c, _) = room(topic, net)
  let older = b.epoch()
  let olderKey = EpochCrypto(b.crypto).heldKey(older)
  a.admit(eve)                                       # a new epoch
  let payload = bytesOf("""{"parents":[],"key":"msg/alice-late","value":"alice in the new epoch"}""")
  # Bob takes Alice's bytes and seals them under the older key with Alice's identity —
  # he cannot sign as Alice, so he signs as himself for an epoch Alice did not sign
  let wire = newLocalTransport(net)
  var body = @[2'u8] & alice.toBytes()
  body.add bobKs.edSignRecord(envelopeRecordOf(topic, older, payload))
  body.add payload
  discard wire.publish(topic, @[FrameData] & secretboxSeal(olderKey, body))
  doAssert not c.said("alice in the new epoch"), "an envelope its named sender did not sign is refused"
  echo "4. an envelope re-sealed in someone else's name is refused (P2-08) OK"

# ── 5. an authored event by an identity the room never admitted ────────────────
block:
  let topic = "/muster/1/adv-sockpuppet/proto"
  let net = newLocalNetwork()
  let (a, _, c, m) = room(topic, net)
  let puppetKs = newInMemoryKeystore(seed(9), seed(10))
  let puppet = "0x" & hx(puppetKs.encIdentity().toBytes())
  let (_, msg) = newMessageEvent(puppet, ts = 7, body = "from a puppet", nonce = 1)
  m.publish(signAuthored(puppetKs, topic, msg))      # Mallory, a member, sends it
  let (_, own) = newMessageEvent("0x" & hx(mal.toBytes()), ts = 8, body = "from mallory", nonce = 2)
  m.publishAuthored(malKs, own)
  let bodies = reduceMessages(c.roomEvents()).mapIt(it.body)
  doAssert "from mallory" in bodies, "a member speaks as herself"
  doAssert "from a puppet" notin bodies, "an identity the room never admitted names no one in it"
  discard a
  echo "5. an authored event by a non-member identity is dropped from the room's reads OK"

# ── 6. a founder alone, and an inbox: no grant from a stranger ─────────────────
block:
  let topic = "/muster/1/adv-alone/proto"
  let net = newLocalNetwork()
  let a = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
  let wire = newLocalTransport(net)
  discard wire.publish(topic, @[FrameControl] &
    grantFrameAs(eveKs, topic, 1, default(array[32, byte]), @[alice, eve], randomKey(), alice))
  doAssert a.epoch() == 0 and a.members() == @[alice], "a founder who asked nothing takes no grant"
  # an inbox: a stranger's grant, then a beacon request — no key, no answer
  let inboxTopic = "/muster/1/adv-inbox/proto"
  let inbox = newCoordinationSession(newLocalTransport(net), newEpochJoiner(aliceKs), inboxTopic)
  inbox.markInbox()
  discard wire.publish(inboxTopic, @[FrameControl] &
    grantFrameAs(eveKs, inboxTopic, 1, default(array[32, byte]), @[alice, eve], randomKey(), alice))
  doAssert inbox.epoch() == -1, "an inbox takes no grant (P2-05)"
  let n = wire.storeQuery(inboxTopic).len
  discard wire.publish(inboxTopic, @[FrameBeaconRequest] & randomBytes(16))
  doAssert wire.storeQuery(inboxTopic).len == n + 1, "the inbox answers no beacon request"
  echo "6. a founder alone and an inbox take no stranger's grant (P2-05) OK"

# ── 7. the journal keeps only what was accepted ────────────────────────────────
block:
  let topic = "/muster/1/adv-journal/proto"
  let net = newLocalNetwork()
  let (_, b, _, _) = room(topic, net)
  var kept: seq[seq[byte]]
  b.setJournal(proc(f: seq[byte]) {.gcsafe.} =
    {.cast(gcsafe).}: kept.add f)
  let wire = newLocalTransport(net)
  discard wire.publish(topic, @[FrameControl] &
    grantFrameAs(eveKs, topic, b.epoch() + 1, default(array[32, byte]), @[bob, eve], randomKey(), bob))
  discard wire.publish(topic, @[FrameData] & randomBytes(200))
  doAssert kept.len == 0, "nothing refused reaches the member's journal (P2-06)"
  echo "7. the journal keeps only accepted frames (P2-06) OK"

# ── 8. the old, unsigned wire ──────────────────────────────────────────────────
block:
  let topic = "/muster/1/adv-unsigned/proto"
  let net = newLocalNetwork()
  let (_, b, c, _) = room(topic, net)
  let k = EpochCrypto(b.crypto).heldKey(b.epoch())
  let wire = newLocalTransport(net)
  discard wire.publish(topic, @[FrameData] &
    secretboxSeal(k, bytesOf("""{"parents":[],"key":"msg/unsigned","value":"no signature"}""")))
  doAssert not c.said("no signature"), "an unsigned envelope is refused, even under the room's key"
  echo "8. an unsigned envelope is refused OK"

# ── 9. a removed member's name in a new roster; two re-keys from one epoch (exo-a16) ──
block:
  const topic = "/muster/1/adv-siblings/proto"
  proc carolAt0(): EpochCrypto =
    let a = newEpochCrypto(aliceKs, topic, @[bob, carol, mal])
    result = newEpochJoiner(carolKs, topic)
    result.ingestGrant(a.grantFor(0, carol))
  let k0 = newEpochCrypto(aliceKs, topic, @[bob, carol, mal]).heldKey(0)
  let (keyA, keyB) = (randomKey(), randomKey())
  let without = @[alice, bob, carol]
  # Alice and Bob each re-key Mallory out of epoch 0 at once: two grants for epoch 1
  let gA = grantFrameAs(aliceKs, topic, 1, keyIdOf(k0), without, keyA, carol)
  let gB = grantFrameAs(bobKs, topic, 1, keyIdOf(k0), without, keyB, carol)
  let c1 = carolAt0()
  doAssert c1.ingestControl(gA) and c1.ingestControl(gB)
  let c2 = carolAt0()
  doAssert c2.ingestControl(gB) and c2.ingestControl(gA)
  doAssert c1.heldKey(1) == c2.heldKey(1), "the same epoch 1 whichever grant arrives first"
  doAssert c1.epoch() == 1 and 1 in c1.forkSeen
  # what the losing key sealed still opens
  let loser = (if c1.heldKey(1) == keyA: keyB else: keyA)
  let loserSigner = (if loser == keyA: aliceKs else: bobKs)
  discard c1.open(envelopeAs(loserSigner, topic, 1, loser, bytesOf("sealed under the other key")))
  # once the room has removed Mallory, no roster naming her is taken
  let c3 = carolAt0()
  c3.setBanned(proc(): seq[Member] {.gcsafe.} = @[mal])
  doAssert not c3.ingestControl(grantFrameAs(aliceKs, topic, 1, keyIdOf(k0), @[alice, bob, carol, mal], randomKey(), carol)),
    "a roster naming a removed member is refused"
  doAssert c3.ingestControl(grantFrameAs(aliceKs, topic, 1, keyIdOf(k0), without, randomKey(), carol))
  echo "9. sibling re-keys converge on one epoch; a removed member's name in a roster is refused OK"

echo "room_crypto_adversarial_test: all OK"
