## Two people in one room — the full cross-host journey over the transport seam, in
## one test. Alice founds a room; Bob is outside it; Bob requests to join and Alice
## admits him (forward re-key, F-16); then the two coordinate a REAL Safe intent to
## executable and CONVERGE (state = reduce(log), invariant 4). Finally a reconnecting
## member that re-reads the shared log recomputes the identical state — the fold is a
## pure function of the event set, so a drop-and-resume loses nothing it already holds.
##
## This exercises the two-instance logic against LocalTransport (the same Transport
## interface DeliveryTransport implements). The remaining live step — two hosts on
## SEPARATE machines through a store node, killed mid-collection and restarted (R-4/
## R-6) — needs a running delivery node and is infra-bound (see the module README).
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/strutils
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/secp256k1
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/coordination/session
import ../src/coordination/intents
import ../src/drivers/driver as drivercore
import ../src/drivers/safe

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc toAddr(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

# Alice and Bob are two hosts. Their Safe-owner secp keys are anvil accounts 0 and 1.
let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let bobPub = bobKs.encIdentity()

let driver = newSafeDriver(chainId = 31337,
  safe = toAddr("0x5FbDB2315678afecb367f032d93F642f64180aa3"),
  owners = @[toAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
             toAddr("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
             toAddr("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")],
  threshold = 2)
let foldDrv: DriverFor = proc(kind: string): drivercore.Driver = driver

const effectJson = """{"to":"0x1111111111111111111111111111111111111111","value":1000,"nonce":0}"""
const sig0 = "0x00278ad6c27d00993883a10909200661d6559d4eea8ca3c9ee3367e8761ba7056fe11cb9a6e87ede5aef673a0f075b220a3c6d37842743c91d9868d834edffcd1b"
const sig1 = "0x7089eabcc8f8d1ff49a4b420d59f9b51f78ce7b498a5d4d17f1e07c0915231ca6443249c38693bbe3f1c12fc87e3a909c7c1e6ad8401d3d03c0b1fb751aa9d241b"

const topic = "/muster/1/two-instance/proto"
let net = newLocalNetwork()

# 1. Alice founds the room (epoch 0). Bob starts outside it — no key, no read.
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs), topic)
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
doAssert bob.log.allEvents().len == 0, "Bob holds no key — the outsider cannot read the room"
echo "1. Alice founds the room; Bob is outside OK"

# 2. Bob asks to join (discovery, no authority); Alice verifies his F-9 binding and
#    admits him — re-key forward, so Bob reads from his epoch on (F-16).
let ctx = LinkContext(account: "room-safe", slot: "0", expiry: high(uint64))
bob.requestJoin(bobKs.bindingFor(ctx))
doAssert bobPub in alice.pendingJoins(), "Alice sees Bob's request as pending"
alice.admit(bobPub)
doAssert bobPub notin alice.pendingJoins(), "the request clears once admitted"
echo "2. Bob requests, Alice admits (forward re-key) OK"

# 3. Alice proposes a real Safe intent into the room; Bob recovers the effect from the
#    shared log — the same id both derive with no coordination (content-addressed).
let id = intentIdFor(effectJson)
alice.publish(proposeEvent(id, effectJson))
doAssert effectJsonOf(bob.log.allEvents(), id) == effectJson,
         "Bob recovers Alice's proposed effect from the shared log"
echo "3. Alice proposes; Bob recovers the effect OK"

# 4. Each host contributes its owner signature; both instances fold the shared log and
#    CONVERGE on the intent reaching executable (invariant 4).
let who0 = contributorOf(driver, effectJson, sig0)
let who1 = contributorOf(driver, effectJson, sig1)
doAssert who0.len > 0 and who1.len > 0 and who0 != who1, "two distinct configured owners"
alice.publish(contributeEvent(id, who0, sig0))
bob.publish(contributeEvent(id, who1, sig1))
let aState = intentState(alice.log.allEvents(), foldDrv, id)
let bState = intentState(bob.log.allEvents(), foldDrv, id)
doAssert aState == "executable" and bState == "executable", "both hosts converge on executable"
doAssert alice.digest() == bob.digest(), "both instances converge to the same state (invariant 4)"
echo "4. two hosts contribute; both converge on executable OK"

# 5. Reduce(log) durability: a member that re-reads the SAME event set recomputes the
#    identical intent state — the fold is a pure function of the events, so a client
#    that drops and resumes (re-reading the log it holds) loses nothing. The
#    store-backed reconnect of a host that missed frames while OFFLINE is the live
#    delivery-node step (R-4/R-6), infra-bound; here we prove the fold half.
block:
  let events = bob.log.allEvents()
  doAssert intentState(events, foldDrv, id) == "executable",
           "re-folding the held log recomputes executable (reduce(log), order-independent)"
  # Idempotent under duplication: a re-delivered contribution folds once.
  var dup = events
  dup.add contributeEvent(id, who0, sig0)
  let views = reduceIntentViews(dup, foldDrv)
  doAssert views.len == 1 and views[0].approvals == 2,
           "a duplicated contribution does not inflate the fold (idempotent convergence)"
echo "5. reduce(log) convergence survives re-read + duplication OK"

echo "two_instance_test: all OK"
