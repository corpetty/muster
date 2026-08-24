## Chat/room surface — authored messages + roster fold over the SAME sealed log
## the intents ride. Mirrors coordination_surface_test's setup: two in-process
## instances (Alice, Bob) over LocalTransport, sharing one epoch. Asserts messages
## round-trip (author + body + order) across the encrypted transport, that a JSON
## card body is carried opaquely, and that the admitted roster is reported.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/[strutils, json]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/coordination/session
import ../src/coordination/intents

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))

let aliceId = toHex(aliceKs.encIdentity().toBytes())
let bobId   = toHex(bobKs.encIdentity().toBytes())

# The room: Alice and Bob share one epoch (their room identity is their enc key).
let net = newLocalNetwork()
let bobMem = bobKs.encIdentity()
let aliceCrypto = newEpochCrypto(aliceKs, @[bobMem])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobMem))
const topic = "/muster/1/room-chat/proto"
let alice = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bob = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)

# 1. Alice posts a plain-text message; Bob posts a typed card as a JSON body.
#    Controlled timestamps make the oldest-first ordering deterministic to assert.
let plainBody = "hello room"
let cardBody = $(%*{"kind": "transfer-card", "to": "0xabc", "amount": "42"})

let (mid1, ev1) = newMessageEvent(aliceId, ts = 100, body = plainBody, nonce = 1)
alice.publish(ev1)
let (mid2, ev2) = newMessageEvent(bobId, ts = 200, body = cardBody, nonce = 1)
bob.publish(ev2)
doAssert mid1 != mid2, "distinct messages get distinct ids"
echo "1. posted a plain message (Alice) + a JSON card (Bob) OK"

# 2. Both instances fold the SAME two messages out of the shared log, oldest-first.
for (who, s) in {"alice": alice, "bob": bob}:
  let msgs = reduceMessages(s.log.allEvents())
  doAssert msgs.len == 2, who & ": both messages arrived (" & $msgs.len & ")"
  doAssert msgs[0].ts == 100 and msgs[1].ts == 200, who & ": oldest-first order"
  doAssert msgs[0].author == aliceId, who & ": first author is Alice"
  doAssert msgs[0].body == plainBody, who & ": plain body round-trips"
  doAssert msgs[1].author == bobId, who & ": second author is Bob"
  doAssert msgs[1].body == cardBody, who & ": JSON card body carried opaquely"
  # the card body is itself valid JSON on the other side — carried, not mangled
  doAssert parseJson(msgs[1].body)["kind"].getStr() == "transfer-card",
           who & ": card decodes"
  doAssert msgs[0].id == mid1 and msgs[1].id == mid2, who & ": ids match"
echo "2. messages round-trip across encrypted transport, ordered + intact OK"

# 3. Convergence: message fold is a pure function of the event set (invariant 4).
doAssert alice.digest() == bob.digest(), "both instances converge on the log"
echo "3. both instances converge (invariant 4) OK"

# 4. The admitted roster: Alice's session lists both members, self-flagged.
block:
  let me = alice.selfIdentity()
  let roster = alice.members()
  doAssert roster.len == 2, "roster has both admitted members (" & $roster.len & ")"
  var sawSelf, sawBob = false
  for m in roster:
    if m == me: sawSelf = true
    if m == bobMem: sawBob = true
  doAssert sawSelf, "roster includes our own identity (self)"
  doAssert sawBob, "roster includes the admitted peer"
echo "4. admitted roster reported with self-flag OK"

echo "coordination_messages_test: all OK"
