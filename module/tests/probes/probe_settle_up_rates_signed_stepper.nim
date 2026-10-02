## derived-exo-a90.17 s3: the rates are the proposer's recorded quote — exactly one rate for
## each chain and asset the covered shares use other than the payment one (none for the payment
## asset, none unused, each once, in one order), each naming its source and time; the rates are
## in the signed bytes, so changing a rate, its source or its time changes them; and they reach
## the signed bytes only as an external read the proposer recorded before anyone agreed —
## without it no agreement counts (invariant 10; exo-a90.17).
##
## STEPPER: state = one of 21 cases, chained case -> case+1. The base: Carol owes Alice 300000
## wei for dinner, Bob 5000 sat for a hotel on Bitcoin regtest, and Dave 7 tokens for a taxi,
## settled up in ETH on eip155:31337 at 21.4 ETH per BTC and 0.0004 ETH per token. Cases:
##   0      the base: the driver accepts it;
##   1-12   one malformed rate set each, which the driver refuses: the BTC rate missing; a rate
##          no cover uses; a rate for the payment asset; a rate twice; the rates out of order;
##          an empty source; a source over MaxQuoteSource; a non-canonical rate; a zero per; a
##          zero rate; a time that is not unix seconds; a rate (and a cover) on the private zone;
##   13-17  the signed bytes (materialize): the rate changed (the payments re-netted), rate and
##          per both doubled (the same conversion), the source changed, the time changed — each
##          valid and each giving other bytes; and nothing changed — the same bytes, eight
##          elements, the rates the eighth;
##   18-20  over the live path in a room: Carol's agreement counts when the proposer recorded
##          the rates as a read, is refused "unaccountable-input" when they did not, and a
##          settle-up in one asset needs no read at all.
## Run by hand (no argv), it checks all 21 with doAssert.

import std/[json, strutils, tables]
import ../../src/dcbor/dcbor
import ../../src/intents/materialization
import ./settle_across_room
import ./oracle_emit

const At = 1_790_000_000'i64
const N = 21
let Dinner = "0x" & repeat("11", 32)
let Hotel = "0x" & repeat("22", 32)
let Taxi = "0x" & repeat("33", 32)
let drv = newSplitDriver(EvmSplitFamily, EvmChain, roster)

let covers = @[Cover(intent: Dinner, debtor: carol, creditor: alice, amount: "300000", payTo: evmAddrOf["alice"],
                     chain: EvmChain, asset: "ETH"),
               Cover(intent: Hotel, debtor: carol, creditor: bob, amount: "5000", payTo: btcAddrOf("bob"),
                     chain: BtcChain, asset: "BTC"),
               Cover(intent: Taxi, debtor: carol, creditor: dave, amount: "7000000", payTo: evmAddrOf["dave"],
                     chain: EvmChain, asset: Token)]
let vouched = {bob: evmAddrOf["bob"]}.toTable
let btcRate = settleRate(BtcChain, "BTC", "21.4", 18, 8, "Alice's BTC/ETH", At).rate
let tokRate = settleRate(EvmChain, Token, "0.0004", 18, 6, "Alice's MTD/ETH", At).rate

proc effectWith(rates: seq[SettleRate], memo = "lisbon"): string =
  settleUpEffectJson(EvmChain, "ETH", covers, netTransfers(covers, rates, EvmChain, "ETH", vouched), memo, rates)
let baseJson = effectWith(@[btcRate, tokRate])

proc refusalOf(js: string): string =
  try: drv.signRefusal(effectFromJson(js))
  except CatchableError as e: "unreadable: " & e.msg

proc edited(f: proc (j: JsonNode)): string =
  let j = parseJson(baseJson)
  f(j)
  $j

proc bytesOf(js: string): seq[byte] = canonicalize(drv, effectFromJson(js)).bytes

proc liveCase(k: int): bool =
  var r = newRoom4("/muster/1/probe-rates-signed-" & $k & "/proto")
  for i, m in Members: r.shareAddress(m, "ETH", evmAddrOf[m], seqNo = 100 + i)
  discard r.splitAgreed(EvmChain, "ETH", "alice", @["bob", "carol"], "900000", "dinner")
  discard r.splitAgreed(EvmChain, "ETH", "dave", @["carol", "bob"], "600000", "lunch")
  discard r.splitAgreed(BtcChain, "BTC", "bob", @["carol"], "10000", "hotel")
  let events = r.alice.roomEvents()
  if k == 20:                                         # one asset: no rates, no read
    let one = openParts(events, acrossFor, EvmChain, "ETH", Now)
    let id = r.proposeAs("alice", EvmPolicy, settleUpEffectJson(EvmChain, "ETH", one, netTransfers(one), "one asset"),
                         EvmChain)
    if not id.startsWith("0x"): return false
    r.sync()
    return r.agreeAs("carol", id) in ["collecting", "executable"]
  let composed = settleUpAcross(events, acrossFor, EvmChain, "ETH", @[btcRate], (if k == 18: "read" else: "unread"), Now)
  if composed.why.len > 0: return false
  let reads = (if k == 18: @[(field: "rates", source: "rates:proposer")] else: @[])
  let id = r.proposeAs("alice", EvmPolicy, composed.effectJson, EvmChain, reads)
  if not id.startsWith("0x"): return false
  r.sync()
  let outcome = r.agreeAs("carol", id)
  if k == 18: outcome in ["collecting", "executable"] else: outcome == "unaccountable-input"

proc correct(k: int): bool =
  case k
  of 0: refusalOf(baseJson) == ""
  of 1: refusalOf(effectWith(@[tokRate])).len > 0        # netted without the hotel's rate: no BTC rate
  of 2: refusalOf(edited(proc (j: JsonNode) = j["rates"].add %*{"chain": MainChain, "asset": "ETH", "rate": "1",
                                                                 "per": "1", "source": "x", "at": $At})).len > 0
  of 3: refusalOf(edited(proc (j: JsonNode) = j["rates"].add %*{"chain": EvmChain, "asset": "ETH", "rate": "1",
                                                                 "per": "1", "source": "x", "at": $At})).len > 0
  of 4: refusalOf(edited(proc (j: JsonNode) = j["rates"].add j["rates"][0].copy)).len > 0
  of 5: refusalOf(edited(proc (j: JsonNode) =
          swap(j["rates"].elems[0], j["rates"].elems[1]))).len > 0
  of 6: refusalOf(edited(proc (j: JsonNode) = j["rates"][0]["source"] = %"  ")).len > 0
  of 7: refusalOf(edited(proc (j: JsonNode) = j["rates"][0]["source"] = %repeat('x', MaxQuoteSource + 1))).len > 0
  of 8: refusalOf(edited(proc (j: JsonNode) = j["rates"][0]["rate"] = %("0" & j["rates"][0]["rate"].getStr()))).len > 0
  of 9: refusalOf(edited(proc (j: JsonNode) = j["rates"][0]["per"] = %"0")).len > 0
  of 10: refusalOf(edited(proc (j: JsonNode) = j["rates"][0]["rate"] = %"0")).len > 0
  of 11: refusalOf(edited(proc (j: JsonNode) = j["rates"][0]["at"] = %"soon")).len > 0
  of 12:
    let lezPayTo = "priv:" & repeat("ab", 32) & ":" & repeat("cd", 33)
    refusalOf(edited(proc (j: JsonNode) =
      j["covers"].add %*{"intent": "0x" & repeat("44", 32), "debtor": carol, "creditor": alice, "amount": "1000",
                         "payTo": lezPayTo, "chain": LezChain, "asset": "LEZ"}
      j["rates"].add %*{"chain": LezChain, "asset": "LEZ", "rate": "1", "per": "1", "source": "x", "at": $At})).len > 0
  of 13:                                             # the rate changed: re-netted, valid, other bytes
    var rs = btcRate
    rs.rate = $(big(rs.rate).v * 2.stuint(512))
    let js = effectWith(@[rs, tokRate])
    refusalOf(js) == "" and bytesOf(js) != bytesOf(baseJson)
  of 14:                                             # rate and per doubled: the same conversion
    var rs = btcRate
    rs.rate = $(big(rs.rate).v * 2.stuint(512))
    rs.per = $(big(rs.per).v * 2.stuint(512))
    let js = effectWith(@[rs, tokRate])
    parseJson(js)["transfers"] == parseJson(baseJson)["transfers"] and refusalOf(js) == "" and
      bytesOf(js) != bytesOf(baseJson)
  of 15:
    var rs = btcRate
    rs.source = "someone else's quote"
    let js = effectWith(@[rs, tokRate])
    refusalOf(js) == "" and bytesOf(js) != bytesOf(baseJson)
  of 16:
    var rs = btcRate
    rs.at = $(At + 1)
    let js = effectWith(@[rs, tokRate])
    refusalOf(js) == "" and bytesOf(js) != bytesOf(baseJson)
  of 17:
    let again = $parseJson(baseJson)
    let m = decode(bytesOf(baseJson))
    bytesOf(again) == bytesOf(baseJson) and m.arr.len == 8 and m.arr[7].arr.len == 2
  else: liveCase(k)

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N: doAssert correct(k), "case " & $k & " judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
