## Settling up across assets and chains (exo-a90.17; docs/design/split-the-bill.md §4.13).
## Held here, without a room:
##   * each cover converts on its own at its asset's signed rate, rounded down, and the net
##     transfers conserve every member's balance in the payment asset;
##   * the driver refuses a cover in an asset with no rate, a rate no cover uses, a rate on
##     the payment asset itself, a cover that converts to nothing, the private split, and a
##     netting that does not conserve;
##   * a recipient owed on the payment chain is paid where that split agreed; one owed only
##     elsewhere is paid at an address on the payment chain they vouch for — their client
##     refuses to agree to one it does not hold (payto-not-mine);
##   * the rates and each cover's own chain and asset are the signed bytes, and the cover
##     claims carry each cover's own chain and asset, so the core checks it against its split;
##   * a settle-up in one asset is byte for byte what it was.
## Needs libsodium (Ed25519).

import std/[json, strutils, sequtils, tables]
import stint
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/split
import ../src/intents/materialization
import ../src/crypto/curve25519
import ../src/coordination/intent_events

const Evm = "eip155:31337"
const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const Lez = "lez:testnet"
const Usdc = "erc20:0x5fbdb2315678afecb367f032d93f642f64180aa3"
proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc filled(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc idOf(k: EncKeys): string = hexOf(k.identity().toBytes())
let alice = encFromSeed(filled(71))
let bob = encFromSeed(filled(72))
let carol = encFromSeed(filled(73))
let (a, b, c) = (idOf(alice), idOf(bob), idOf(carol))
const PayA = "0xaaaa000000000000000000000000000000000001"
const PayB = "0xbbbb000000000000000000000000000000000002"
const PayBEvm2 = "0xbbbb000000000000000000000000000000000003"   # Bob, vouched on the payment chain
const PayBBtc = "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
const S1 = "0x1111111111111111"
const S2 = "0x2222222222222222"
const S3 = "0x3333333333333333"

# dinner (S1) in ETH: Bob and Carol owe Alice 300 each; taxi (S2) in USDC on the same chain:
# Alice owes Bob 200; a hotel (S3) in BTC on regtest: Carol owes Bob 5000 sat.
# Rates into ETH: 3 wei per 2 USDC units; 7 wei per 3 sat.
let dinnerB = Cover(intent: S1, debtor: b, creditor: a, amount: "300", payTo: PayA, chain: Evm, asset: "ETH")
let dinnerC = Cover(intent: S1, debtor: c, creditor: a, amount: "300", payTo: PayA, chain: Evm, asset: "ETH")
let taxiA = Cover(intent: S2, debtor: a, creditor: b, amount: "200", payTo: PayB, chain: Evm, asset: Usdc)
let hotelC = Cover(intent: S3, debtor: c, creditor: b, amount: "5000", payTo: PayBBtc, chain: Regtest, asset: "BTC")
let usdcRate = SettleRate(chain: Evm, asset: Usdc, rate: "3", per: "2", source: "a probe's USDC/ETH", at: "1800000000")
let btcRate = SettleRate(chain: Regtest, asset: "BTC", rate: "7", per: "3", source: "a probe's BTC/ETH", at: "1800000000")
let covers = @[dinnerB, dinnerC, taxiA, hotelC]
let rates = @[usdcRate, btcRate]

proc netOf(ts: seq[NetTransfer]): Table[string, int] =
  for t in ts:
    result[t.frm] = result.getOrDefault(t.frm) - parseInt(t.amount)
    result[t.to] = result.getOrDefault(t.to) + parseInt(t.amount)

# ── 1. each cover converts on its own; the transfers conserve converted balances ────
block:
  doAssert convertedAmount(dinnerB, rates, Evm, "ETH") == (true, "300", ""), "the payment asset is itself"
  doAssert convertedAmount(taxiA, rates, Evm, "ETH") == (true, "300", ""), "200 × 3 ÷ 2"
  doAssert convertedAmount(hotelC, rates, Evm, "ETH") == (true, "11666", ""), "5000 × 7 ÷ 3, rounded down"
  doAssert not convertedAmount(hotelC, @[usdcRate], Evm, "ETH").ok, "no rate for BTC"
  let tiny = Cover(intent: S3, debtor: c, creditor: b, amount: "1", payTo: PayBBtc, chain: Regtest, asset: "BTC")
  doAssert not convertedAmount(tiny, @[SettleRate(chain: Regtest, asset: "BTC", rate: "1", per: "3",
                                                  source: "x", at: "1")], Evm, "ETH").ok, "converts to nothing"
  # Alice: +600 − 300 = +300; Bob: −300 + 300 + 11666 = +11666; Carol: −300 − 11666 = −11966
  let ts = netTransfers(covers, rates, Evm, "ETH", {b: PayBEvm2}.toTable)
  let n = netOf(ts)
  doAssert n.getOrDefault(a) == 300 and n.getOrDefault(b) == 11666 and n.getOrDefault(c) == -11966, $n
  for t in ts:
    doAssert t.payTo == (if t.to == a: PayA else: PayB),
             "Bob is owed on the payment chain (the taxi): paid where the taxi agreed, not at a vouched address"
  let onlyElsewhere = netTransfers(@[dinnerB, hotelC], rates, Evm, "ETH", {b: PayBEvm2}.toTable)
  doAssert onlyElsewhere.anyIt(it.to == b and it.payTo == PayBEvm2),
           "Bob owed only on Bitcoin: paid at the address he vouches for on the payment chain: " & $onlyElsewhere
  doAssert netTransfers(@[dinnerB, hotelC], rates, Evm, "ETH").anyIt(it.to == b and it.payTo == ""),
           "no vouched address known: no payTo, for the composer to refuse"
  echo "1. each cover converts on its own, rounded down; the transfers conserve every balance in the payment asset OK"

# ── 2. the driver: rates, conversion, conservation, where a recipient is paid ────────
let drv = newSplitDriver(EvmSplitFamily, Evm, @[a, b, c])
proc across(cs: seq[Cover], rs: seq[SettleRate], ts: seq[NetTransfer], memo = "Lisbon"): Effect =
  effectFromJson(settleUpEffectJson(Evm, "ETH", cs, ts, memo, rs))
let goodTs = netTransfers(covers, rates, Evm, "ETH")
let good = across(covers, rates, goodTs)
block:
  doAssert drv.signRefusal(good) == "", drv.signRefusal(good)
  doAssert "rate" in drv.signRefusal(across(covers, @[usdcRate], goodTs)), "a cover in an asset with no rate"
  let unused = SettleRate(chain: "eip155:1", asset: "ETH", rate: "1", per: "1", source: "x", at: "1")
  doAssert "rate" in drv.signRefusal(across(covers, @[unused, usdcRate, btcRate], goodTs)), "a rate no cover uses"
  let self = SettleRate(chain: Evm, asset: "ETH", rate: "1", per: "1", source: "x", at: "1")
  doAssert drv.signRefusal(across(covers, @[self, usdcRate, btcRate], goodTs)).len > 0, "a rate on the payment asset"
  var swapped = parseJson(settleUpEffectJson(Evm, "ETH", covers, goodTs, "Lisbon", rates))
  swapped["rates"] = %*[swapped["rates"][1], swapped["rates"][0]]      # the composer sorts; a forger need not
  doAssert "sorted" in drv.signRefusal(effectFromJson($swapped)), "rates in their one order"
  doAssert "source" in drv.signRefusal(across(covers, @[usdcRate, SettleRate(chain: Regtest, asset: "BTC",
                                        rate: "7", per: "3", source: "", at: "1")], goodTs)), "a rate names its source"
  # conservation, in the payment asset
  var short = goodTs
  short[0].amount = $(parseInt(short[0].amount) - 1)
  doAssert "balance" in drv.signRefusal(across(covers, rates, short)), "a netting that does not conserve"
  # converted at face value instead of at the rate: refused
  let faceValue = netTransfers(covers.mapIt(Cover(intent: it.intent, debtor: it.debtor, creditor: it.creditor,
                                                  amount: it.amount, payTo: it.payTo, chain: Evm, asset: "ETH")))
  doAssert drv.signRefusal(across(covers, rates, faceValue)).len > 0, "covers are converted at their rates"
  # the private split is never netted, whatever the rate
  let priv = Cover(intent: S3, debtor: c, creditor: b, amount: "5000",
                   payTo: "priv:" & "ab".repeat(32) & ":" & "cd".repeat(33), chain: Lez, asset: "LEZ")
  let lezRate = SettleRate(chain: Lez, asset: "LEZ", rate: "1", per: "1", source: "x", at: "1")
  doAssert "private" in drv.signRefusal(across(@[dinnerB, dinnerC, taxiA, priv], @[usdcRate, lezRate],
                                                netTransfers(@[dinnerB, dinnerC, taxiA, priv], @[usdcRate, lezRate], Evm, "ETH"))),
           "the private split is never netted"
  # a cover whose payTo is not an address of its own chain
  let wrongPay = Cover(intent: S3, debtor: c, creditor: b, amount: "5000", payTo: PayB, chain: Regtest, asset: "BTC")
  doAssert drv.signRefusal(across(@[dinnerB, dinnerC, taxiA, wrongPay], rates, goodTs)).len > 0,
           "a Bitcoin cover pays a Bitcoin address"
  # where a recipient is paid: owed on the payment chain — only where that split agreed
  var elsewhere = goodTs
  for t in elsewhere.mitems:
    if t.to == b: t.payTo = PayBEvm2
  doAssert "agreed" in drv.signRefusal(across(covers, rates, elsewhere)),
           "Bob is owed by the taxi on the payment chain: paid only where the taxi agreed"
  # owed only elsewhere: any address of the payment chain — theirs to vouch for
  let cs2 = @[dinnerB, dinnerC, hotelC]
  let rs2 = @[btcRate]
  let vouched = netTransfers(cs2, rs2, Evm, "ETH", {b: PayBEvm2}.toTable)
  doAssert drv.signRefusal(across(cs2, rs2, vouched)) == "", drv.signRefusal(across(cs2, rs2, vouched))
  var notEvm = vouched
  for t in notEvm.mitems:
    if t.to == b: t.payTo = PayBBtc
  doAssert drv.signRefusal(across(cs2, rs2, notEvm)).len > 0, "a vouched address is still one of the payment chain"
  echo "2. the driver: every other asset has its one rate, covers convert at it, balances conserve, recipients paid where they may be OK"

# ── 3. the signed bytes, the parties, the parts, the cover claims ─────────────────────
block:
  let m = decode(canonicalize(drv, good).bytes)
  doAssert m.kind == ckArray and m.arr.len == 8 and m.arr[0].t == SettleUpDomain, "the rates are the eighth element"
  doAssert m.arr[4].arr.allIt(it.arr.len == 7), "each cover names its own chain and asset"
  var other = rates
  other[1].source = "another source"
  doAssert canonicalize(drv, across(covers, other, goodTs)).bytes != canonicalize(drv, good).bytes,
           "a rate's source is signed"
  doAssert describeFor(drv, good).threshold == 3, "everyone the covered parts name agrees"
  for p in drv.settlementParts(good):
    let t = drv.partTransfer(good, p)
    doAssert t.ok and t.chain == Evm and t.asset == "ETH", "every part pays on the payment rail"
  let claims = drv.covers(good)
  doAssert claims.len == 4
  for cl in claims:
    let want = covers.filterIt(it.intent == cl.intent and partName(it.debtor) == cl.part)[0]
    doAssert cl.chain == want.chain and cl.asset == want.asset and cl.amount == want.amount,
             "a claim is the cover as its own split says it: " & $cl
  let j = parseJson(settleUpEffectJson(Evm, "ETH", covers, goodTs, "Lisbon", rates))
  doAssert j["sources"] == %*{"rates": "read"}, "the rates are an external read (invariant 10)"
  echo "3. the rates and each cover's chain and asset are signed; claims carry them; the rates are a declared read OK"

# ── 4. a vouched address is the recipient's word: their client refuses one it does not hold ──
block:
  let cs2 = @[dinnerB, dinnerC, hotelC]
  let e = across(cs2, @[btcRate], netTransfers(cs2, @[btcRate], Evm, "ETH", {b: PayBEvm2}.toTable))
  doAssert settleAgreeRefusal(e, b, @[PayBEvm2]) == "", "Bob holds the address he is paid at"
  doAssert settleAgreeRefusal(e, b, @["0x9999000000000000000000000000000000000009"]) == "payto-not-mine",
           "Bob's client never vouches for an address it does not hold"
  doAssert settleAgreeRefusal(e, a, @[]) == "", "Alice is paid where her dinner agreed: nothing to vouch for"
  doAssert settleAgreeRefusal(e, c, @[]) == "", "Carol only pays"
  doAssert settleAgreeRefusal(good, b, @[]) == "", "Bob paid where the taxi agreed: nothing to vouch for"
  echo "4. a recipient owed only elsewhere vouches for their address by agreeing; their client checks it OK"

# ── 5. a settle-up in one asset is byte for byte what it was ──────────────────────────
block:
  let one = @[Cover(intent: S1, debtor: b, creditor: a, amount: "300", payTo: PayA),
              Cover(intent: S1, debtor: c, creditor: a, amount: "300", payTo: PayA),
              Cover(intent: S2, debtor: a, creditor: b, amount: "200", payTo: PayB)]
  let js = settleUpEffectJson(Evm, "ETH", one, netTransfers(one), "Lisbon")
  doAssert "\"rates\"" notin js and "\"sources\"" notin js and "\"chain\":\"eip155:31337\",\"asset\"" notin js.split("covers")[1],
           "no rates, no sources, covers without their own chain: " & js
  let m = decode(canonicalize(drv, effectFromJson(js)).bytes)
  doAssert m.arr.len == 7 and m.arr[4].arr.allIt(it.arr.len == 5), "the settle-up of exo-3c6, unchanged"
  # covers from openParts carry their chain and asset; in one asset they are not written
  let fromOpen = one.mapIt(Cover(intent: it.intent, debtor: it.debtor, creditor: it.creditor, amount: it.amount,
                                 payTo: it.payTo, chain: Evm, asset: "ETH"))
  doAssert settleUpEffectJson(Evm, "ETH", fromOpen, netTransfers(fromOpen), "Lisbon") == js, "one spelling"
  # a cover naming its own chain with no rates at all: not the one spelling
  var j = parseJson(js)
  j["covers"][0]["chain"] = %Evm
  j["covers"][0]["asset"] = %"ETH"
  doAssert drv.signRefusal(effectFromJson($j)).len > 0, "in one asset, covers name no chain of their own"
  echo "5. a settle-up in one asset is byte for byte what it was OK"

# ── 6. a conversion that overflows 256 bits is refused, never wrapped ─────────────────
block:
  let big = Cover(intent: S2, debtor: c, creditor: b, amount: "1" & repeat('0', 70), payTo: PayB,
                  chain: Regtest, asset: "BTC")
  let huge = SettleRate(chain: Regtest, asset: "BTC", rate: "1" & repeat('0', 10), per: "1",
                        source: "test", at: "1790000000")
  let conv = convertedAmount(big, @[huge], Evm, "ETH")
  doAssert not conv.ok and "overflow" in conv.why,
           "10^70 × 10^10 does not fit 256 bits: refused, never wrapped — got " & $conv
  let fits = convertedAmount(Cover(intent: S2, debtor: c, creditor: b, amount: "1" & repeat('0', 60), payTo: PayB,
                                   chain: Regtest, asset: "BTC"), @[huge], Evm, "ETH")
  doAssert fits.ok and fits.amount == "1" & repeat('0', 70), "10^60 × 10^10 fits: " & $fits
  echo "6. a conversion that overflows is refused, never wrapped OK"

# ── 7. a rate as a person gives it: per ONE unit, kept exact in base units ─────────────
block:
  # "1 BTC = 21.4 ETH": 21.4 × 10^18 wei per 10^8 sat
  let r = settleRate(Regtest, "BTC", "21.4", 18, 8, " CoinGecko ", 1790000000)
  doAssert r.ok and r.rate.rate == "21400000000000000000" and r.rate.per == "100000000", $r
  doAssert r.rate.source == "CoinGecko" and r.rate.at == "1790000000" and r.rate.chain == Regtest, $r
  doAssert ratePerUnit(r.rate, 8) == "21400000000000000000", "the card reads back 21.4 ETH per BTC"
  let five = convertedAmount(Cover(intent: S2, debtor: c, creditor: b, amount: "5000", payTo: PayB,
                                   chain: Regtest, asset: "BTC"), @[r.rate], Evm, "ETH")
  doAssert five.ok and five.amount == "1070000000000000", "5000 sat at 21.4 ETH/BTC = 0.00107 ETH: " & $five
  # paid in a 6-decimal token: "1 ETH = 2500.5 USDC" — 2500500000 per 10^18 wei
  let t = settleRate(Evm, "ETH", "2500.5", 6, 18, "my exchange", 1790000000)
  doAssert t.ok and t.rate.rate == "2500500000" and t.rate.per == "1" & repeat('0', 18), $t
  doAssert ratePerUnit(t.rate, 18) == "2500500000"
  # refused: no source, too long a source, not a plain decimal, zero, finer than a base unit,
  # unknown decimals
  doAssert not settleRate(Regtest, "BTC", "21.4", 18, 8, "  ", 0).ok
  doAssert not settleRate(Regtest, "BTC", "21.4", 18, 8, repeat('x', MaxQuoteSource + 1), 0).ok
  for bad in ["", "-1", "1e3", "21.4.1", ".5", "0", "0.0", "0x10", "21,4"]:
    doAssert not settleRate(Regtest, "BTC", bad, 18, 8, "s", 0).ok, "refused: " & bad
  doAssert not settleRate(Evm, "ETH", "0.0000001", 6, 18, "s", 0).ok, "finer than one base unit of the payment asset"
  doAssert not settleRate(Evm, Usdc, "1", 18, -1, "s", 0).ok, "a token whose decimals could not be read"
  doAssert ratePerUnit(SettleRate(rate: "7", per: "0"), 8) == "" and ratePerUnit(r.rate, -1) == ""
  echo "7. a rate as a person gives it is kept exact in base units, and read back per one unit OK"

echo "settle_up_across_test: all OK"
