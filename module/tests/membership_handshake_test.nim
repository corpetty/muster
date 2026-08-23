## Membership grant handshake over the coordination session (the piece that lets a
## joiner actually get an epoch key without a side channel). A join-request carries
## no authority; a member decides to admit; the grant travels as an opaque control
## frame on the same topic. F-16 must still hold over the wire: the newly admitted
## member reads messages from their epoch on, and NOTHING from before their seam.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/strutils
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/coordination/session

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let malKs   = newInMemoryKeystore(key("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(3))
let bobPub = bobKs.encIdentity()

# F-9 owner set: Bob is a Safe owner, Mallory is not.
let owners = @[bobKs.address()]
let ctx = LinkContext(account: "room-safe", slot: "0", expiry: high(uint64))

const topic = "/muster/1/handshake/proto"
let net = newLocalNetwork()

# Alice founds the room (epoch 0, just her). Bob starts outside it entirely.
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs), topic)
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)

# Alice says something before Bob is admitted — this is the pre-seam history.
alice.publish(Event(key: "msg/1", value: "before-bob"))
doAssert bob.log.allEvents().len == 0, "Bob holds no key yet — cannot read epoch 0"
echo "1. outsider cannot read the room OK"

# Bob asks to join, carrying his binding. The request carries no authority; Alice
# sees it as pending and can VERIFY it (F-9) before deciding.
bob.requestJoin(bobKs.bindingFor(ctx))
doAssert bobPub in alice.pendingJoins(), "Alice sees Bob's join-request as pending"
doAssert bob.log.allEvents().len == 0, "a join-request alone admits nobody"
echo "2. join-request is discovery, not entry OK"

# F-9: Bob's binding proves his encryption identity belongs to a Safe owner; a
# non-owner's binding for the same room does not bind against the owner set.
block:
  var bobBinding: LinkStatement
  for st in alice.pendingBindings():
    if st.enc == bobPub: bobBinding = st
  doAssert bindingBinds(bobBinding, owners, now = 0), "Bob's binding proves Safe ownership (F-9)"
  doAssert not bindingBinds(malKs.bindingFor(ctx), owners, now = 0),
           "a non-owner's binding must not satisfy the owner check"
echo "3. F-9 binding verified before admission OK"

# Alice admits Bob: re-key forward, grants published on the topic. Bob ingests his.
alice.admit(bobPub)
doAssert bobPub notin alice.pendingJoins(), "the request is cleared once admitted"
echo "4. member admits the joiner OK"

# Now Alice speaks in the new epoch; Bob can read it — the handshake worked.
alice.publish(Event(key: "msg/2", value: "after-bob"))
var sawAfter = false
for e in bob.log.allEvents():
  if e.key == "msg/2" and e.value == "after-bob": sawAfter = true
doAssert sawAfter, "Bob reads messages from his epoch onward"
echo "5. admitted member reads new messages OK"

# F-16 over the wire: Bob still cannot read the pre-admission message. He was
# granted only the new epoch's key, never epoch 0's.
for e in bob.log.allEvents():
  doAssert e.value != "before-bob", "F-16: the joiner must not read pre-seam history"
echo "6. F-16 holds across the handshake OK"

echo "membership_handshake_test: all OK"
