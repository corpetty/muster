## derived-exo-a90.20 s2: a bill in another currency is converted exactly — the total is the
## fiat amount in minor units times the rate in the asset's base units (per one unit of the
## currency), rounded down, and anything not exactly convertible is refused; the quote
## (currency, amount, rate, source, time) is in the signed bytes and reaches them only as a
## recorded external read: without that read no agreement counts (invariant 10; exo-3a4).
##
## STEPPER: state = one case of a grid — currency {JPY: 0 minor places, EUR: 2, KWD: 3} x
## amount {1840.00, 12.345, 0.5, 0, 1e3} x asset {a 6-decimal token, BTC at 8, LEZ at 9 — the
## private split, ETH at 18} x rate {0.00031, 1.08, 2, 0.0000000000000000001 — finer than any
## base unit here, 0}: 300 cases. A grader state is one row — a currency, amount and asset
## with all five rates (a failing case is named on stderr) — chained row -> row+1, 60 rows. The probe does its OWN exact arithmetic (its own decimal
## parse into integers, never the module's): minor = amount x 10^places, base = rate x
## 10^decimals, total = minor x base div 10^places; refused iff either is not a plain
## decimal within its places, either is zero, or the total is zero. Then, for each quote
## that converts: fiatQuote returns exactly that total; the driver accepts a split of it
## and refuses total + 1 and total - 1 (BTC also refuses a share below the 546-sat dust
## limit); another source, or another time, gives other signed bytes; and — for every
## asset but BTC, in a room over the live path — Bob's agreement counts when the proposal recorded
## the quote as an external read, and is refused "unaccountable-input" when it did not. Run
## by hand (no argv), it checks all 300 with doAssert.

import std/[json, strutils]
import stint
import ../../src/dcbor/dcbor
import ../../src/intents/materialization
import ../../src/bitcoin/[script, keys]
import ./split_room
import ./oracle_emit

const Currencies = [("JPY", 0), ("EUR", 2), ("KWD", 3)]
const Amounts = ["1840.00", "12.345", "0.5", "0", "1e3"]
const Assets = [("erc20:0x5fbdb2315678afecb367f032d93f642f64180aa3", 6), ("BTC", 8), ("LEZ", 9), ("ETH", 18)]
const Rates = ["0.00031", "1.08", "2", "0.0000000000000000001", "0"]
const N = 300
const At = 1_790_000_000'i64
const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const LezPayTo = "priv:" & "ab".repeat(32) & ":" & "cd".repeat(33)

proc decode(k: int): tuple[cur: string, places: int, amount, asset: string, decimals: int, rate: string] =
  let c = Currencies[k div 100]
  let a = Assets[(k mod 20) div 5]
  (c[0], c[1], Amounts[(k mod 100) div 20], a[0], a[1], Rates[k mod 5])

proc scaled(s: string, places: int): tuple[ok: bool, v: UInt256] =
  ## The probe's own reading: a plain decimal (digits, at most one point) with at most
  ## `places` fraction digits, times 10^places — or not ok.
  let parts = s.split('.')
  if s.len == 0 or parts.len > 2: return (false, 0.u256)
  for p in parts:
    if p.len == 0: return (false, 0.u256)
    for ch in p:
      if ch notin '0' .. '9': return (false, 0.u256)
  let frac = (if parts.len == 2: parts[1] else: "")
  if frac.len > places: return (false, 0.u256)
  var v = 0.u256
  for ch in parts[0] & frac & repeat('0', places - frac.len): v = v * 10.u256 + u256(ord(ch) - ord('0'))
  (true, v)

proc filled(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

proc correct(k: int): bool =
  let (cur, places, amount, asset, decimals, rate) = decode(k)
  # the rule, by the probe's own arithmetic
  let m = scaled(amount, places)
  let b = scaled(rate, decimals)
  var tenP = 1.u256
  for _ in 0 ..< places: tenP = tenP * 10.u256
  let converts = m.ok and b.ok and m.v != 0.u256 and b.v != 0.u256 and (m.v * b.v) div tenP != 0.u256
  let q = fiatQuote(cur, amount, rate, decimals, "a probe's rate", At)
  if q.ok != converts: return false
  if not converts: return q.why.len > 0
  let total = $((m.v * b.v) div tenP)
  if q.total != total: return false
  # the driver: the total IS the conversion
  let btc = asset == "BTC"
  let lez = asset == "LEZ"
  let chain = (if btc: Regtest elif lez: LezChain else: EvmChain)
  let drv = (if btc: newSplitDriver(BtcSplitFamily, Regtest, roster)
             elif lez: newSplitDriver(LezSplitFamily, LezChain, roster)
             else: newSplitDriver(EvmSplitFamily, EvmChain, roster))
  let payTo = (if btc: p2wpkhAddress("bcrt", compressedPubKey(filled(7))) elif lez: LezPayTo else: AlicePayTo)
  proc splitOf(t: string, src = "a probe's rate", at = At): string =
    var qq = q.quote
    qq.source = src
    qq.at = $at
    splitEffectJson(chain, asset, t, alice, payTo, evenShares(t, alice, @[bob, carol], distinctAmounts = lez),
                    "fiat " & $k, qq)
  let refusal = drv.signRefusal(effectFromJson(splitOf(total)))
  let dust = btc and u256(total) div 3.u256 < 546.u256
  if dust: (if "dust" notin refusal: return false)
  elif refusal.len > 0: return false
  if drv.signRefusal(effectFromJson(splitOf($(u256(total) + 1.u256)))).len == 0: return false
  if total != "1" and drv.signRefusal(effectFromJson(splitOf($(u256(total) - 1.u256)))).len == 0: return false
  if not dust:
    let base = canonicalize(drv, effectFromJson(splitOf(total))).bytes
    if canonicalize(drv, effectFromJson(splitOf(total, src = "another source"))).bytes == base: return false
    if canonicalize(drv, effectFromJson(splitOf(total, at = At + 1))).bytes == base: return false
    if decode(base).arr.len != 10: return false
  # invariant 10, over the live path: the quote counts only as a recorded read (all but BTC)
  if not btc and not dust:
    var r = newRoom4("/muster/1/probe-fiat-" & $k & "/proto")
    let policy = (if lez: LezPolicy else: EvmPolicy)
    let account = (if lez: LezChain else: EvmChain & ":" & AlicePayTo)
    inc r.seqNo
    let withRead = liveProposeIntent(r.alice, aliceKs, splitFor, policy, splitOf(total), int64(Now), r.seqNo,
                                     account = account, ttlSec = Ttl,
                                     reads = @[(field: "quote", source: "quote:proposer")])
    if not withRead.startsWith("0x"): return false
    r.sync()
    if r.agree("bob", withRead) notin ["collecting", "executable"]: return false
    inc r.seqNo
    let without = liveProposeIntent(r.alice, aliceKs, splitFor, policy, splitOf(total, src = "unrecorded"),
                                    int64(Now), r.seqNo, account = account, ttlSec = Ttl)
    if not without.startsWith("0x"): return false
    r.sync()
    if r.agree("bob", without) != "unaccountable-input": return false
  true

const Rows = N div Rates.len

proc rowOk(row: int): bool =
  result = true
  for k in row * Rates.len ..< (row + 1) * Rates.len:
    if not correct(k):
      let (cur, _, amount, asset, _, rate) = decode(k)
      stderr.writeLine "judged wrongly: case " & $k & ": " & amount & " " & cur & " at " & rate & " " & asset
      result = false

proc state(row: int): JsonNode = %*{"row": row, "decision_correct": rowOk(row)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (cur, places, amount, asset, decimals, rate) = decode(k)
    doAssert correct(k), "case " & $k & ": " & amount & " " & cur & " at " & rate & " " & asset &
                         " — judged wrongly"
let here = oracleStateInt(arg, "row", 0)
emitSuccessors(@[state((here + 1) mod Rows)])
