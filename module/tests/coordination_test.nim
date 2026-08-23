## Multi-instance coordination over transport + epoch encryption — the P3 join
## point. Two instances sharing an epoch key converge to identical state; an
## outsider without the key learns nothing from the same topic; a member who comes
## online late catches up from the store. Needs libsecp256k1 + libsodium linked
## (see tests/README.md). Runs on LocalTransport — the delivery-backed transport
## is a drop-in for the same interface.

import std/[strutils, tables]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/coordination/session

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let daveKs  = newInMemoryKeystore(key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"), seed(3))
let malKs   = newInMemoryKeystore(key("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(4))
let bobMem = bobKs.encIdentity()
let daveMem = daveKs.encIdentity()

const topic = "/muster/1/room-1/proto"
let net = newLocalNetwork()

# The room: Alice founds epoch 0 with Bob and Dave; both are granted the key.
let aliceCrypto = newEpochCrypto(aliceKs, @[bobMem, daveMem])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobMem))

let alice = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bob = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)

# ── 1. two instances converge on the coordination state ───────────────────────
# Alice proposes an intent; Bob's approval and Alice's status both propagate.
alice.publish(Event(key: "intent-1:state", value: "proposed"))
bob.publish(Event(key: "intent-1:sig:bob", value: "0xabc…"))
alice.publish(Event(key: "intent-1:state", value: "collecting"))

doAssert alice.digest() == bob.digest(), "two instances must converge to one state"
doAssert alice.state().entries["intent-1:sig:bob"] == "0xabc…", "Bob's event reached Alice"
doAssert bob.state().entries["intent-1:state"] == "collecting", "Alice's events reached Bob"
echo "1. two-instance convergence OK"

# ── 2. an outsider on the same topic, without the epoch key, learns nothing ───
let malCrypto = newEpochJoiner(malKs)           # never granted any epoch
let mal = newCoordinationSession(newLocalTransport(net), malCrypto, topic)
alice.publish(Event(key: "intent-1:state", value: "executable"))
doAssert mal.log.allEvents().len == 0,
         "an outsider without the epoch key ingests nothing (the envelope is opaque)"
doAssert alice.digest() == bob.digest(), "members still converge past the outsider"
echo "2. outsider without the epoch key is blind OK"

# ── 3. a member who comes online late catches up from the store ───────────────
let daveCrypto = newEpochJoiner(daveKs)
daveCrypto.ingestGrant(aliceCrypto.grantFor(0, daveMem))   # Dave held epoch 0 all along
let dave = newCoordinationSession(newLocalTransport(net), daveCrypto, topic)
dave.catchUp()                                             # pull retained envelopes
doAssert dave.digest() == alice.digest(),
         "a late-but-authorised member catches up to the converged state from the store"
echo "3. offline catchup (authorised late member) OK"

echo "coordination_test: all OK"
