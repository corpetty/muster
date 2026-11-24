## exo-3b3.14 (P5-05): a part's chain reference has one spelling per rail, at report,
## confirm and fold time — an EVM transaction hash is 0x + 64 lowercase hex, a Bitcoin or
## Monero txid 64 lowercase hex — and anything else is refused. An RPC that also accepts
## another spelling of the same hash (no 0x, capitals) must not let one transaction settle
## two parts by being written two ways.
##
## In-process: the stub ledger seam (its transfer hashes are canonical) and the local
## transport; the creditor's seam reads the ledger as a lenient RPC would, accepting a hash
## with or without 0x, in any case.

import std/[json, strutils]
import ../src/log/log
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/drivers/[driver, split, kinds]
import ../src/intents/materialization
import ../src/coordination/[session, intent_events, intents, live, parts, authorship]

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

const Now = 1_800_000_000'u64
const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const AlicePayTo = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

# A creditor's read through an RPC that takes a hash in any spelling, as nim-eth's
# Hash32.fromHex does (optional 0x, either case).
type LenientSeam = ref object of FakePartSeam
proc canon(tx: string): string =
  result = tx.strip().toLowerAscii()
  if not result.startsWith("0x"): result = "0x" & result
method checkReceived*(s: LenientSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  procCall FakePartSeam(s).checkReceived(t, canon(tx))

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let alice = idHex(aliceKs); let bob = idHex(bobKs)

let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob])
  else: newUnsupportedDriver(policy)

let topic = "/muster/1/part-ref-canonical/proto"
let net = newLocalNetwork()
let aliceCrypto = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity()])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobKs.encIdentity()))
let aliceS = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bobS = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)
proc sync() = (aliceS.poll(); bobS.poll())
proc bindCtx(): LinkContext = LinkContext(account: Chain & ":" & AlicePayTo, slot: "0", expiry: Now + 86_400)
var seqNo = 0'u64
proc agreed(memo: string): string =
  inc seqNo
  let id = liveProposeIntent(aliceS, aliceKs, splitFor, Policy,
                             splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo,
                                             @[SplitShare(who: bob, amount: "450")], memo),
                             int64(Now), seqNo, account = Chain & ":" & AlicePayTo, ttlSec = 3600)
  doAssert id.startsWith("0x"), id
  sync()
  discard liveContribute(bobS, bobKs, splitFor, id, "", "", bindCtx(), Now)
  sync()
  doAssert intentState(aliceS.roomEvents(), splitFor, id) == "executable"
  id

let ledger = newFakeLedger()
let bobSeam = newFakePartSeam(ledger, "bob")
let aliceSeam = LenientSeam(ledger: ledger, payer: "alice")

# ── 1. Bob pays lunch; the creditor confirms it on its canonical hash ──────────────
let lunch = agreed("Lunch")
let taxi = agreed("Taxi")
let (o, pp) = liveSettlePartSend(bobS, bobKs, splitFor, lunch, bobSeam, Now)
doAssert o == "", o
ledger.mine()
doAssert liveSettlePartComplete(bobS, bobKs, splitFor, bobSeam, pp) == "submitted"
let t = pp.tx
doAssert t.startsWith("0x") and t.len == 66 and t[2 .. ^1].allCharsInSet({'0'..'9', 'a'..'f'}),
  "the ledger's hash is canonical: " & t
sync()
doAssert liveConfirmPart(aliceS, aliceKs, splitFor, lunch, partName(bob), aliceSeam, t) == "final"
echo "1. a canonical hash confirms its part OK"

# ── 2. the same hash, written another way, never confirms another part ─────────────
for variant in [t[2 .. ^1], t.toUpperAscii().replace("0X", "0x"), "0X" & t[2 .. ^1], " " & t & " "]:
  let why = liveConfirmPart(aliceS, aliceKs, splitFor, taxi, partName(bob), aliceSeam, variant)
  doAssert why.startsWith("refused"), "'" & variant & "' confirmed the taxi on lunch's payment: " & why
sync()
doAssert intentState(aliceS.roomEvents(), splitFor, taxi) == "executable"
# a report carrying another spelling does not move the dedup either
bobS.publishAuthored(bobKs, partEvent(taxi, partName(bob), "settled", bob, t[2 .. ^1]))
sync()
doAssert liveConfirmParts(aliceS, aliceKs, splitFor, aliceSeam).len == 0
echo "2. one hash in another spelling never settles a second part OK"

# ── 3. the spelling per rail ─────────────────────────────────────────────────────
block:
  let h = repeat("ab", 32)
  doAssert canonicalRefRefusal("eip155:1", "0x" & h) == ""
  doAssert canonicalRefRefusal("eip155:1", h).len > 0, "an EVM hash carries 0x"
  doAssert canonicalRefRefusal("eip155:1", "0x" & h.toUpperAscii()).len > 0, "lowercase only"
  doAssert canonicalRefRefusal("eip155:1", "0x" & h[0 .. ^3]).len > 0, "32 bytes"
  doAssert canonicalRefRefusal("bip122:000000000019d6689c085ae165831e93", h) == ""
  doAssert canonicalRefRefusal("bip122:000000000019d6689c085ae165831e93", "0x" & h).len > 0, "a txid has no 0x"
  doAssert canonicalRefRefusal("monero:418015bb9ae982a1975da7d79277c270", h) == ""
  doAssert canonicalRefRefusal("monero:418015bb9ae982a1975da7d79277c270", h & "," & repeat("cd", 32)) == "",
    "a Monero part may arrive in several transfers, each a txid"
  doAssert canonicalRefRefusal("monero:418015bb9ae982a1975da7d79277c270", h & ",0x" & h).len > 0
  echo "3. one spelling per rail OK"

echo "part_reference_canonical_test: all OK"
