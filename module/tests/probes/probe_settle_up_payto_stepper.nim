## derived-exo-a90.17 s4: where a recipient is paid — one owed by a covered split on the payment
## chain is paid only at that split's payTo; one owed only on other chains is paid at an address
## on the payment chain they vouch for, the last one they shared into the room for that chain,
## and the proposal is refused naming them when they shared none; their own client agrees only to
## an address it holds (payto-not-mine); an address a split agreed on one chain is never taken as
## that recipient's address on another (exo-a90.17).
##
## STEPPER: state = one case of a grid — payment chain {eip155:31337 in ETH, Bitcoin regtest} x
## how Bob is owed {by a covered split on the payment chain, at an address the split agreed that
## is neither of his shared ones; only on the other rail; only on eip155:1, a split there naming
## his own Ethereum address} x what Bob shared for the payment chain {nothing; one address; two,
## the later his; only an address of the other kind} x whether his client holds the address he
## would be paid at {yes, no}: 48 cases, chained case -> case+1. Every case also has Alice owed
## by Carol on the payment chain and Dave owed by Carol on the other rail (Dave shared his
## address), so each settle-up is across assets. Over the live path, the REAL settleUpAcross
## composes it at the proposer's rates. The rule, stated alone:
##   * owed on the payment chain: Bob is paid at his split's payTo whatever he shared; his client
##     needs to vouch for nothing; a settle-up paying him anywhere else is refused by the driver;
##   * owed only elsewhere: with nothing shared for the payment chain (or only an address of the
##     other kind) the composer refuses "no-address:<Bob>" — never Bob's eip155:1 split's payTo;
##     else he is paid at the last address he shared for it, and his client's check
##     (settleAgreeRefusal) passes iff it holds that address, else "payto-not-mine";
##   * Carol's agreement to the honest settle-up counts, and Bob's counts when his client's
##     check passes.
## Run by hand (no argv), it checks all 48 with doAssert.

import std/[json, strutils, tables, sequtils]
import ../../src/bitcoin/[script, keys]
import ./settle_across_room
import ./oracle_emit

const N = 48
const At = 1_790_000_000'i64
const EarlierEvm = "0x9999999999999999999999999999999999999999"
const SplitEvm = "0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"   ## what Bob's on-chain split agreed: neither share
proc filled(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
let SplitBtc = p2wpkhAddress("bcrt", compressedPubKey(filled(9)))
let EarlierBtc = p2wpkhAddress("bcrt", compressedPubKey(filled(10)))

proc decode(k: int): tuple[btcPay: bool, owed: string, shared: string, holds: bool] =
  (k div 24 == 1, ["here", "elsewhere", "mainnet"][(k div 8) mod 3],
   ["none", "one", "two", "other-kind"][(k div 2) mod 4], k mod 2 == 0)

proc correct(k: int): bool =
  let (btcPay, owed, shared, holds) = decode(k)
  var r = newRoom4("/muster/1/probe-payto-" & $k & "/proto")
  let (payChain, payAsset) = (if btcPay: (BtcChain, "BTC") else: (EvmChain, "ETH"))
  let (otherChain, otherAsset) = (if btcPay: (EvmChain, "ETH") else: (BtcChain, "BTC"))
  proc total(chain: string): string = (if chain == BtcChain: "100000" else: "20000000000000000")
  # Alice owed on the payment chain, Dave on the other rail, Bob as the case says
  discard r.splitAgreed(payChain, payAsset, "alice", @["carol"], total(payChain), "alice " & $k)
  discard r.splitAgreed(otherChain, otherAsset, "dave", @["carol"], total(otherChain), "dave " & $k)
  let bobPayTo = (if btcPay: SplitBtc else: SplitEvm)
  case owed
  of "here": discard r.splitAgreed(payChain, payAsset, "bob", @["carol"], total(payChain), "bob " & $k, payTo = bobPayTo)
  of "elsewhere": discard r.splitAgreed(otherChain, otherAsset, "bob", @["carol"], total(otherChain), "bob " & $k)
  else: discard r.splitAgreed(MainChain, "ETH", "bob", @["carol"], total(MainChain), "bob " & $k,
                              payTo = evmAddrOf["bob"])
  # what Dave and Bob shared into the room for the payment chain
  let (kind, mine, earlier, otherKind, otherAddr) =
    (if btcPay: ("BTC", btcAddrOf("bob"), EarlierBtc, "ETH", evmAddrOf["bob"])
     else: ("ETH", evmAddrOf["bob"], EarlierEvm, "BTC", btcAddrOf("bob")))
  r.shareAddress("dave", kind, payToOn("dave", payChain), seqNo = 50)
  case shared
  of "one": r.shareAddress("bob", kind, mine, seqNo = 51)
  of "two": (r.shareAddress("bob", kind, earlier, seqNo = 51); r.shareAddress("bob", kind, mine, seqNo = 52))
  of "other-kind": r.shareAddress("bob", otherKind, otherAddr, seqNo = 51)
  else: discard
  # the rates: one per other chain and asset someone is owed in
  var rates: seq[SettleRate]
  let payDec = (if btcPay: 8 else: 18)
  rates.add settleRate(otherChain, otherAsset, (if btcPay: "0.05" else: "21.4"), payDec,
                       (if otherAsset == "BTC": 8 else: 18), "Alice's quote", At).rate
  if owed == "mainnet":
    rates.add settleRate(MainChain, "ETH", (if btcPay: "0.05" else: "1"), payDec, 18, "Alice's quote", At).rate
  let composed = settleUpAcross(r.alice.roomEvents(), acrossFor, payChain, payAsset, rates, "payto " & $k, Now)
  # the rule, stated alone
  let vouches = owed != "here"
  let mustRefuse = vouches and shared in ["none", "other-kind"]
  if mustRefuse: return composed.why == "no-address:" & bob
  if composed.why.len > 0:
    stderr.writeLine "case " & $k & ": not composed: " & composed.why
    return false
  let e = effectFromJson(composed.effectJson)
  let su = settleUpOf(e)
  var toBob = su.transfers.filterIt(it.to == bob)
  if toBob.len != 1: return false
  let want = (if vouches: mine else: bobPayTo)
  if toBob[0].payTo != want: return false
  # Bob's client: vouches only for an address it holds
  let held = (if holds: @[toBob[0].payTo] else: @[payToOn("carol", payChain)])
  let check = settleAgreeRefusal(e, bob, held)
  if vouches and not holds: (if check != "payto-not-mine": return false)
  elif check != "": return false
  # owed here: paying Bob anywhere but his split's payTo is refused by the driver
  if not vouches:
    let drv = newSplitDriver((if btcPay: BtcSplitFamily else: EvmSplitFamily), payChain, roster)
    let j = parseJson(composed.effectJson)
    for t in j["transfers"]:
      if t["to"].getStr() == bob: t["payTo"] = %mine
    if drv.signRefusal(effectFromJson($j)).len == 0: return false
  # over the live path: Carol agrees; Bob agrees when his client's check passes
  let id = r.proposeAs("alice", policyOf(payChain), composed.effectJson, payChain,
                       @[(field: "rates", source: "rates:proposer")])
  if not id.startsWith("0x"): return false
  r.sync()
  if r.agreeAs("carol", id) notin ["collecting", "executable"]: return false
  if check == "" and r.agreeAs("bob", id) notin ["collecting", "executable"]: return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (btcPay, owed, shared, holds) = decode(k)
    doAssert correct(k), "case " & $k & ": pay on " & (if btcPay: "Bitcoin" else: "Ethereum") & ", Bob owed " & owed &
                         ", shared " & shared & ", holds " & $holds & " — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
