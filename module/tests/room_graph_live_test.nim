## The room map over real sessions (G3, exo-9cb): what `coordinate_graph` folds is the
## authenticated log a member's session actually decrypted. Alice founds a room, writes
## and proposes; Bob is admitted over the encrypted handshake; both act after. Bob's
## map holds nothing sealed before his admission (invariant 7, F-16, over the wire, not
## by slicing a list), the part of the room both hold maps the same for both, a forged
## message never reaches either map, and a joiner is never counted as a founder.
## LocalTransport + epoch crypto; needs libsecp256k1 + libsodium (tests/README.md).

import std/[json, strutils, sequtils, sets]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/curve25519
import ../src/drivers/driver
import ../src/log/log
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/intents
import ../src/coordination/flow
import ../src/coordination/room_graph

proc key(h: string): array[32, byte] = (for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1])))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs = newInMemoryKeystore(key("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let aliceId = hex(aliceKs.encIdentity().toBytes())
let bobId = hex(bobKs.encIdentity().toBytes())

const topic = "/muster/1/room-graph-live/proto"
let net = newLocalNetwork()
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)

let stub: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 1, finality = finExternal, verifyResult = true)

# epoch 0: alice alone — a message and a proposal Bob will never hold
let effectBefore = """{"to":"0xbefore","value":1}"""
let idBefore = intentIdFor(effectBefore)
alice.publishAuthored(aliceKs, newMessageEvent(aliceId, 1, "before bob", 1)[1])
alice.publish(proposeEvent(idBefore, effectBefore))

# bob is admitted over the handshake (re-key forward, an admit entry under the new epoch)
bob.requestJoin(bobKs.joinRequestFor(topic, high(uint64)))
alice.admitAs(aliceKs, bobKs.encIdentity())

# epoch 1: both act; a message with a forged author never reaches a map
let effectAfter = """{"to":"0xafter","value":2}"""
let idAfter = intentIdFor(effectAfter)
alice.publish(proposeEvent(idAfter, effectAfter))
bob.publishAuthored(bobKs, newMessageEvent(bobId, 2, "after bob", 1)[1])
bob.publish(contributeEvent(idAfter, "0xbobkey", "sb"))
bob.publish(newMessageEvent(aliceId, 3, "bob pretending to be alice", 1)[1])   # unsigned: forged
alice.poll(); bob.poll()

proc roster(s: CoordinationSession): seq[string] =
  for m in s.members(): result.add hex(m.toBytes()).toUpperAscii()   # as the host spells it (strutils.toHex)
proc graphOf(s: CoordinationSession, me: string): RoomGraph =
  let events = s.roomEvents()
  reduceRoomGraph(events, stub, foundersOf(events, s.roster()), me, s.sealedIn)

let ga = alice.graphOf(aliceId)
let gb = bob.graphOf(bobId)

block:
  doAssert ga.readFrom == 0 and gb.readFrom == 1, $(ga.readFrom, gb.readFrom)
  doAssert ga.nodes.anyIt(it.id == "i:" & idBefore) and ga.nodes.anyIt(it.id == "i:" & idAfter)
  doAssert not gb.nodes.anyIt(it.id == "i:" & idBefore), "Bob's map holds no proposal sealed before him"
  for n in gb.nodes:
    if n.kind == "entry": doAssert n.epoch >= 1, "an entry from before Bob's admission: " & $n
  doAssert gb.nodes.anyIt(it.id == "i:" & idAfter)
  echo "1. a joiner's map, from what its session decrypted, starts at its admission (inv 7) OK"

block:
  # Bob was admitted, so he is no founder in either map — whatever case the roster uses
  for g in [ga, gb]:
    let b = g.nodes.filterIt(it.id == "m:" & bobId)
    doAssert b.len == 1 and b[0].attrs["joined"].getInt() == 1, $b
  echo "2. a joiner is a member from its admission, never a founder OK"

block:
  # what both hold maps the same: every node and edge in Bob's map is in Alice's
  let aIds = ga.nodes.mapIt(it.id & "@" & $it.kind).toHashSet()
  for n in gb.nodes:
    if n.kind in ["entry", "intent", "member", "observer", "signer"]:
      doAssert (n.id & "@" & n.kind) in aIds, "Bob maps something Alice does not: " & $n
  let aEdges = ga.edges.filterIt(it.kind != "parent").mapIt(it.src & ">" & it.dst & ":" & it.kind).toHashSet()
  for e in gb.edges:
    if e.kind != "parent": doAssert (e.src & ">" & e.dst & ":" & e.kind) in aEdges, $e
  echo "3. the room both hold maps the same for both (inv 9) OK"

block:
  # the forged message dropped at roomEvents: neither map attributes it to alice
  for g in [ga, gb]:
    doAssert not ($g.toJson()).contains("pretending")
    let authoredByAlice = g.edges.filterIt(it.kind == "authored" and it.src == "m:" & aliceId).len
    doAssert authoredByAlice <= 1, "only alice's own signed message names her: " & $authoredByAlice
  echo "4. a forged message reaches no map; an author is named only where it signed OK"

block:
  # these events carry no parents, so canonical order sorts them by content id and says
  # nothing about when they were sealed; each entry's epoch is the one whose key opened it
  let o = canonicalOrder(alice.roomEvents())
  for g in [ga, gb]:
    for n in g.nodes:
      if n.kind != "entry": continue
      var key = ""
      for e in o: (if "e:" & eventId(e) == n.id: key = e.key)
      let before = key.startsWith("message/") and n.attrs.hasKey("account") and n.attrs["account"].getStr() == "m:" & aliceId
      if key == "intent/" & idBefore & "/propose" or before: doAssert n.epoch == 0, key & " @ " & $n.epoch
      elif key.len > 0: doAssert n.epoch == 1, key & " @ " & $n.epoch
  echo "5. every entry's epoch is the one whose key opened it, not its log position OK"

echo "room_graph_live_test: all OK"
