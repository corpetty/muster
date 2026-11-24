## Publishing in causal order (C3, exo-88e; docs/design/causal-parents.md §3.2–3.4).
##   1. a new event names the publisher's heads in `after`, and a peer receives it so
##   2. the session's causalOrder is the order events were published (canonical is not)
##   3. re-publishing an event the log holds re-seals the stored copy, original `after`
##      included — a joiner given a re-announce learns the true order
##   4. an author-signed event still verifies after `after` is stamped
##   5. a caller's `parents` are kept exactly
##   6. the activity feed reads proposals in the order they were made
##   7. the room history reads as it happened (exo-9e3): an admission, one proposal's
##      whole lifecycle, then a later proposal whose id sorts first — content-id order
##      listed the later group first; causal order lists them as they happened
## LocalTransport + epoch crypto; needs libsecp256k1 + libsodium.

import std/[strutils, sequtils, algorithm]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/intents
import ../src/drivers/driver

proc key(h: string): array[32, byte] = (for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1])))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs = newInMemoryKeystore(key("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs = newInMemoryKeystore(key("59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let carolKs = newInMemoryKeystore(key("7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(3))
const topic = "/muster/1/causal-publish/proto"
let net = newLocalNetwork()
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
let ctx = LinkContext(account: "room", slot: "0", expiry: high(uint64))
bob.requestJoin(bobKs.joinRequestFor(topic, high(uint64)))
alice.admitAs(aliceKs, bobKs.encIdentity())

proc held(s: CoordinationSession, k: string): Event =
  for e in s.log.allEvents(): (if e.key == k: return e)
  doAssert false, "not held: " & k

block:
  alice.publish(Event(key: "msg/one", value: "1"))
  alice.publish(Event(key: "msg/two", value: "2"))
  let one = alice.held("msg/one")
  doAssert alice.held("msg/two").after == @[eventId(one)], $alice.held("msg/two").after
  doAssert bob.held("msg/two").after == @[eventId(one)], "the peer receives after over the wire"
  echo "1. a new event names the publisher's heads, and a peer receives them OK"

block:
  var order: seq[string]
  for i in 0 ..< 8:
    let k = "msg/seq" & $i
    (if i mod 2 == 0: alice else: bob).publish(Event(key: k, value: $i))
    order.add k
  for s in [alice, bob]:
    let causal = causalOrder(s.log.allEvents()).mapIt(it.key).filterIt(it.startsWith("msg/seq"))
    doAssert causal == order, $causal
  let canon = canonicalOrder(alice.log.allEvents()).mapIt(it.key).filterIt(it.startsWith("msg/seq"))
  doAssert canon != order, "the fixture must differ from id order to mean anything"
  echo "2. causalOrder is the order events were published, on both members OK"

block:
  # a proposal published before carol joins, then re-announced to her rebuilt from scratch
  let effectJson = """{"to":"0xc","value":3}"""
  let id = intentIdFor(effectJson)
  alice.publish(proposeEvent(id, effectJson))
  let original = alice.held("intent/" & id & "/propose")
  doAssert original.after.len > 0
  let carol = newCoordinationSession(newLocalTransport(net), newEpochJoiner(carolKs), topic)
  carol.requestJoin(carolKs.joinRequestFor(topic, high(uint64)))
  alice.admitAs(aliceKs, carolKs.encIdentity())
  alice.publish(proposeEvent(id, effectJson))          # the re-announce: rebuilt, so no after
  doAssert alice.held("intent/" & id & "/propose").after == original.after, "the stored copy is kept"
  doAssert carol.held("intent/" & id & "/propose").after == original.after, "the joiner gets the original order"
  doAssert eventId(carol.held("intent/" & id & "/propose")) == eventId(original)
  echo "3. re-publishing re-seals the stored copy, original after included OK"

block:
  let aliceId = hex(aliceKs.encIdentity().toBytes())
  alice.publishAuthored(aliceKs, newMessageEvent(aliceId, 9, "signed", 1)[1])
  let m = bob.roomEvents().filterIt(it.key.startsWith("message/") and it.value.contains("signed"))
  doAssert m.len == 1 and m[0].after.len > 0, "stamped, and still verifies on the peer"
  echo "4. an author-signed event still verifies after after is stamped OK"

block:
  let p = alice.held("msg/one")
  alice.publish(Event(key: "msg/child", value: "c", parents: @[eventId(p)]))
  doAssert bob.held("msg/child").parents == @[eventId(p)]
  echo "5. a caller's parents are kept exactly OK"

block:
  # the activity feed reads proposals in the order they were made: pick two effects whose
  # propose ids sort the other way, so canonical order alone would reverse them
  var ex, ey: string
  for n in 0 .. 400:
    ex = """{"to":"0xa","value":""" & $n & "}"
    ey = """{"to":"0xb","value":""" & $n & "}"
    if eventId(proposeEvent(intentIdFor(ey), ey)) < eventId(proposeEvent(intentIdFor(ex), ex)): break
  let stub: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, finality = finExternal, verifyResult = true)
  alice.publish(proposeEvent(intentIdFor(ex), ex))
  alice.publish(proposeEvent(intentIdFor(ey), ey))
  let act = reduceActivity(bob.roomEvents(), stub).filterIt(it.kind == "propose")
  let ix = act.mapIt(it.intentId).find(intentIdFor(ex))
  let iy = act.mapIt(it.intentId).find(intentIdFor(ey))
  doAssert ix >= 0 and iy >= 0 and ix < iy, "first proposed reads first: " & $(ix, iy)
  echo "6. the activity feed reads proposals in the order they were made OK"

block:
  const t2 = "/muster/1/causal-history/proto"
  let net2 = newLocalNetwork()
  let a = newCoordinationSession(newLocalTransport(net2), newEpochCrypto(aliceKs, t2), t2)
  let b = newCoordinationSession(newLocalTransport(net2), newEpochJoiner(bobKs), t2)
  b.requestJoin(bobKs.joinRequestFor(t2, high(uint64)))
  a.admitAs(aliceKs, bobKs.encIdentity())      # publishes the admit, signed (exo-045)
  b.poll()
  # two effects, the SECOND proposed one's propose id sorting first
  var ea, eb: string
  for n in 0 .. 400:
    ea = """{"to":"0xd","value":""" & $n & "}"
    eb = """{"to":"0xe","value":""" & $n & "}"
    if eventId(proposeEvent(intentIdFor(eb), eb)) < eventId(proposeEvent(intentIdFor(ea), ea)): break
  let (ia, ib) = (intentIdFor(ea), intentIdFor(eb))
  let stub: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, finality = finExternal, verifyResult = true)
  a.publish(proposeEvent(ia, ea)); b.poll()
  a.publish(contributeEvent(ia, "0xaa", "01")); b.poll()
  b.publish(contributeEvent(ia, "0xbb", "02")); a.poll()
  a.publish(submitEvent(ia, chainRef = "0xa1")); b.poll()
  a.publish(finalEvent(ia, chainRef = "0xa1")); b.poll()
  b.publish(proposeEvent(ib, eb)); a.poll()
  b.publish(submitEvent(ib, chainRef = "0xb1")); a.poll()
  for s in [a, b]:
    let act = reduceActivity(s.roomEvents(), stub)
    let admitAt = act.mapIt(it.kind).find("admit")
    var lastA = -1
    var firstB = act.len
    for i, x in act:
      if x.intentId == ia: lastA = max(lastA, i)
      if x.intentId == ib: firstB = min(firstB, i)
    doAssert admitAt >= 0 and lastA >= 0 and firstB < act.len, $act.mapIt((it.kind, it.intentId))
    doAssert admitAt < firstB and lastA < firstB, "the later proposal reads after the earlier one's whole history: " &
      $act.mapIt((it.kind, it.intentId == ia))
    for i, x in act:
      if x.intentId == ia: doAssert i > admitAt, "the admission reads before the proposal made after it"
  echo "7. the room history reads as it happened, whatever the proposals' ids OK"

echo "causal_publish_test: all OK"
