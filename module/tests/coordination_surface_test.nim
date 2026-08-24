## Hosted coordination surface — the algorithm the coordinate_* lidl methods run,
## exercised in-process over LocalTransport (the host round-trip and delivery node
## are deferred with the live two-instance test). This drives the SAME helpers the
## module glue calls: intentIdFor (content-addressed id, so hosts agree without a
## round-trip), effectJsonOf (recover the proposed effect from the shared log), and
## contributorOf (recover+verify the owner before publishing). Two owners converge
## on a real Safe intent reaching executable; a non-owner is refused.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/strutils
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/secp256k1
import ../src/crypto/keystore
import ../src/coordination/session
import ../src/coordination/intents
import ../src/drivers/safe

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

proc toAddr(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let driver = newSafeDriver(chainId = 31337,
  safe = toAddr("0x5FbDB2315678afecb367f032d93F642f64180aa3"),
  owners = @[toAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
             toAddr("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
             toAddr("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")],
  threshold = 2)

# Same fixture effect + pre-signed owner signatures as multiparty_intent_test.
const effectJson = """{"to":"0x1111111111111111111111111111111111111111","value":1000,"nonce":0}"""
const otherEffect = """{"to":"0x2222222222222222222222222222222222222222","value":1,"nonce":0}"""
const sig0 = "0x00278ad6c27d00993883a10909200661d6559d4eea8ca3c9ee3367e8761ba7056fe11cb9a6e87ede5aef673a0f075b220a3c6d37842743c91d9868d834edffcd1b"
const sig1 = "0x7089eabcc8f8d1ff49a4b420d59f9b51f78ce7b498a5d4d17f1e07c0915231ca6443249c38693bbe3f1c12fc87e3a909c7c1e6ad8401d3d03c0b1fb751aa9d241b"
const nonOwnerSig = "0x434ffc353ac48d485e94d1a03d03fdd8279204e9de49e73e0ab3023b392ae2297c3de7242a294bfdc689544d2dd256b7b447659bda23624cb8ef8b247875773f1c"

# 0. Intent id is content-addressed: deterministic, and distinct per effect — so
#    two hosts derive the same id for the same effect with no coordination.
let id = intentIdFor(effectJson)
doAssert id == intentIdFor(effectJson), "same effect -> same id"
doAssert id != intentIdFor(otherEffect), "different effect -> different id"
echo "0. content-addressed intent id OK (", id, ")"

# The room: Alice and Bob share an epoch (their room identity is their Safe key).
let net = newLocalNetwork()
let bobMem = bobKs.encIdentity()
let aliceCrypto = newEpochCrypto(aliceKs, @[bobMem])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobMem))
const topic = "/muster/1/safe-5FbD/proto"
let alice = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bob = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)

# 1. Alice proposes; Bob recovers the effect from the shared log (effectJsonOf) —
#    what a contributor needs to recompute the hash their signature must cover.
alice.publish(proposeEvent(id, effectJson))
doAssert effectJsonOf(bob.log.allEvents(), id) == effectJson,
         "Bob recovers the proposed effect from the log"
doAssert intentState(bob.log.allEvents(), driver, id) == "proposed"
echo "1. propose propagates; effect recovered OK"

# 2. Contribute the way the hosted method does: recover+verify the owner, then key
#    the contribution by the recovered owner address. First valid sig -> collecting.
let who0 = contributorOf(driver, effectJson, sig0)
doAssert who0.len > 0, "owner0 signature recovers to a configured owner"
alice.publish(contributeEvent(id, who0, sig0))
doAssert intentState(alice.log.allEvents(), driver, id) == "collecting"
echo "2. first owner contribution -> collecting OK"

# 3. Second owner meets the threshold; both instances fold to executable + converge.
let who1 = contributorOf(driver, effectJson, sig1)
doAssert who1.len > 0 and who1 != who0, "owner1 is a distinct configured owner"
bob.publish(contributeEvent(id, who1, sig1))
let aState = intentState(alice.log.allEvents(), driver, id)
let bState = intentState(bob.log.allEvents(), driver, id)
doAssert aState == "executable" and bState == "executable", "threshold met -> executable"
doAssert alice.digest() == bob.digest(), "both instances converge (invariant 4)"
echo "3. threshold met -> executable + convergence OK"

# 4. A non-owner signature is refused before publishing — contributorOf returns "".
doAssert contributorOf(driver, effectJson, nonOwnerSig) == "",
         "a non-owner signature does not recover to any owner (rejected)"
echo "4. non-owner contribution refused OK"

# 5. A duplicate owner contribution folds once (keyed by the recovered owner).
alice.publish(contributeEvent(id, who0, sig0))
doAssert intentState(alice.log.allEvents(), driver, id) == "executable",
         "a duplicate owner signature does not double-count"
echo "5. duplicate owner contribution folds once OK"

# 6. The render-ready projection the room draws its cards from: state + the effect
#    it carried + the driver threshold + the DISTINCT-owner approval count. The
#    duplicate from step 5 must not inflate the count — two owners signed, so 2.
block:
  let views = reduceIntentViews(bob.log.allEvents(), driver)
  doAssert views.len == 1, "one intent in the room"
  let v = views[0]
  doAssert v.id == id, "the view keys on the content-addressed intent id"
  doAssert v.state == "executable", "state matches the fold"
  doAssert v.effectJson == effectJson, "the proposed effect travels with the view"
  doAssert v.approvals == 2, "two distinct owners contributed; the duplicate folds once"
echo "6. render-ready intent view (effect + threshold N=2 + approvals M=2) OK"

echo "coordination_surface_test: all OK"
