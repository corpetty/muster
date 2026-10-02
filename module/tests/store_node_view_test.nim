## exo-661.7 — what a store node reads off a room's topic: topic, timing, and frame
## kinds and sizes, never who is in the room (FS-7), and never which epoch a frame
## belongs to.
##
## A store node, and anyone else subscribed to a content topic, holds every frame
## published on it. FS-7 says a member's identity "lives in the room's encrypted
## interior — never leaked to a store node or any observer outside the room". The
## join-request, the admit and the data envelope each broke that in the clear:
##   - a join request carried the joiner's Ed25519/X25519 identity, the room it
##     named and a secp256k1 signature that recovers the joiner's address;
##   - every admit published, once per member, the WHOLE roster of the new epoch;
##   - every data envelope began with its 4-byte epoch number.
##
## The test runs the flow the app runs — two instances that joined one room by name
## (each founds its own epoch), one asks and the other admits, then a third asks and
## a NON-founding member admits them — and then reads the topic as the store node
## does: every retained frame. It asserts:
##   1. no member's Ed25519 key, X25519 key, secp256k1 address or binding signature
##      appears anywhere in any frame (a conservation check: sentinels in, zero out);
##   2. no two data frames, and no two grant frames, share their first or last four
##      bytes — a deterministic epoch tag at either end fails this;
##   3. the handshake still works: each asker is admitted, reads from its own epoch
##      on and nothing before it (F-16).
## Needs libsodium + $SECP (run-suite.sh supplies them).

import std/[sequtils, strutils]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/coordination/session

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

proc contains(hay, needle: openArray[byte]): bool =
  if needle.len == 0 or needle.len > hay.len: return false
  for i in 0 .. hay.len - needle.len:
    var ok = true
    for j in 0 ..< needle.len:
      if hay[i + j] != needle[j]: ok = false; break
    if ok: return true

let aliceKs = newInMemoryKeystore(seed(0x11), seed(0x21))
let bobKs   = newInMemoryKeystore(seed(0x12), seed(0x22))
let carolKs = newInMemoryKeystore(seed(0x13), seed(0x23))
const topic = "/muster/1/store-node-view/proto"
let ctx = LinkContext(account: topic, slot: "0", expiry: high(uint64))

let net = newLocalNetwork()
# Both Alice and Bob joined the room by name, so each founded its own epoch (the app's
# coordinate_join does exactly this). Carol starts with no key at all.
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
let bob   = newCoordinationSession(newLocalTransport(net), newEpochCrypto(bobKs, topic), topic)
let carol = newCoordinationSession(newLocalTransport(net), newEpochJoiner(carolKs), topic)

alice.publish(Event(key: "msg/a0", value: "alice alone"))

# Bob asks; Alice admits him.
let bobBinding = bobKs.bindingFor(ctx)
bob.requestJoin(bobBinding)
doAssert bobKs.encIdentity() in alice.pendingJoins(), "Alice sees Bob's request"
alice.admit(bobKs.encIdentity())
doAssert bob.members().len == 2 and alice.members().len == 2, "Alice and Bob share an epoch"
alice.publish(Event(key: "msg/a1", value: "alice to bob"))
bob.publish(Event(key: "msg/b1", value: "bob to alice"))

# Carol asks; BOB (not the founder) admits her.
let carolBinding = carolKs.bindingFor(ctx)
carol.requestJoin(carolBinding)
doAssert carolKs.encIdentity() in bob.pendingJoins(), "Bob, a member, sees Carol's request"
bob.admit(carolKs.encIdentity())
doAssert carol.members().len == 3 and alice.members().len == 3, "all three share the new epoch"
alice.publish(Event(key: "msg/a2", value: "alice to all"))
carol.publish(Event(key: "msg/c2", value: "carol to all"))

proc holds(s: CoordinationSession, value: string): bool =
  s.log.allEvents().anyIt(it.value == value)

# ── 3. the handshake still works, and F-16 holds ────────────────────────────────
block:
  doAssert bob.holds("alice to bob") and bob.holds("carol to all")
  doAssert carol.holds("alice to all") and carol.holds("bob to alice") == false,
    "Carol reads from her own epoch on, and nothing sealed before it (F-16)"
  doAssert not bob.holds("alice alone"), "Bob cannot read what Alice sealed before admitting him (F-16)"
  echo "3. both askers admitted; each reads from its own epoch on (F-16) OK"

# ── what the store node holds: every frame retained on the topic ────────────────
let frames = newLocalTransport(net).storeQuery(topic).mapIt(it.payload)
doAssert frames.len > 0

# ── 1. no member identity, address or binding in any frame ──────────────────────
block:
  var sentinels: seq[(string, seq[byte])]
  for (name, ks) in [("alice", Keystore(aliceKs)), ("bob", Keystore(bobKs)), ("carol", Keystore(carolKs))]:
    let id = ks.encIdentity()
    sentinels.add (name & " ed25519", @(id.ed))
    sentinels.add (name & " x25519", @(id.x))
    sentinels.add (name & " secp256k1 address", @(ks.address()))
  sentinels.add ("bob's binding signature", @(bobBinding.sig))
  sentinels.add ("carol's binding signature", @(carolBinding.sig))
  var leaks: seq[string]
  for (name, bytes) in sentinels:
    var n = 0
    for f in frames:
      if f.contains(bytes): inc n
    if n > 0: leaks.add name & " (in " & $n & " frame(s))"
  doAssert leaks.len == 0,
    "a store node reads member identity off the topic: " & leaks.join("; ")
  echo "1. no member identity, address or binding signature in any of ", frames.len, " frames OK"

# ── 2. no deterministic epoch tag at either end of a data or grant frame ────────
block:
  proc noSharedEnds(kind: byte, what: string) =
    let bodies = frames.filterIt(it.len > 9 and it[0] == kind).mapIt(it[1 .. ^1])
    doAssert bodies.len >= 2, "the flow produced several " & what & " frames"
    for i in 0 ..< bodies.len:
      for j in i + 1 ..< bodies.len:
        doAssert bodies[i][0 ..< 4] != bodies[j][0 ..< 4],
          "two " & what & " frames begin with the same four bytes (an epoch in the clear?)"
        doAssert bodies[i][^4 .. ^1] != bodies[j][^4 .. ^1],
          "two " & what & " frames end with the same four bytes"
  noSharedEnds(0x00'u8, "data")
  noSharedEnds(0x02'u8, "grant")
  echo "2. data and grant frames carry no epoch tag at either end OK"

echo "store_node_view_test: all OK"
