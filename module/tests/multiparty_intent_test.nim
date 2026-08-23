## Multi-party intent coordination — the P3 payoff: two owners coordinate a REAL
## Safe intent over encrypted transport, and the intent's lifecycle state IS
## reduce(log) (invariant 4). Alice proposes; Alice and Bob each contribute their
## owner signature; both instances fold the shared log through the SAME lifecycle
## engine and converge on the intent reaching `executable`. A non-owner signature
## does not count. Needs libsecp256k1 + libsodium (see tests/README.md).

import std/[strutils, tables]
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

# Owners = anvil accounts 0/1/2; the coordinating pair are owners 0 and 1.
let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let driver = newSafeDriver(chainId = 31337,
  safe = toAddr("0x5FbDB2315678afecb367f032d93F642f64180aa3"),
  owners = @[toAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
             toAddr("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
             toAddr("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")],
  threshold = 2)

# The effect {to,value,nonce}=0x1111…/1000/0 hashes to the safeTxHash these two
# pre-signed owner signatures cover (same fixture as the P4 harness).
const effectJson = """{"to":"0x1111111111111111111111111111111111111111","value":1000,"nonce":0}"""
const sig0 = "0x00278ad6c27d00993883a10909200661d6559d4eea8ca3c9ee3367e8761ba7056fe11cb9a6e87ede5aef673a0f075b220a3c6d37842743c91d9868d834edffcd1b" # owner0
const sig1 = "0x7089eabcc8f8d1ff49a4b420d59f9b51f78ce7b498a5d4d17f1e07c0915231ca6443249c38693bbe3f1c12fc87e3a909c7c1e6ad8401d3d03c0b1fb751aa9d241b" # owner1
const nonOwnerSig = "0x434ffc353ac48d485e94d1a03d03fdd8279204e9de49e73e0ab3023b392ae2297c3de7242a294bfdc689544d2dd256b7b447659bda23624cb8ef8b247875773f1c" # anvil 3

# Room: Alice and Bob share an epoch (their conversation identity is their Safe key).
let net = newLocalNetwork()
let bobMem = bobKs.encIdentity()
let aliceCrypto = newEpochCrypto(aliceKs, @[bobMem])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobMem))
const topic = "/muster/1/safe-5FbD/proto"
let alice = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bob = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)

# Alice proposes intent-1.
alice.publish(proposeEvent("1", effectJson))
doAssert intentState(bob.log.allEvents(), driver, "1") == "proposed",
         "Bob sees the proposal after it propagates"
echo "1. propose propagates OK"

# Alice contributes her owner signature — collecting (1 of 2).
alice.publish(contributeEvent("1", "owner0", sig0))
doAssert intentState(alice.log.allEvents(), driver, "1") == "collecting",
         "one valid owner signature -> collecting"
echo "2. first signature -> collecting OK"

# Bob contributes his — threshold met, both fold to executable and converge.
bob.publish(contributeEvent("1", "owner1", sig1))
let aState = intentState(alice.log.allEvents(), driver, "1")
let bState = intentState(bob.log.allEvents(), driver, "1")
doAssert aState == "executable", "two owner signatures -> executable (Alice): " & aState
doAssert bState == "executable", "two owner signatures -> executable (Bob): " & bState
doAssert aState == bState and alice.digest() == bob.digest(),
         "both instances converge on the same intent state (invariant 4)"
echo "3. threshold met -> executable + convergence OK"

# A non-owner signature does not count: it never advances the intent to executable.
alice.publish(proposeEvent("2", effectJson))
alice.publish(contributeEvent("2", "intruder", nonOwnerSig))
doAssert intentState(alice.log.allEvents(), driver, "2") != "executable",
         "a non-owner signature must not reach the threshold"
echo "4. non-owner signature does not count OK"

echo "multiparty_intent_test: all OK"
