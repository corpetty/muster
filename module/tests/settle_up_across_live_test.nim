## Settle up across assets and chains in a room (exo-a90.17; docs/design/split-the-bill.md
## §4.13). Alice fronted dinner in ETH (Bob and Carol owe her 300 wei each); Bob fronted a
## hotel in BTC on regtest (Carol owes him 5000 sat). Settled up in ETH at Alice's rate of
## 7 wei per 3 sat (5000 sat = 11666 wei): Carol pays Alice 600 and Bob 11366, and Bob's own 300
## to Alice nets out — Bob, owed only on Bitcoin, paid at the Ethereum address he shared. Over the local transport
## and a fake ledger. Held here:
##   * the composer gathers the room's open shares on every public rail, keeps those in the
##     payment asset or one with a rate, and pays a recipient owed only elsewhere at the
##     address they shared for the payment chain — or refuses, naming them, when they shared none;
##   * every client checks each cover against its own split, on its own chain, before agreeing;
##   * the rates count only as a read the proposer recorded (invariant 10);
##   * once final, each creditor marks what it covered received — the Bitcoin hotel goes final
##     with no Bitcoin transaction, by Bob's word;
##   * a covered Bitcoin share is paid only through the settle-up.
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils, sequtils, tables]
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/intent_events
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/parts
import ../src/coordination/settle_up
import ../src/bitcoin/script
import ./probes/live_room

const Evm = "eip155:31337"
const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const EvmPolicy = "evm-split@" & Evm
const BtcPolicy = "btc-split@" & Regtest
const PayA = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
const BobEvm = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let bobBtc = p2wpkhAddress("bcrt", bobKs.btcPubKey())
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == EvmPolicy: newSplitDriver(EvmSplitFamily, Evm, @[alice, bob, carol])
  elif policy == BtcPolicy: newSplitDriver(BtcSplitFamily, Regtest, @[alice, bob, carol])
  else: newUnsupportedDriver(policy)

var r = newRoom3("/muster/1/settle-up-across/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
proc stateOn(s: CoordinationSession, id: string): string =
  sync()
  intentState(s.roomEvents(), splitFor, id)
var seqNo = 0'u64
proc propose(s: CoordinationSession, ks: Keystore, policy, effect, account: string,
             reads: seq[tuple[field, source: string]] = @[]): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, policy, effect, int64(Now), seqNo, account = account, ttlSec = Ttl, reads = reads)

let dinner = r.alice.propose(aliceKs, EvmPolicy, splitEffectJson(Evm, "ETH", "900", alice, PayA,
                              evenShares("900", alice, @[bob, carol]), "Dinner"), Evm & ":" & PayA)
let hotel = r.bob.propose(bobKs, BtcPolicy, splitEffectJson(Regtest, "BTC", "10000", bob, bobBtc,
                          evenShares("10000", bob, @[carol]), "Hotel"), Regtest & ":" & bobBtc)
doAssert dinner.startsWith("0x") and hotel.startsWith("0x"), dinner & " " & hotel
discard agree(r.bob, bobKs, dinner)
doAssert agree(r.carol, room3CarolKs, dinner) == "executable"
doAssert agree(r.carol, room3CarolKs, hotel) == "executable"
echo "0. dinner in ETH (Alice owed 300 by Bob and Carol), a hotel in BTC (Bob owed 5000 sat by Carol) OK"

# ── 1. composing across chains: open shares everywhere, a rate, Bob's own address ──
let btcRate = SettleRate(chain: Regtest, asset: "BTC", rate: "7", per: "3", source: "Alice's BTC/ETH", at: $Now)
sync()
let all = openPartsAll(r.alice.roomEvents(), splitFor, Now)
doAssert all.len == 3 and all.countIt(it.chain == Regtest and it.asset == "BTC") == 1, $all
doAssert openParts(r.alice.roomEvents(), splitFor, Evm, "ETH", Now).len == 2, "one asset: as before"
# Bob has not shared an Ethereum address: the composer names him instead of guessing
let noAddr = settleUpAcross(r.alice.roomEvents(), splitFor, Evm, "ETH", @[btcRate], "Lisbon", Now)
doAssert noAddr.why == "no-address:" & bob, noAddr.why
# a rate for an asset nobody owes in: refused
let stray = settleUpAcross(r.alice.roomEvents(), splitFor, Evm, "ETH",
                           @[SettleRate(chain: "eip155:1", asset: "ETH", rate: "1", per: "1", source: "x", at: $Now)],
                           "Lisbon", Now)
doAssert stray.why.startsWith("no open share"), stray.why
r.bob.publishAuthored(bobKs, newMessageEvent(bob, int64(Now), $(%*{"kind": "address-share", "asset": "ETH",
                                                                 "address": BobEvm, "form": 1}), 1)[1])
sync()
let composed = settleUpAcross(r.alice.roomEvents(), splitFor, Evm, "ETH", @[btcRate], "Lisbon", Now)
doAssert composed.why == "", composed.why
doAssert composed.covers.len == 3
let eff = parseJson(composed.effectJson)
var paid = initTable[string, (string, string)]()
for t in eff["transfers"]: paid[t["to"].getStr()] = (t["payTo"].getStr(), t["amount"].getStr())
# Alice +600; Bob −300 + 11666 = +11366; Carol −300 −11666 = −11966
doAssert paid.getOrDefault(alice) == (PayA, "600"), $paid
doAssert paid.getOrDefault(bob) == (BobEvm, "11366"), "Bob, owed only on Bitcoin, paid at the address he shared: " & $paid
echo "1. the composer nets ETH and BTC shares at the rate, paying Bob where he said, or naming him OK"

# ── 2. the rates count only as a recorded read; every cover is checked against its split ──
# (its own memo: the same effect and policy would be the same intent, id for id)
let unrecordedEffect = settleUpAcross(r.alice.roomEvents(), splitFor, Evm, "ETH", @[btcRate], "Unrecorded", Now).effectJson
let unrecorded = r.alice.propose(aliceKs, EvmPolicy, unrecordedEffect, Evm)
doAssert unrecorded.startsWith("0x"), unrecorded
doAssert agree(r.carol, room3CarolKs, unrecorded) == "unaccountable-input", "rates proposed without their read"
# a Bitcoin cover one sat higher, netted consistently — it balances, so only the check
# against the hotel itself can catch it
var misstated = composed.covers
for c in misstated.mitems:
  if c.chain == Regtest: c.amount = "5001"
let misTs = netTransfers(misstated, @[btcRate], Evm, "ETH", {bob: BobEvm}.toTable)
let wrongCover = r.carol.propose(room3CarolKs, EvmPolicy,
                                 settleUpEffectJson(Evm, "ETH", misstated, misTs, "Forged", @[btcRate]), Evm,
                                 @[(field: "rates", source: "rates:proposer")])
doAssert wrongCover.startsWith("0x"), wrongCover
let wrongWhy = agree(r.bob, bobKs, wrongCover)
doAssert wrongWhy.startsWith("refused") and "5001" in wrongWhy and "5000" in wrongWhy,
         "a Bitcoin cover must say what the hotel says: " & wrongWhy
echo "2. the rates count only as a recorded read; a cover misstating its Bitcoin split is refused OK"

# ── 3. everyone agrees; Bob's client vouches for his address; paid on one chain ─────
doAssert settleAgreeRefusal(effectFromJson(composed.effectJson), bob, @[BobEvm]) == "", "Bob holds the address"
doAssert settleAgreeRefusal(effectFromJson(composed.effectJson), bob, @[PayA]) == "payto-not-mine"
let su = r.alice.propose(aliceKs, EvmPolicy, composed.effectJson, Evm, @[(field: "rates", source: "rates:proposer")])
doAssert su.startsWith("0x"), su
doAssert agree(r.bob, bobKs, su) == "collecting"
doAssert agree(r.carol, room3CarolKs, su) == "executable", "Alice by proposing, Bob and Carol by agreeing"
let ledger = newFakeLedger()
let (direct, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, hotel, newFakePartSeam(ledger, "carol"), Now)
doAssert direct == "covered-by-settle-up", "the Bitcoin share is paid through the settle-up: " & direct
for (s, ks, name) in [(r.bob, bobKs, "bob"), (r.carol, room3CarolKs, "carol")]:
  let seam = newFakePartSeam(ledger, name)
  while true:
    let (outcome, pp) = liveSettlePartSend(s, ks, splitFor, su, seam, Now)
    if outcome.len > 0: break
    ledger.mine()
    doAssert pp.transfer.chain == Evm and pp.transfer.asset == "ETH", "every payment is on the payment rail"
    discard liveSettlePartComplete(s, ks, splitFor, seam, pp)
sync()
discard liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
discard liveConfirmParts(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob"))
doAssert stateOn(r.carol, su) == "final", "every net payment confirmed by its own recipient"
echo "3. everyone agrees, Bob vouching for his address; every payment is ETH on one chain OK"

# ── 4. final: each creditor marks what it covered — the hotel goes final by Bob's word ──
doAssert settleCovered(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice")).len == 2, "the dinner's two shares"
doAssert settleCovered(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob")).len == 1, "the hotel's one share"
for s in [r.alice, r.bob, r.carol]:
  doAssert stateOn(s, dinner) == "final" and stateOn(s, hotel) == "final",
           "the ETH dinner and the BTC hotel final on every member, with no Bitcoin transaction"
echo "4. the settle-up final: the dinner and the Bitcoin hotel go final on all three OK"

echo "settle_up_across_live_test: all OK"
