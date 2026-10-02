## derived-exo-a90.17 s1: each conversion is exact — every covered share in another asset
## converts on its own at that asset's signed rate, amount × rate ÷ per, rounded down, the
## debtor keeping a remainder under one base unit of the payment asset; a share that converts
## to nothing, or whose product overflows 256 bits, is refused, never wrapped; a rate typed per
## ONE unit is kept exactly in base units on both sides, and one finer than the payment asset's
## smallest unit, zero, or not a plain decimal is refused (exo-a90.17, exo-df6).
##
## STEPPER: state = one case of a grid — payment asset {ETH at 18 decimals, a 6-decimal token,
## BTC at 8} x covered asset {the other two} x typed rate {21.4, 2500.5, 1, one finer than any
## base unit here, 0, 1e3, 21.4.1, a 70-digit integer} x share {1, 5000, 10^60, 10^70}: 192
## cases. A grader state is one row — a payment asset, covered asset and rate with all four
## shares — chained row -> row+1, 48 rows. The probe does its OWN arithmetic (its own decimal
## parse, a 512-bit product, never the module's): the rate is representable iff it is a plain
## decimal within the payment asset's decimals, above zero, and fits 256 bits; the conversion
## is product div per, refused iff the product passes 256 bits or the result is zero. Then:
## settleRate keeps exactly rate x 10^payDecimals per 10^decimals, or refuses exactly when that
## is not representable; ratePerUnit reads it back; convertedAmount equals the probe's floor or
## refuses exactly when the probe does (an overflow named as one); and the driver accepts a
## settle-up whose payment carries exactly that conversion and refuses one unit more or less.
## Run by hand (no argv), it checks all 192 with doAssert.

import std/[json, strutils]
import ../../src/intents/materialization
import ./settle_across_room
import ./oracle_emit

type Asset = tuple[asset, chain: string, decimals: int]
const Pays: array[3, Asset] = [("ETH", EvmChain, 18), (Token, EvmChain, 6), ("BTC", BtcChain, 8)]
let Fine = "0." & repeat('0', 30) & "1"
let Rates = ["21.4", "2500.5", "1", Fine, "0", "1e3", "21.4.1", repeat('9', 70)]
let Shares = ["1", "5000", "1" & repeat('0', 60), "1" & repeat('0', 70)]
const At = 1_790_000_000'i64
let Dinner = "0x" & repeat("11", 32)
let Hotel = "0x" & repeat("22", 32)
const Base = "100000"     ## the payment-asset share the converted one rides on: above any dust limit

proc decode(k: int): tuple[pay, cov: Asset, rate, share: string] =
  let p = k div 64
  let others = (if p == 0: [1, 2] elif p == 1: [0, 2] else: [0, 1])
  (Pays[p], Pays[others[(k div 32) mod 2]], Rates[(k div 4) mod 8], Shares[k mod 4])

proc correct(k: int): bool =
  let (pay, cov, rate, share) = decode(k)
  # 1. the rate, by the probe's own reading
  let own = decimalUnits(rate, pay.decimals)
  let representable = own.ok and own.v != 0.stuint(512) and own.v <= Max256
  let sr = settleRate(cov.chain, cov.asset, rate, pay.decimals, cov.decimals, "a probe's quote", At)
  if sr.ok != representable: return false
  if not representable: return sr.why.len > 0
  if sr.rate.rate != $own.v or sr.rate.per != $pow10(cov.decimals): return false
  if ratePerUnit(sr.rate, cov.decimals) != $own.v: return false
  # 2. the conversion, against the probe's own floor
  let mine = ownConversion(share, sr.rate.rate, sr.rate.per)
  let converted = Cover(intent: Hotel, debtor: carol, creditor: bob, amount: share,
                        payTo: payToOn("bob", cov.chain), chain: cov.chain, asset: cov.asset)
  let conv = convertedAmount(converted, @[sr.rate], pay.chain, pay.asset)
  if conv.ok != mine.ok: return false
  if not mine.ok:
    if conv.why.len == 0: return false
    if mine.why == "overflows" and "overflow" notin conv.why: return false
    return true
  if conv.amount != $mine.v: return false
  # 3. the driver signs exactly that conversion: one unit more or less is refused
  let base = Cover(intent: Dinner, debtor: carol, creditor: bob, amount: Base,
                   payTo: payToOn("bob", pay.chain), chain: pay.chain, asset: pay.asset)
  let drv = newSplitDriver((if pay.chain == BtcChain: BtcSplitFamily else: EvmSplitFamily), pay.chain, roster)
  proc paying(v: U512): string =
    let t = NetTransfer(frm: carol, to: bob, payTo: base.payTo, amount: $(v + big(Base).v))
    drv.signRefusal(effectFromJson(settleUpEffectJson(pay.chain, pay.asset, @[base, converted], @[t],
                                                      "rate " & $k, @[sr.rate])))
  let honest = paying(mine.v)
  if honest.len > 0:
    stderr.writeLine "case " & $k & ": the honest settle-up refused: " & honest
    return false
  if paying(mine.v + 1.stuint(512)).len == 0: return false
  if paying(mine.v - 1.stuint(512)).len == 0: return false
  true

const N = 192
const PerRow = 4
const Rows = N div PerRow

proc rowOk(row: int): bool =
  result = true
  for k in row * PerRow ..< (row + 1) * PerRow:
    if not correct(k):
      let (pay, cov, rate, share) = decode(k)
      stderr.writeLine "judged wrongly: case " & $k & ": " & share & " " & cov.asset & " on " & cov.chain &
                       " at " & rate & " " & pay.asset & " per unit"
      result = false

proc state(row: int): JsonNode = %*{"row": row, "decision_correct": rowOk(row)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (pay, cov, rate, share) = decode(k)
    doAssert correct(k), "case " & $k & ": " & share & " " & cov.asset & " at " & rate & " " & pay.asset &
                         " — judged wrongly"
let here = oracleStateInt(arg, "row", 0)
emitSuccessors(@[state((here + 1) mod Rows)])
