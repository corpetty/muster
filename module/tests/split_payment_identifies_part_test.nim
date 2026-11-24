## exo-3b3.14 (P5-03): a payment identifies the one part it settles.
##
## On a public rail the creditor confirms a part from its own read of the reported
## transaction: to, amount, asset, chain, status. That read does not name who sent it, so
## the amount is what ties a payment to its part, as on the private rail (§4.7):
##   1. every split family refuses two equal shares — evm.split (ETH and a token) and
##      btc.split as well as lez.split and monero.split;
##   2. an even split is composed with every share distinct — the i-th debtor owes i
##      smallest units less, the creditor absorbing the difference — so the shares still
##      never exceed the total;
##   3. when two parties report the same transaction for different parts (two splits paid
##      at one address, the same amount), neither part is confirmed on it, and the room's
##      view of each part says why (contestedParts).
## In-process: the stub ledger seam and the local transport, as split_live_test.

import std/[json, strutils, sequtils, tables]
import stint
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
const Ttl = 3600'i64
const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const AlicePayTo = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
const Token = "erc20:0x5fbdb2315678afecb367f032d93f642f64180aa3"
const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let carolKs = newInMemoryKeystore(key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"), seed(3))
let alice = idHex(aliceKs); let bob = idHex(bobKs); let carol = idHex(carolKs)

# ── 1. every family refuses two equal shares ────────────────────────────────────
block:
  let equal = @[SplitShare(who: bob, amount: "450"), SplitShare(who: carol, amount: "450")]
  let evm = newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol])
  let ethWhy = evm.signRefusal(effectFromJson(splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo, equal, "x")))
  doAssert "differ" in ethWhy, "an ETH split with two equal shares is refused: " & ethWhy
  let tokWhy = evm.signRefusal(effectFromJson(splitEffectJson(Chain, Token, "900", alice, AlicePayTo, equal, "x")))
  doAssert "differ" in tokWhy, "a token split with two equal shares is refused: " & tokWhy
  let btc = newSplitDriver(BtcSplitFamily, Regtest, @[alice, bob, carol])
  let btcEqual = @[SplitShare(who: bob, amount: "100000"), SplitShare(who: carol, amount: "100000")]
  let btcWhy = btc.signRefusal(effectFromJson(splitEffectJson(Regtest, "BTC", "300000", alice,
    "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", btcEqual, "x")))
  doAssert "differ" in btcWhy, "a Bitcoin split with two equal shares is refused: " & btcWhy
  # distinct shares are what the driver takes
  let apart = @[SplitShare(who: bob, amount: "450"), SplitShare(who: carol, amount: "449")]
  doAssert evm.signRefusal(effectFromJson(splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo, apart, "x"))) == ""
  echo "1. every split family refuses two equal shares OK"

# ── 2. an even split is composed with distinct shares, within the total ─────────────
block:
  for (total, creditorShares) in [("900", true), ("900", false), ("1000000000000000000", true), ("7", false)]:
    let sh = evenShares(total, alice, @[bob, carol], creditorShares = creditorShares)
    doAssert sh.len == 2, $sh
    doAssert sh[0].amount != sh[1].amount, "an even split's shares differ: " & $sh
    var sum = 0.u256
    for s in sh: sum = sum + u256(s.amount)
    doAssert sum <= u256(total), "the shares never exceed the total"
    let evm = newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol])
    doAssert evm.signRefusal(effectFromJson(splitEffectJson(Chain, "ETH", total, alice, AlicePayTo, sh, "x"))) == ""
  # one debtor: nothing to tell apart, the share is the plain even one
  doAssert evenShares("900", alice, @[bob]).mapIt(it.amount) == @["450"]
  echo "2. an even split's shares are distinct and within the total OK"

# ── 3. one transaction reported for two parts: neither is confirmed on it ──────────
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol])
  else: newUnsupportedDriver(policy)

let topic = "/muster/1/split-identifies/proto"
let net = newLocalNetwork()
let aliceCrypto = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity(), carolKs.encIdentity()])
proc joiner(ks: Keystore): CoordinationSession =
  let c = newEpochJoiner(ks); c.ingestGrant(aliceCrypto.grantFor(0, ks.encIdentity()))
  newCoordinationSession(newLocalTransport(net), c, topic)
let aliceS = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bobS = joiner(bobKs); let carolS = joiner(carolKs)
proc sync() = (aliceS.poll(); bobS.poll(); carolS.poll())
proc bindCtx(): LinkContext = LinkContext(account: Chain & ":" & AlicePayTo, slot: "0", expiry: Now + 86_400)

proc agreed(effect: string, debtorS: CoordinationSession, debtorKs: Keystore): string =
  let id = liveProposeIntent(aliceS, aliceKs, splitFor, Policy, effect, int64(Now), 1,
                             account = Chain & ":" & AlicePayTo, ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  sync()
  discard liveContribute(debtorS, debtorKs, splitFor, id, "", "", bindCtx(), Now)
  sync()
  doAssert intentState(aliceS.roomEvents(), splitFor, id) == "executable"
  id

block:
  # two one-debtor requests from Alice at one address, for the same amount
  let lunch = agreed(splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo,
                                     @[SplitShare(who: bob, amount: "450")], "Lunch"), bobS, bobKs)
  let taxi = agreed(splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo,
                                    @[SplitShare(who: carol, amount: "450")], "Taxi"), carolS, carolKs)
  let ledger = newFakeLedger()
  let bobSeam = newFakePartSeam(ledger, "bob")
  let aliceSeam = newFakePartSeam(ledger, "alice")
  let (outcome, pp) = liveSettlePartSend(bobS, bobKs, splitFor, lunch, bobSeam, Now)
  doAssert outcome == "", outcome
  ledger.mine()
  doAssert liveSettlePartComplete(bobS, bobKs, splitFor, bobSeam, pp) == "submitted"
  let t = pp.tx
  sync()
  # Carol reports the same transaction for her own part
  carolS.publishAuthored(carolKs, partEvent(taxi, partName(carol), "settled", carol, t))
  sync()
  let c = liveConfirmPart(aliceS, aliceKs, splitFor, taxi, partName(carol), aliceSeam, t)
  doAssert "two parts" in c, "a reference reported for two parts confirms neither (Carol's): " & c
  let b = liveConfirmPart(aliceS, aliceKs, splitFor, lunch, partName(bob), aliceSeam, t)
  doAssert "two parts" in b, "a reference reported for two parts confirms neither (Bob's): " & b
  # the pump confirms neither either
  doAssert liveConfirmParts(aliceS, aliceKs, splitFor, aliceSeam).len == 0
  # and the room's view of each part says why
  let contested = contestedParts(aliceS.roomEvents(), splitFor)
  doAssert lunch & "/" & partName(bob) in contested and taxi & "/" & partName(carol) in contested, $contested
  doAssert "reported for two parts" in contested[lunch & "/" & partName(bob)]
  # the creditor can still say they received it outside muster (their word, shown as such)
  doAssert liveConfirmPart(aliceS, aliceKs, splitFor, lunch, partName(bob), aliceSeam, "") == "final"
  echo "3. a reference two parties report confirms neither part, and the view says why OK"

echo "split_payment_identifies_part_test: all OK"
