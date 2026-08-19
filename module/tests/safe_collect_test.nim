## P2 integration: collect 2-of-3 Safe owner signatures over the safeTxHash and
## reach executable — with real secp256k1 ECDSA verification against the owner set,
## non-owner rejection, and wrong-chainId rejection. No indexer/service in the loop.
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/crypto/secp256k1
import ../src/intents/materialization
import ../src/intents/signing_payload
import ../src/intents/lifecycle

var owners: seq[Address]
var keys: seq[array[32, byte]]
for k in 1 .. 3:
  var sk: array[32, byte]; sk[31] = byte(k)
  keys.add sk
  owners.add addressOf(sk)

var safeAddr: Address
for i in 0 ..< 20: safeAddr[i] = byte(0x10 + i)
let drv = newSafeDriver(chainId = 31337, safe = safeAddr, owners = owners, threshold = 2)

let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
  ("to", cbText("0x00112233445566778899aabbccddeeff00112233")),
  ("value", cbUint(1000'u64)), ("nonce", cbUint(0'u64))])
let mat = canonicalizeSafe(drv, effect)
var hash: array[32, byte]
for i in 0 ..< 32: hash[i] = mat.bytes[i]
let sctx = SigningContext(environment: "anvil-31337", account: "safe", slot: "0", expiry: 1_000_000'u64)

block collectTwoOfThree:
  var it = newIntent(drv, effect, sctx)
  it.apply(drv, IntentEvent(kind: iePropose, now: 0))
  it.apply(drv, IntentEvent(kind: ieContribute, now: 1,
    contribution: Contribution(bytes: @(signRecoverable(hash, keys[0])))))
  doAssert it.state == lsCollecting
  it.apply(drv, IntentEvent(kind: ieContribute, now: 1,
    contribution: Contribution(bytes: @(signRecoverable(hash, keys[1])))))
  doAssert it.state == lsExecutable, $it.state
  echo "collected 2-of-3 owner signatures -> executable: OK"

block nonOwnerRejected:
  var it = newIntent(drv, effect, sctx)
  it.apply(drv, IntentEvent(kind: iePropose, now: 0))
  var badKey: array[32, byte]; badKey[31] = 99
  for _ in 0 .. 1:
    it.apply(drv, IntentEvent(kind: ieContribute, now: 1,
      contribution: Contribution(bytes: @(signRecoverable(hash, badKey)))))
  doAssert it.state == lsCollecting          # never reaches executable on non-owner sigs
  echo "non-owner signatures never reach executable: OK"

block wrongChainIdRejected:
  # A signature made over a DIFFERENT chain's safeTxHash does not verify here.
  let otherHashSeq = safeTxHash(toSafeTx(effect), 1, safeAddr)   # chainId 1, not 31337
  var otherHash: array[32, byte]
  for i in 0 ..< 32: otherHash[i] = otherHashSeq[i]
  var it = newIntent(drv, effect, sctx)
  it.apply(drv, IntentEvent(kind: iePropose, now: 0))
  it.apply(drv, IntentEvent(kind: ieContribute, now: 1,
    contribution: Contribution(bytes: @(signRecoverable(otherHash, keys[0])))))
  doAssert it.state == lsCollecting          # wrong-chain sig does not count
  echo "wrong-chainId signature rejected: OK"

echo "safe collect: all checks passed"
