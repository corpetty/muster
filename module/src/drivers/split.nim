## A split: the room agrees who owes what, and each person pays their own share
## (exo-a90.3; docs/design/split-the-bill.md). The first family with NO shared account —
## the "each" locus: one member fronted a bill, the effect names every debtor and their
## share, and the address to pay; nothing on a chain counts or enforces any of it.
##
## Behind the one Driver seam:
##   * the EFFECT has one spelling (§4.1): canonical decimal amounts in the asset's
##     smallest unit (dCBOR has no bignum, and wei outgrows uint64), shares sorted by the
##     debtor's room identity with none repeated, the creditor never a debtor, the shares
##     never more than the total (the creditor's own share is the rest), the chain the
##     policy's. Anything else is refused with its reason and canonicalizes to a sentinel
##     no signature can name (invariants 1, 5);
##   * the THRESHOLD is everyone the effect names — each debtor and the creditor
##     (describeFor, §4.2; the creditor since exo-770, whose agreement is their word that
##     payTo is theirs, made at propose when they propose it) — and an agreement is that
##     party's Ed25519 room-key signature over the materialization — the signer set is
##     decoded from the materialization itself, never the room roster, so a member the
##     split does not name can never agree and a later joiner never moves it;
##   * each debtor is a PART (§4.3): settled by that debtor, confirmed by the creditor, and
##     the transfer that settles it is derived here from the reviewed effect (invariant 1);
##   * the PROFILE is the each locus; the manifest says what each rail discloses (§6).
## One driver, three families, as btc_multisig.nim: evm.split; lez.split — the private
## split (exo-a90.9): a shielded payTo, the private rail, and every share a distinct amount
## so the creditor's scan can attribute each note without the chain naming its payer; and
## btc.split (exo-d17): BTC in satoshis, each share its payer's own single-key spend to a
## payTo of the chain's network, confirmed on the creditor's own node, no share below dust.

import std/[json, strutils, sequtils, algorithm, tables]
import stint
import ../dcbor/dcbor
import ../crypto/curve25519
import ../intents/materialization
import ./driver
import ./manifest
import ./profile
import ../bitcoin/[network, bech32]

const
  EvmSplitFamily* = "evm.split"
  LezSplitFamily* = "lez.split"
  BtcSplitFamily* = "btc.split"   ## paid in BTC on a Bitcoin chain, each share its payer's own spend (exo-d17)
  BtcDust* = 546'u64              ## a Bitcoin output below this is non-standard: no share may be smaller
  SplitDomain* = "muster.split.v1"
  SplitSchema* = "muster.effect.split.v1"
  MaxMemo* = 280            ## bytes of room-only text
  MaxQuoteSource* = 140     ## bytes naming where a fiat quote came from

type
  SplitShare* = object
    who*: string            ## the debtor's room identity: 64-byte encryption identity, lowercase hex
    amount*: string         ## canonical decimal, the asset's smallest unit

  SplitQuote* = object
    ## A bill in fiat, settled in the split's asset at a recorded quote (exo-3a4, §4.10):
    ## an external read (invariant 10), in the signed bytes. All canonical decimal text.
    currency*: string       ## ISO 4217, three capitals ("EUR")
    fiatTotal*: string      ## the bill in the currency's minor units ("184000" = 1840.00 EUR)
    fiatDecimals*: string   ## the currency's minor-unit digits ("2")
    rateFiat*: string       ## the rate: rateAsset of the asset's base units per rateFiat
    rateAsset*: string      ##   minor fiat units (rateFiat = 10^fiatDecimals: per ONE major unit)
    source*: string         ## where the quote came from, as the proposer names it
    at*: string             ## when it was read, unix seconds

  Split* = object
    chain*, asset*, total*, creditor*, payTo*, memo*: string
    shares*: seq[SplitShare]
    quote*: SplitQuote      ## empty (currency "") = a bill in the asset itself

  SplitDriver* = ref object of Driver
    family*: string         ## evm.split | lez.split | btc.split
    chain*: string          ## the CAIP-2 chain this instance settles on (the policy's qualifier)
    roster*: seq[string]    ## the room's members (room identities) — the propose/sign gate only, never the fold
    pending: seq[byte]      ## the materialization contributions currently verify against

proc newSplitDriver*(family, chain: string, roster: seq[string] = @[]): SplitDriver =
  SplitDriver(family: family, chain: chain, roster: roster.mapIt(it.toLowerAscii()))

# ── helpers ────────────────────────────────────────────────────────────────────
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc isLowerHex(s: string): bool =
  s.len > 0 and s.allIt(it in {'0'..'9', 'a'..'f'})

proc isRoomIdentity*(s: string): bool = s.len == 128 and isLowerHex(s)

proc quoted*(q: SplitQuote): bool = q.currency.len > 0

proc isCanonDec*(s: string): bool =
  ## Digits only, no sign, no leading zero, and it fits 256 bits: the ONE spelling of a
  ## non-negative integer (invariant 5 — "030" is refused, never normalized).
  if s.len == 0 or s.len > 78 or not s.allIt(it in {'0'..'9'}): return false
  if s.len > 1 and s[0] == '0': return false
  try: $u256(s) == s
  except CatchableError: false

# ── a bill in fiat (exo-3a4): the conversion, by string arithmetic, never a float ──────
proc minorUnits*(currency: string): int =
  ## ISO 4217 minor-unit digits: none for yen and the like, three for the dinars, two
  ## for everything else.
  case currency
  of "JPY", "KRW", "VND", "CLP", "ISK", "UGX", "PYG", "RWF", "XAF", "XOF", "KMF", "GNF", "VUV", "XPF", "DJF": 0
  of "BHD", "KWD", "OMR", "JOD", "TND", "LYD", "IQD": 3
  else: 2

proc pow10(n: int): string = "1" & repeat('0', n)

proc toUnits*(amount: string, decimals: int): tuple[ok: bool, units, why: string] =
  ## "1840.00" at 2 decimals -> "184000": digits and at most one point, no more fraction
  ## digits than `decimals`, exact. A sign, an exponent or a finer fraction is refused.
  let s = amount.strip()
  let parts = s.split('.')
  if s.len == 0 or parts.len > 2 or parts[0].len == 0 or not parts[0].allIt(it in {'0'..'9'}) or
     (parts.len == 2 and (parts[1].len == 0 or not parts[1].allIt(it in {'0'..'9'}))):
    return (false, "", "not a plain decimal amount: " & amount)
  let frac = (if parts.len == 2: parts[1] else: "")
  if frac.len > decimals:
    return (false, "", amount & " has more decimals than " & $decimals)
  var u = (parts[0] & frac & repeat('0', decimals - frac.len)).strip(leading = true, trailing = false, chars = {'0'})
  if u.len == 0: u = "0"
  if not isCanonDec(u): return (false, "", "too large: " & amount)
  (true, u, "")

proc quoteConversion*(q: SplitQuote): tuple[ok: bool, total, why: string] =
  ## The total in the asset's base units: fiatTotal × rateAsset ÷ rateFiat, rounded down —
  ## overflow refused, never wrapped.
  if not (isCanonDec(q.fiatTotal) and isCanonDec(q.rateAsset) and isCanonDec(q.rateFiat)) or q.rateFiat == "0":
    return (false, "", "the quote's amounts are not canonical decimals")
  let a = u256(q.fiatTotal)
  let r = u256(q.rateAsset)
  let p = a * r
  if a != 0.u256 and p div a != r: return (false, "", "the conversion overflows")
  (true, $(p div u256(q.rateFiat)), "")

proc fiatQuote*(currency, fiatAmount, rate: string, assetDecimals: int, source: string,
                at: int64): tuple[ok: bool, quote: SplitQuote, total, why: string] =
  ## A quote for a bill of `fiatAmount` `currency`, at `rate` of the asset per ONE unit of
  ## the currency (in the asset's own decimals: "0.00031" ETH), read from `source` at `at`.
  if currency.len != 3 or not currency.allIt(it in {'A'..'Z'}):
    return (false, SplitQuote(), "", "a currency is its ISO 4217 code, three capitals: " & currency)
  if source.strip().len == 0 or source.len > MaxQuoteSource:
    return (false, SplitQuote(), "", "a quote names its source, in at most " & $MaxQuoteSource & " bytes")
  let fd = minorUnits(currency)
  let f = toUnits(fiatAmount, fd)
  if not f.ok: return (false, SplitQuote(), "", f.why)
  if f.units == "0": return (false, SplitQuote(), "", "the bill must be more than zero")
  let r = toUnits(rate, assetDecimals)
  if not r.ok: return (false, SplitQuote(), "", "the rate: " & r.why)
  if r.units == "0": return (false, SplitQuote(), "", "the rate must be more than zero (in the asset's smallest unit)")
  let q = SplitQuote(currency: currency, fiatTotal: f.units, fiatDecimals: $fd, rateFiat: pow10(fd),
                     rateAsset: r.units, source: source.strip(), at: $max(0'i64, at))
  let c = quoteConversion(q)
  if not c.ok: return (false, SplitQuote(), "", c.why)
  if c.total == "0": return (false, SplitQuote(), "", "the bill comes to nothing in the asset at that rate")
  (true, q, c.total, "")

proc edOf(identity: string): Ed25519Pub =
  var b: seq[byte]
  for i in 0 ..< identity.len div 2: b.add byte(parseHexInt(identity[2*i .. 2*i+1]))
  encIdentityFromBytes(b).ed

proc partName*(identity: string): string =
  ## How the driver names a debtor as a contributor and a part — the Ed25519 half of the
  ## room identity, "ed:<hex>" (the convention every room-key driver and the attestation
  ## layer already use).
  "ed:" & hx(edOf(identity))

proc isErc20Asset*(a: string): bool =
  ## A token an Ethereum split may be paid in, in its one spelling: "erc20:" + a lowercase
  ## 0x address, never the zero address (exo-5ab).
  if not a.startsWith("erc20:0x") or a.len != 48: return false
  let h = a[8 .. ^1]
  h.allCharsInSet({'0' .. '9', 'a' .. 'f'}) and h != repeat('0', 40)

proc payToOk(family, chain, payTo: string): bool =
  case family
  of EvmSplitFamily: payTo.len == 42 and payTo.startsWith("0x") and isLowerHex(payTo[2 .. ^1])
  of BtcSplitFamily:
    # a segwit address of THIS chain's network, in its one (lowercase) spelling
    try:
      let net = networkByCaip2(chain)
      payTo == payTo.toLowerAscii() and decodeSegwitAddress(net.hrp, payTo).program.len > 0
    except CatchableError: false
  of LezSplitFamily:
    # a shielded key node: the private split pays only a shielded address (§4.6)
    let p = payTo.split(':')
    p.len == 3 and p[0] == "priv" and isLowerHex(p[1]) and isLowerHex(p[2])
  else: false

# ── the effect ─────────────────────────────────────────────────────────────────
proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

proc textOf(e: Effect, name: string): string =
  let v = e.fieldOf(name)
  if v.kind == ckText: v.t else: ""

proc splitOf*(e: Effect): Split =
  ## The split an effect carries, as carried — validation is `refusal`'s.
  if e.schemaId != SplitSchema: raise newException(ValueError, "not a split")
  result = Split(chain: e.textOf("chain"), asset: e.textOf("asset"), total: e.textOf("total"),
                 creditor: e.textOf("creditor"), payTo: e.textOf("payTo"), memo: e.textOf("memo"))
  let qv = e.fieldOf("quote")
  if qv.kind == ckMap:
    for (k, v) in qv.pairs:
      if k.kind != ckText or v.kind != ckText: raise newException(ValueError, "a quote is text fields")
      case k.t
      of "currency": result.quote.currency = v.t
      of "fiatTotal": result.quote.fiatTotal = v.t
      of "fiatDecimals": result.quote.fiatDecimals = v.t
      of "rateFiat": result.quote.rateFiat = v.t
      of "rateAsset": result.quote.rateAsset = v.t
      of "source": result.quote.source = v.t
      of "at": result.quote.at = v.t
      else: raise newException(ValueError, "a quote has no field " & k.t)
    if not result.quote.quoted: raise newException(ValueError, "a quote names its currency")
  let sh = e.fieldOf("shares")
  if sh.kind == ckArray:
    for x in sh.arr:
      if x.kind != ckArray or x.arr.len != 2 or x.arr[0].kind != ckText or x.arr[1].kind != ckText:
        raise newException(ValueError, "a share is [who, amount]")
      result.shares.add SplitShare(who: x.arr[0].t, amount: x.arr[1].t)

proc refusal(d: SplitDriver, sp: Split): string =
  ## Why `sp` is not a split this driver will propose, sign or pay ("" = it is one).
  if sp.chain != d.chain:
    return "this split settles on " & (if sp.chain.len > 0: sp.chain else: "no chain") &
           "; its policy settles on " & d.chain
  if d.family == EvmSplitFamily and sp.asset != "ETH" and not isErc20Asset(sp.asset):
    return "an Ethereum split is paid in ETH or in a token named erc20:<0x address, lowercase> (asked: " &
           sp.asset & ")"
  if d.family == LezSplitFamily and sp.asset != "LEZ":
    return "only LEZ is split privately on " & d.chain & " so far (asked: " & sp.asset & ")"
  if d.family == BtcSplitFamily and sp.asset != "BTC":
    return "a Bitcoin split is paid in BTC, in satoshis (asked: " & sp.asset & ")"
  if not isCanonDec(sp.total): return "the total is not a canonical decimal: " & sp.total
  if sp.total == "0": return "the total must be more than zero"
  if not isRoomIdentity(sp.creditor): return "the creditor is not a room identity (64 bytes, lowercase hex)"
  if not payToOk(d.family, d.chain, sp.payTo): return "payTo is not a " & d.family & " address in its one spelling: " & sp.payTo
  if sp.memo.len > MaxMemo: return "the memo is longer than " & $MaxMemo & " bytes"
  if sp.quote.quoted:
    # a bill in fiat (exo-3a4): the total must BE the quote's conversion — derived, never trusted
    let q = sp.quote
    if q.currency.len != 3 or not q.currency.allIt(it in {'A'..'Z'}): return "a quote's currency is three capitals"
    if q.fiatDecimals notin ["0", "1", "2", "3", "4"] or q.rateFiat != pow10(parseInt(q.fiatDecimals)):
      return "a quote's rate is per one unit of its currency"
    if not isCanonDec(q.at): return "a quote says when it was read, in unix seconds"
    if q.source.len == 0 or q.source.len > MaxQuoteSource: return "a quote names its source, in at most " & $MaxQuoteSource & " bytes"
    let c = quoteConversion(q)
    if not c.ok: return "the quote: " & c.why
    if c.total != sp.total:
      return "the total " & sp.total & " is not the quote's conversion (" & q.fiatTotal & " minor units of " &
             q.currency & " at " & q.rateAsset & " per " & q.rateFiat & " = " & c.total & ")"
  if sp.shares.len == 0: return "no one owes anything"
  var sum = 0.u256
  for i, s in sp.shares:
    if not isRoomIdentity(s.who): return "a debtor is not a room identity (64 bytes, lowercase hex)"
    if s.who == sp.creditor: return "the creditor cannot also owe the creditor"
    if i > 0 and s.who <= sp.shares[i-1].who: return "shares must be sorted by who, each debtor once"
    if not isCanonDec(s.amount): return "a share is not a canonical decimal: " & s.amount
    if s.amount == "0": return "every share must be more than zero"
    if d.family == BtcSplitFamily and u256(s.amount) < u256(BtcDust):
      return "a share of " & s.amount & " sat is below Bitcoin's dust limit (" & $BtcDust &
             " sat): it could never be paid"
    let before = sum
    sum = sum + u256(s.amount)
    if sum < before: return "the shares overflow"
  if sum > u256(sp.total): return "the shares add up to more than the total"
  if d.family == LezSplitFamily:
    # the chain names no payer on the private rail, so the AMOUNT is what lets the
    # creditor's scan tell whose note arrived (§4.7): no two shares may be equal
    var seen: seq[string]
    for s in sp.shares:
      if s.amount in seen:
        return "every share of a private split must differ, so the creditor can tell whose payment arrived " &
               "without the chain naming anyone (" & s.amount & " twice)"
      seen.add s.amount
  ""

proc validSplit(d: SplitDriver, e: Effect): tuple[ok: bool, split: Split, why: string] =
  try:
    let sp = splitOf(e)
    let why = d.refusal(sp)
    (why.len == 0, sp, why)
  except ValueError as err:
    (false, Split(), err.msg)

# ── settle up (exo-3c6, §4.11): net several splits into fewer payments ─────────────
const
  SettleUpDomain* = "muster.settle-up.v1"
  SettleUpSchema* = "muster.effect.settle-up.v1"

type
  Cover* = object
    ## One agreed, unpaid part of a split that a settle-up settles: as that split says it.
    intent*, debtor*, creditor*, amount*, payTo*: string
  NetTransfer* = object
    ## One net payment a settle-up makes instead: `frm` pays `to` at `to`'s agreed address.
    frm*, to*, payTo*, amount*: string
  SettleUp* = object
    chain*, asset*, memo*: string
    covers*: seq[Cover]
    transfers*: seq[NetTransfer]

proc settleUpOf*(e: Effect): SettleUp =
  ## The settle-up an effect carries, as carried — validation is settleRefusal's.
  if e.schemaId != SettleUpSchema: raise newException(ValueError, "not a settle-up")
  result = SettleUp(chain: e.textOf("chain"), asset: e.textOf("asset"), memo: e.textOf("memo"))
  let cv = e.fieldOf("covers")
  if cv.kind == ckArray:
    for x in cv.arr:
      if x.kind != ckArray or x.arr.len != 5 or not x.arr.allIt(it.kind == ckText):
        raise newException(ValueError, "a cover is [intent, debtor, creditor, amount, payTo]")
      result.covers.add Cover(intent: x.arr[0].t, debtor: x.arr[1].t, creditor: x.arr[2].t,
                              amount: x.arr[3].t, payTo: x.arr[4].t)
  let tv = e.fieldOf("transfers")
  if tv.kind == ckArray:
    for x in tv.arr:
      if x.kind != ckArray or x.arr.len != 4 or not x.arr.allIt(it.kind == ckText):
        raise newException(ValueError, "a transfer is [from, to, payTo, amount]")
      result.transfers.add NetTransfer(frm: x.arr[0].t, to: x.arr[1].t, payTo: x.arr[2].t, amount: x.arr[3].t)

proc settleParties*(su: SettleUp): seq[string] =
  ## Everyone the covered parts name — each debtor and each creditor — sorted, once each.
  for c in su.covers:
    for w in [c.debtor, c.creditor]:
      if w notin result: result.add w
  result.sort()

proc settleRefusal(d: SplitDriver, su: SettleUp): string =
  ## Why `su` is not a settle-up this driver will sign or pay ("" = it is one).
  if d.family == LezSplitFamily:
    return "the private split is never netted: its shares are told apart by amount, which netting would erase"
  if su.chain != d.chain: return "this settle-up settles on " & su.chain & "; its policy settles on " & d.chain
  if d.family == EvmSplitFamily and su.asset != "ETH" and not isErc20Asset(su.asset):
    return "an Ethereum settle-up is in ETH or an erc20:<0x token> (asked: " & su.asset & ")"
  if d.family == BtcSplitFamily and su.asset != "BTC": return "a Bitcoin settle-up is in BTC"
  if su.memo.len > MaxMemo: return "the memo is longer than " & $MaxMemo & " bytes"
  if su.covers.len < 2: return "a settle-up nets at least two parts"
  var balance = initTable[string, UInt256]()     # owed to them
  var owes = initTable[string, UInt256]()        # they owe
  for i, c in su.covers:
    if not (c.intent.startsWith("0x") and isLowerHex(c.intent[2 .. ^1])): return "a covered intent id is 0x + lowercase hex"
    if not isRoomIdentity(c.debtor) or not isRoomIdentity(c.creditor): return "a cover names room identities"
    if c.debtor == c.creditor: return "a cover's debtor is never its creditor"
    if not isCanonDec(c.amount) or c.amount == "0": return "a covered amount is a canonical decimal above zero"
    if not payToOk(d.family, d.chain, c.payTo): return "a cover's payTo is not a " & d.family & " address: " & c.payTo
    if i > 0 and (c.intent, c.debtor) <= (su.covers[i-1].intent, su.covers[i-1].debtor):
      return "covers are sorted by intent then debtor, each part once"
    balance[c.creditor] = balance.getOrDefault(c.creditor) + u256(c.amount)
    owes[c.debtor] = owes.getOrDefault(c.debtor) + u256(c.amount)
  var paid = initTable[string, UInt256]()
  var got = initTable[string, UInt256]()
  let parties = settleParties(su)
  for i, t in su.transfers:
    if t.frm notin parties or t.to notin parties: return "a transfer names someone the covered parts do not"
    if t.frm == t.to: return "a transfer pays someone else"
    if not isCanonDec(t.amount) or t.amount == "0": return "a transfer amount is a canonical decimal above zero"
    if i > 0 and (t.frm, t.to) <= (su.transfers[i-1].frm, su.transfers[i-1].to):
      return "transfers are sorted by from then to, each pair once"
    # a recipient is paid only where one of the splits owing them agreed
    if not su.covers.anyIt(it.creditor == t.to and it.payTo == t.payTo):
      return "a transfer pays " & t.payTo & ", not an address a split owing its recipient agreed"
    paid[t.frm] = paid.getOrDefault(t.frm) + u256(t.amount)
    got[t.to] = got.getOrDefault(t.to) + u256(t.amount)
  # conservation: each member's net across the transfers is their net across the covers
  for w in parties:
    let owedIn = balance.getOrDefault(w) + paid.getOrDefault(w)
    let owedOut = owes.getOrDefault(w) + got.getOrDefault(w)
    if owedIn != owedOut:
      return "the transfers do not conserve the balance of " & w[0 ..< 12] & "…: what they are owed less " &
             "what they owe must equal what they receive less what they pay"
  ""

proc validSettle(d: SplitDriver, e: Effect): tuple[ok: bool, su: SettleUp, why: string] =
  try:
    let su = settleUpOf(e)
    let why = d.settleRefusal(su)
    (why.len == 0, su, why)
  except ValueError as err:
    (false, SettleUp(), err.msg)

proc isSettleUp*(e: Effect): bool = e.schemaId == SettleUpSchema

proc debtorsOf(mat: seq[byte]): seq[string] =
  ## The debtors a materialization names — decoded from the bytes this driver produced.
  ## A sentinel (a malformed split) names none, so nothing can agree to it.
  try:
    let v = decode(mat)
    if v.kind != ckArray or v.arr.len notin [9, 10] or v.arr[0].kind != ckText or v.arr[0].t != SplitDomain: return
    if v.arr[7].kind != ckArray: return
    for s in v.arr[7].arr:
      if s.kind == ckArray and s.arr.len == 2 and s.arr[0].kind == ckText: result.add s.arr[0].t
  except CatchableError: discard

proc creditorOf(mat: seq[byte]): string =
  ## The creditor a materialization names ("" when it is not a split's).
  try:
    let v = decode(mat)
    if v.kind == ckArray and v.arr.len in [9, 10] and v.arr[0].kind == ckText and v.arr[0].t == SplitDomain and
       v.arr[5].kind == ckText: return v.arr[5].t
  except CatchableError: discard

proc settlePartiesOf(mat: seq[byte]): seq[string] =
  ## The parties a settle-up materialization names (every covered debtor and creditor),
  ## decoded from the bytes this driver produced; none for anything else.
  try:
    let v = decode(mat)
    if v.kind != ckArray or v.arr.len != 7 or v.arr[0].kind != ckText or v.arr[0].t != SettleUpDomain: return
    if v.arr[4].kind != ckArray: return
    for c in v.arr[4].arr:
      if c.kind == ckArray and c.arr.len == 5:
        for i in [1, 2]:
          if c.arr[i].kind == ckText and c.arr[i].t notin result: result.add c.arr[i].t
  except CatchableError: discard

proc settlePart*(t: NetTransfer): string =
  ## A net transfer's part name: its payer and its recipient ("ed:<from>>ed:<to>") — a
  ## payer who owes two people settles two parts.
  partName(t.frm) & ">" & partName(t.to)

# ── the Driver seam ────────────────────────────────────────────────────────────
method describe*(d: SplitDriver): DriverDescriptor =
  ## The family's one policy: a split needs at least one debtor. What a PROPOSAL needs is
  ## describeFor — every debtor it names.
  DriverDescriptor(rounds: 1, serializationDomain: SplitDomain, finality: finExternal, threshold: 1)

method describeFor*(d: SplitDriver, e: Effect): DriverDescriptor =
  ## Every debtor the split names, AND its creditor (exo-770): a split's content is anyone's
  ## to write, so without the creditor's own agreement anyone could publish "Alice paid —
  ## pay 0x<mine>". The creditor agrees at propose when they propose it themselves.
  result = d.describe()
  if e.isSettleUp:
    # a settle-up: everyone the covered parts name — each debtor and each creditor
    let (ok, su, _) = d.validSettle(e)
    if ok: result.threshold = settleParties(su).len
    return
  let (ok, sp, _) = d.validSplit(e)
  if ok: result.threshold = sp.shares.len + 1

method agreesByProposing*(d: SplitDriver, e: Effect, proposer: string): bool =
  ## The creditor proposing their own split agrees to it then — payTo is theirs to state. A
  ## party proposing a settle-up agrees to it then: they composed it.
  let who = proposer.toLowerAscii().replace("0x", "")
  if e.isSettleUp:
    let (ok, su, _) = d.validSettle(e)
    return ok and who in settleParties(su)
  let (ok, sp, _) = d.validSplit(e)
  ok and who == sp.creditor

method environment*(d: SplitDriver): string = d.chain

method mayContribute*(d: SplitDriver, e: Effect, names: seq[string]): Eligibility =
  ## A party the split names: a debtor, or the creditor (exo-770); for a settle-up, anyone
  ## its covered parts name. A malformed effect names no one: nobody's agreement could count.
  let mine = bareNames(names)
  if e.isSettleUp:
    let (sok, su, _) = d.validSettle(e)
    if not sok: return elNo
    for who in settleParties(su):
      if partName(who)[3 .. ^1] in mine: return elYes
    return elNo
  let (ok, sp, _) = d.validSplit(e)
  if not ok: return elNo
  for who in sp.shares.mapIt(it.who) & @[sp.creditor]:
    if partName(who)[3 .. ^1] in mine: return elYes
  elNo

proc creditorAgreeRefusal*(e: Effect, me: string, held: seq[string]): string =
  ## Before THIS member agrees to a split: "" unless they are its creditor and payTo is not an
  ## address their client holds (`held`, compared case-blind) — then "payto-not-mine". The
  ## creditor's agreement is their word that payTo is theirs (exo-770); their client does
  ## not give it for an address it cannot account for. Not a split: not this check.
  try:
    let sp = splitOf(e)
    if sp.creditor != me.toLowerAscii().replace("0x", ""): return ""
    for h in held:
      if h.toLowerAscii() == sp.payTo.toLowerAscii(): return ""
    "payto-not-mine"
  except ValueError: ""

method canonicalize*(d: SplitDriver, e: Effect): Materialization =
  ## dCBOR [domain, schema, chain, asset, total, creditor, payTo, [[who, amount]…], memo(, quote)],
  ## the chain the driver's (the effect must name the same one). A malformed split is a
  ## sentinel no agreement can name.
  if e.isSettleUp:
    # dCBOR [domain, schema, chain, asset, [[intent, debtor, creditor, amount, payTo]…],
    #        [[from, to, payTo, amount]…], memo] — its own domain, never mistaken for a split
    let (sok, su, swhy) = d.validSettle(e)
    if not sok:
      return Materialization(bytes: encode(cbArray(@[cbText(SettleUpDomain), cbText("invalid: " & swhy)])))
    return Materialization(bytes: encode(cbArray(@[
      cbText(SettleUpDomain), cbText(SettleUpSchema), cbText(d.chain), cbText(su.asset),
      cbArray(su.covers.mapIt(cbArray(@[cbText(it.intent), cbText(it.debtor), cbText(it.creditor),
                                        cbText(it.amount), cbText(it.payTo)]))),
      cbArray(su.transfers.mapIt(cbArray(@[cbText(it.frm), cbText(it.to), cbText(it.payTo), cbText(it.amount)]))),
      cbText(su.memo)])))
  let (ok, sp, why) = d.validSplit(e)
  if not ok:
    return Materialization(bytes: encode(cbArray(@[cbText(SplitDomain), cbText("invalid: " & why)])))
  Materialization(bytes: encode(cbArray(@[
    cbText(SplitDomain), cbText(SplitSchema), cbText(d.chain), cbText(sp.asset), cbText(sp.total),
    cbText(sp.creditor), cbText(sp.payTo),
    cbArray(sp.shares.mapIt(cbArray(@[cbText(it.who), cbText(it.amount)]))),
    cbText(sp.memo)] &
    # a bill in fiat: its quote, one element more — a split without one is unchanged
    (if sp.quote.quoted: @[cbArray(@[cbText(sp.quote.currency), cbText(sp.quote.fiatTotal),
                                     cbText(sp.quote.fiatDecimals), cbText(sp.quote.rateFiat),
                                     cbText(sp.quote.rateAsset), cbText(sp.quote.source),
                                     cbText(sp.quote.at)])]
     else: @[]))))

method expectMaterialization*(d: SplitDriver, m: Materialization) = d.pending = m.bytes

proc agreerOf(mat: seq[byte], c: Contribution): string =
  ## "ed:<hex>" of the party whose room key signed `mat` — a debtor, or the creditor, whose
  ## agreement is their word that payTo is theirs (exo-770) — else "".
  if c.bytes.len != 64: return ""
  var sig: Ed25519Sig
  for i in 0 ..< 64: sig[i] = c.bytes[i]
  let creditor = creditorOf(mat)
  for who in debtorsOf(mat) & (if creditor.len > 0: @[creditor] else: @[]) & settlePartiesOf(mat):
    try:
      let pk = edOf(who)
      if edVerify(pk, mat, sig): return "ed:" & hx(pk)
    except CatchableError: discard
  ""

method verifyContribution*(d: SplitDriver, c: Contribution, round: int): bool =
  agreerOf(d.pending, c).len > 0

method identifyContributor*(d: SplitDriver, m: Materialization, c: Contribution): string =
  agreerOf(m.bytes, c)

method signRefusal*(d: SplitDriver, e: Effect): string =
  ## The malformed-split refusal, and — on THIS client's propose / sign path only — a
  ## party who is not a member of the room: nobody could agree for them.
  if e.isSettleUp:
    let (sok, su, swhy) = d.validSettle(e)
    if not sok: return swhy
    if d.roster.len > 0:
      for w in settleParties(su):
        if w notin d.roster: return "a party (" & w[0 ..< 12] & "…) is not a member of this room"
    return ""
  let (ok, sp, why) = d.validSplit(e)
  if not ok: return why
  if d.roster.len > 0:
    if sp.creditor notin d.roster: return "the creditor is not a member of this room"
    for s in sp.shares:
      if s.who notin d.roster: return "a debtor (" & s.who[0 ..< 12] & "…) is not a member of this room"
  ""

# ── settlement in parts ────────────────────────────────────────────────────────
method settlementParts*(d: SplitDriver, e: Effect): seq[string] =
  if e.isSettleUp:
    let (sok, su, _) = d.validSettle(e)
    return (if sok: su.transfers.mapIt(settlePart(it)) else: @[])
  let (ok, sp, _) = d.validSplit(e)
  if ok: sp.shares.mapIt(partName(it.who)) else: @[]

method partAuthor*(d: SplitDriver, e: Effect, part, step: string): string =
  ## "settled" by the debtor the part names; "confirmed" by the creditor, the one person
  ## the debt is owed to. Both named by room identity (invariant 9). A settle-up's part: its
  ## payer settles it, its recipient confirms it.
  if e.isSettleUp:
    let (sok, su, _) = d.validSettle(e)
    if not sok: return ""
    for t in su.transfers:
      if settlePart(t) == part:
        return (case step
                of "settled": t.frm
                of "confirmed": t.to
                else: "")
    return ""
  let (ok, sp, _) = d.validSplit(e)
  if not ok: return ""
  for s in sp.shares:
    if partName(s.who) == part:
      return (case step
              of "settled": s.who
              of "confirmed": sp.creditor
              else: "")
  ""

method partTransfer*(d: SplitDriver, e: Effect, part: string): PartTransfer =
  ## The payment that settles `part`: its share, to payTo, in the split's asset, on the
  ## policy's chain — read from the reviewed effect, never supplied (invariant 1). A
  ## settle-up's part: that net transfer.
  if e.isSettleUp:
    let (sok, su, swhy) = d.validSettle(e)
    if not sok: return PartTransfer(ok: false, error: swhy)
    for t in su.transfers:
      if settlePart(t) == part:
        return PartTransfer(ok: true, chain: d.chain, asset: su.asset, to: t.payTo, amount: t.amount)
    return PartTransfer(ok: false, error: "not a part of this settle-up")
  let (ok, sp, why) = d.validSplit(e)
  if not ok: return PartTransfer(ok: false, error: why)
  for s in sp.shares:
    if partName(s.who) == part:
      return PartTransfer(ok: true, chain: d.chain, asset: sp.asset, to: sp.payTo, amount: s.amount)
  PartTransfer(ok: false, error: "not a part of this split")

method covers*(d: SplitDriver, e: Effect): seq[CoverClaim] =
  ## A settle-up settles, when final, each part it covers: that split's share of that
  ## debtor, paid to that split's payTo, confirmed by that split's creditor — as claimed
  ## here, and checked by the core against the split itself before anyone agrees.
  if not e.isSettleUp: return
  let (ok, su, _) = d.validSettle(e)
  if not ok: return
  for c in su.covers:
    result.add CoverClaim(intent: c.intent, part: partName(c.debtor), chain: d.chain, asset: su.asset,
                          amount: c.amount, payTo: c.payTo, confirmer: c.creditor)

# ── profile + manifest ─────────────────────────────────────────────────────────
method profile*(d: SplitDriver): FamilyProfile =
  ## The each locus (docs/design/split-the-bill.md §3): no shared account, the room holds
  ## the agreement, each debtor's payment is their own transaction on the policy's chain.
  ## evm.split: every payment is an EIP-155 transfer — payer, payee and amount public at
  ## settle. lez.split: the private rail — nothing names a payer, payee or amount.
  ## btc.split: every payment is the payer's own Bitcoin spend — its inputs name the payer,
  ## and payee and amount are public once broadcast; the coins bind it to one chain.
  let lez = d.family == LezSplitFamily
  let btc = d.family == BtcSplitFamily
  FamilyProfile(declared: true, family: d.family,
    settlement: (if lez: "lez" elif btc: "bitcoin" else: "evm"),
    locus: loEach, scheme: scSharedBytes, commits: cmContent,
    # a Bitcoin payment spends coins that exist on one chain only: bound implicitly
    binding: (if lez: bdNone elif btc: bdImplicit else: bdExplicit),
    ordering: orNone, expiry: exOptional, setup: suNone, signerChange: chFixed,
    revealsPolicy: rvNever, revealsSigners: (if lez: rvNever else: rvAtSettle),
    revealsEffect: (if lez: evShielded else: evPublic),
    approverCost: acNone, rounds: 1, secretState: false, maturity: maDemo,
    chain: d.chain, account: "", k: 1, n: 0, bypassesKnown: true)

method manifest*(d: SplitDriver, effect: Effect): ActionManifest =
  ## Needs: the chain, an RPC to pay and to confirm through (the payer's and the
  ## creditor's own, invariant 8); from each debtor, the room key the split names and a
  ## balance that covers their share; from the proposer, the address to be paid (bound to
  ## payTo). Discloses per rail (§6): on EVM every payment's payer, payee and amount — and,
  ## because several payments reach one address close together, the group itself.
  var (ok, sp, _) = d.validSplit(effect)
  let lez = d.family == LezSplitFamily
  var touches = @[touch(d.chain, tmWrite)]
  if ok: touches.add touch(d.chain & ":" & sp.payTo, tmWrite)
  if effect.isSettleUp:
    # a settle-up pays each recipient where their own split agreed: those addresses move
    let (sok, su, _) = d.validSettle(effect)
    if sok:
      ok = true
      sp.asset = su.asset
      for t in su.transfers:
        let tt = touch(d.chain & ":" & t.payTo, tmWrite)
        if tt notin touches: touches.add tt
  # a token share is a call on the token contract: its balances are what move
  if ok and isErc20Asset(sp.asset): touches.add touch(d.chain & ":" & sp.asset[6 .. ^1], tmWrite)
  let btc = d.family == BtcSplitFamily
  let asset = (if ok: sp.asset elif lez: "LEZ" elif btc: "BTC" else: "ETH")
  ActionManifest(declared: true, agreement: d.describeFor(effect),
    requirements: @[
      req(rqEnvironment, d.chain),
      # the payer's and the creditor's own node / RPC (invariant 8)
      (if lez: req(rqModule, "lez_core") elif btc: req(rqInfra, "bitcoind-rpc") else: req(rqInfra, "rpc")),
      req(rqAuthority, "split-party", rpContributor),
      req(rqAsset, "share", rpPayer, need(mcAsset, d.chain & "/" & asset)),   # a debtor's; the creditor pays nothing
      req(rqAddress, "pay-to", rpProposer, need(mcAddress, d.chain, "payTo"))],
    discloses: (if lez: @[row("a-private-transfer", obChainObserver), row("signed-tx", obRpcProvider)]
                else: @[row("payer", obChainObserver), row("payee", obChainObserver),
                        row("amount", obChainObserver), row("group-linkage", obChainObserver),
                        row("signed-tx", obRpcProvider)]),
    touches: touches)

# ── composing a split ──────────────────────────────────────────────────────────
proc evenShares*(total, creditor: string, parties: seq[string],
                 creditorShares = true, distinctAmounts = false): seq[SplitShare] =
  ## Split `total` evenly: among `parties` and the creditor (listed or not) — "I paid for
  ## dinner, split it" — or, with `creditorShares = false`, among `parties` alone — "chip
  ## in for the gift I bought". Every debtor owes total div n, rounded DOWN; the creditor
  ## absorbs the remainder — at most n−1 of the smallest unit, visible as total − sum
  ## (§10.3). Sorted by who, each once: the one spelling the driver accepts. With
  ## `distinctAmounts` (the private split, §4.7) the i-th debtor owes i smallest units less, so
  ## every share differs and a received note is attributable by its amount alone — the
  ## creditor absorbs those few units too.
  var who: seq[string]
  for p in parties:
    let w = p.toLowerAscii()
    if w != creditor.toLowerAscii() and w notin who: who.add w
  who.sort()
  if who.len == 0: return
  let each = u256(total) div u256(who.len + (if creditorShares: 1 else: 0))
  for i, w in who:
    let off = (if distinctAmounts: u256(i) else: 0.u256)
    if distinctAmounts and off >= each: return @[]   # too small to tell apart: no valid private split
    result.add SplitShare(who: w, amount: $(each - off))

proc splitEffectJson*(chain, asset, total, creditor, payTo: string, shares: seq[SplitShare],
                      memo: string, quote = SplitQuote()): string =
  ## The effect JSON a composer proposes: shares sorted by who, so the same split has one
  ## intent id on every host.
  var sh = shares
  sh.sort(proc (a, b: SplitShare): int = cmp(a.who, b.who))
  var arr = newJArray()
  for s in sh: arr.add %*{"who": s.who, "amount": s.amount}
  var j = %*{"effect": "split", "chain": chain, "asset": asset, "total": total, "creditor": creditor,
             "payTo": payTo, "shares": arr, "memo": memo}
  if quote.quoted:
    # the quote is an external read (invariant 10): declared as sourced, so the proposer
    # must record the read in the log before anyone's agreement to it can count
    j["quote"] = %*{"currency": quote.currency, "fiatTotal": quote.fiatTotal,
                    "fiatDecimals": quote.fiatDecimals, "rateFiat": quote.rateFiat,
                    "rateAsset": quote.rateAsset, "source": quote.source, "at": quote.at}
    j["sources"] = %*{"quote": "read"}
  $j

# ── composing a settle-up (exo-3c6) ────────────────────────────────────────────
proc netTransfers*(covers: seq[Cover]): seq[NetTransfer] =
  ## The net payments that settle `covers`: each member's balance — what they are owed less
  ## what they owe — conserved, the largest net debtor paying the largest net creditor until
  ## one of them is square (ties by identity, so every member computes the same). Each
  ## recipient is paid at the payTo of the first covered split (by intent id) that owes
  ## them. Debts that cancel exactly need no payment at all.
  var credit, debit = initTable[string, UInt256]()
  var payTo = initTable[string, string]()
  var sorted = covers
  sorted.sort(proc (x, y: Cover): int = cmp((x.intent, x.debtor), (y.intent, y.debtor)))
  for c in sorted:
    credit[c.creditor] = credit.getOrDefault(c.creditor) + u256(c.amount)
    debit[c.debtor] = debit.getOrDefault(c.debtor) + u256(c.amount)
    if c.creditor notin payTo: payTo[c.creditor] = c.payTo
  var creditors, debtors: seq[(string, UInt256)]
  var who: seq[string]
  for w in toSeq(credit.keys) & toSeq(debit.keys):
    if w notin who: who.add w
  for w in who:
    let (cr, db) = (credit.getOrDefault(w), debit.getOrDefault(w))
    if cr > db: creditors.add (w, cr - db)
    elif db > cr: debtors.add (w, db - cr)
  let byAmount = proc (x, y: (string, UInt256)): int =
    if x[1] != y[1]: (if x[1] > y[1]: -1 else: 1) else: cmp(x[0], y[0])
  creditors.sort(byAmount)
  debtors.sort(byAmount)
  var i, j = 0
  while i < debtors.len and j < creditors.len:
    let x = min(debtors[i][1], creditors[j][1])
    result.add NetTransfer(frm: debtors[i][0], to: creditors[j][0], payTo: payTo[creditors[j][0]], amount: $x)
    debtors[i][1] = debtors[i][1] - x
    creditors[j][1] = creditors[j][1] - x
    if debtors[i][1] == 0.u256: inc i
    if creditors[j][1] == 0.u256: inc j
  result.sort(proc (x, y: NetTransfer): int = cmp((x.frm, x.to), (y.frm, y.to)))

proc settleUpEffectJson*(chain, asset: string, covers: seq[Cover], transfers: seq[NetTransfer],
                         memo: string): string =
  ## The settle-up a composer proposes: covers sorted by intent then debtor, transfers by
  ## from then to — one spelling, so the same netting has one intent id on every host.
  var cs = covers
  cs.sort(proc (x, y: Cover): int = cmp((x.intent, x.debtor), (y.intent, y.debtor)))
  var ts = transfers
  ts.sort(proc (x, y: NetTransfer): int = cmp((x.frm, x.to), (y.frm, y.to)))
  var ca = newJArray()
  for c in cs:
    ca.add %*{"intent": c.intent, "debtor": c.debtor, "creditor": c.creditor, "amount": c.amount, "payTo": c.payTo}
  var ta = newJArray()
  for t in ts: ta.add %*{"from": t.frm, "to": t.to, "payTo": t.payTo, "amount": t.amount}
  $(%*{"effect": "settle-up", "chain": chain, "asset": asset, "covers": ca, "transfers": ta, "memo": memo})
