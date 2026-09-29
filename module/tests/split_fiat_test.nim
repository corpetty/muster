## A bill in fiat, settled in crypto at a recorded quote (exo-3a4; docs/design/split-the-bill.md
## §4.10). "1,840 EUR, paid in ETH": the conversion needs a rate, and a rate is an external
## read — exactly what invariant 10 exists for. Held here:
##   * the quote converts exactly, by string arithmetic: the fiat total in its minor units,
##     the rate in the asset's own base units, the total in the asset = their product,
##     rounded down; anything that cannot be converted exactly is refused, never rounded;
##   * the driver accepts a quoted split only when its total IS the quote's conversion, and
##     the quote — currency, amount, rate, source, time — is in the signed bytes; a split
##     without a quote materializes exactly as before;
##   * the quote reaches the signed bytes as a recorded external read: proposed with its
##     read, every input is accountable and the creditor's agreement counts; proposed
##     without it, nobody's agreement does (invariant 10) — no quote of unknown origin is
##     ever signed;
##   * the words say both: the bill in its currency and what it comes to in the asset.
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils]
import ../src/log/log
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/intents/provenance
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/intent_events
import ../src/coordination/live
import ../src/coordination/attest
import ../src/coordination/authorship
import ../src/coordination/effect_summary
import ./probes/live_room

const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const PayTo = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let drv = newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol])
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)
const At = 1_790_000_000'i64

# ── 1. the quote converts exactly — or not at all ────────────────────────────────
block:
  let q = fiatQuote("EUR", "1840.00", "0.00031", 18, "ECB reference rate, 2026-09-29", At)
  doAssert q.ok, q.why
  doAssert q.quote.currency == "EUR" and q.quote.fiatTotal == "184000" and q.quote.fiatDecimals == "2"
  doAssert q.quote.rateFiat == "100" and q.quote.rateAsset == "310000000000000", "0.00031 ETH per 1 EUR, in wei"
  doAssert q.total == "570400000000000000", "1840.00 EUR × 0.00031 = 0.5704 ETH: " & q.total
  doAssert q.quote.source == "ECB reference rate, 2026-09-29" and q.quote.at == $At
  doAssert fiatQuote("JPY", "1200", "0.0000021", 18, "x", At).quote.fiatTotal == "1200", "yen have no minor unit"
  for (cur, amt, rate) in [("EUR", "1840.001", "0.00031"),          # more decimals than cents
                           ("eur", "1840.00", "0.00031"),           # a currency is three capitals
                           ("EUR", "0", "0.00031"), ("EUR", "12.00", "0"),
                           ("EUR", "12.00", "0.0000000000000000001"),   # finer than a wei
                           ("EUR", "-5", "0.1"), ("EUR", "1e3", "0.1")]:
    let r = fiatQuote(cur, amt, rate, 18, "x", At)
    doAssert not r.ok and r.why.len > 0, cur & " " & amt & " @ " & rate & " should be refused"
  doAssert not fiatQuote("EUR", "10.00", "0.1", 18, "", At).ok, "a quote names its source"
  echo "1. a quote converts exactly: minor units × the rate in base units, or it is refused OK"

# ── 2. the driver: the total IS the quote's conversion, and the quote is signed ──
let q = fiatQuote("EUR", "1840.00", "0.00031", 18, "ECB reference rate, 2026-09-29", At)
let quoted = splitEffectJson(Chain, "ETH", q.total, alice, PayTo, evenShares(q.total, alice, @[bob, carol]),
                             "Dinner", q.quote)
block:
  let e = effectFromJson(quoted)
  doAssert drv.signRefusal(e) == "", drv.signRefusal(e)
  let offByOne = splitEffectJson(Chain, "ETH", "570400000000000001", alice, PayTo,
                                 evenShares("570400000000000001", alice, @[bob, carol]), "Dinner", q.quote)
  doAssert "conversion" in drv.signRefusal(effectFromJson(offByOne)), drv.signRefusal(effectFromJson(offByOne))
  var other = q.quote
  other.source = "a different source"
  let m1 = canonicalize(drv, e).bytes
  let m2 = canonicalize(drv, effectFromJson(splitEffectJson(Chain, "ETH", q.total, alice, PayTo,
                        evenShares(q.total, alice, @[bob, carol]), "Dinner", other))).bytes
  doAssert m1 != m2, "the quote's source is in the signed bytes"
  let plain = splitEffectJson(Chain, "ETH", q.total, alice, PayTo, evenShares(q.total, alice, @[bob, carol]), "Dinner")
  doAssert decode(canonicalize(drv, effectFromJson(plain)).bytes).arr.len == 9, "no quote: the materialization as before"
  doAssert decode(m1).arr.len == 10, "a quote: one element more"
  doAssert parseJson(quoted)["sources"]["quote"].getStr() == "read", "the quote is declared an external read"
  echo "2. the driver checks the total is the quote's conversion; the quote is signed OK"

# ── 3. invariant 10: the quote reaches the signed bytes only as a recorded read ────
block:
  var r = newRoom3("/muster/1/split-fiat/proto")
  proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
  proc viewOf(id: string): IntentView =
    sync()
    for v in reduceIntentViews(r.bob.roomEvents(), splitFor):
      if v.id == id: return v
  # with its read: every input accountable, the creditor agreed by proposing
  let id = liveProposeIntent(r.alice, aliceKs, splitFor, Policy, quoted, int64(Now), 1,
                             account = Chain & ":" & PayTo, ttlSec = Ttl,
                             reads = @[(field: "quote", source: "quote:proposer")])
  doAssert id.startsWith("0x"), id
  sync()
  let inputs = intentInputs(r.bob.roomEvents(), splitFor, id)
  doAssert inputs.allAccountable, "every input accounted for"
  var sawRead = false
  for i in inputs:
    if i.class == icExternalRead: sawRead = true
  doAssert sawRead, "the quote is cited as an external read"
  doAssert viewOf(id).approvals == 1, "Alice agreed by proposing"
  doAssert liveContribute(r.bob, bobKs, splitFor, id, "", "", bindCtx(), Now) == "collecting"
  # without its read: the quote's origin is unaccountable, so nobody's agreement counts
  let lunch = splitEffectJson(Chain, "ETH", q.total, alice, PayTo, evenShares(q.total, alice, @[bob, carol]),
                              "Lunch", q.quote)
  let id2 = liveProposeIntent(r.alice, aliceKs, splitFor, Policy, lunch, int64(Now), 2,
                              account = Chain & ":" & PayTo, ttlSec = Ttl)
  doAssert id2.startsWith("0x"), id2
  doAssert viewOf(id2).approvals == 0, "the creditor's agreement is refused: the quote came from nowhere"
  doAssert liveContribute(r.bob, bobKs, splitFor, id2, "", "", bindCtx(), Now) == "unaccountable-input"
  echo "3. a quote is signed only as a recorded read; without it, no agreement counts OK"

# ── 4. the words: the bill in its currency, and what it comes to ──────────────────
block:
  let sm = effectSummary(quoted)
  doAssert "1840.00 EUR" in sm.text and "0.5704 ETH" in sm.text, sm.text
  echo "4. the words say 1840.00 EUR and 0.5704 ETH OK"

echo "split_fiat_test: all OK"
