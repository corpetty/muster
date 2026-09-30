## Settle up (exo-3c6; docs/design/split-the-bill.md §4.11): net several splits into fewer
## payments. The composing half and the finishing half — the effect, its checks and its
## parts are the split driver's (a settle-up is a second effect of the same families) and
## the cross-intent checks are the core's (coordination/covers).
##
##   openParts     the room's agreed, unpaid split parts on one chain and asset, each as its
##                 split says — what a settle-up can cover (none already covered by one);
##                 openPartsAll, those on every public rail, each naming its chain and asset;
##   settleUpAcross a settle-up across assets and chains (exo-a90.17, §4.13): the open parts
##                 in the payment asset or one the proposer gave a rate for, netted in the
##                 payment asset, each recipient owed only elsewhere paid at the address they
##                 shared for the payment chain;
##   settleCovered once a settle-up is final (or needs no payment at all), the creditor's
##                 client marks each part it covered received — the creditor's word, as for
##                 a share received outside muster, and the split goes final as ever;
##   renewalOf     a settle-up of ONE split's unpaid shares, named by when it was made: how
##                 a split past its expiry is paid after all (exo-a90.15) — everyone its
##                 unpaid shares name agrees again, under the renewal's own, fresh expiry.

import std/[strutils, times, unicode, tables, json, sequtils]
import ../log/log
import ../crypto/keystore
import ../intents/materialization
import ../drivers/driver
import ../drivers/split
import ../drivers/kinds      # splitPolicy: which family a split is
import ../bitcoin/[network, bech32]
import ./session
import ./authorship
import ./intents
import ./covers
import ./parts

proc openPartsWhere(events: seq[Event], driverFor: DriverFor, nowSec: uint64,
                    keep: proc (sp: Split): bool): seq[Cover] =
  for v in reduceIntentViews(events, driverFor):
    if v.parts.len == 0 or v.state notin ["executable", "submitted", "settling"]: continue
    var e: Effect
    try: e = effectFromJson(v.effectJson)
    except CatchableError: continue
    if e.schemaId != SplitSchema: continue
    var sp: Split
    try: sp = splitOf(e)
    except ValueError: continue
    if not keep(sp): continue
    for sh in sp.shares:
      let part = partName(sh.who)
      var paid = false
      for p in v.parts:
        if p.part == part and (p.settled or p.confirmed): paid = true
      if paid or coveringIntent(events, driverFor, v.id, part, nowSec).len > 0: continue
      result.add Cover(intent: v.id, debtor: sh.who, creditor: sp.creditor, amount: sh.amount, payTo: sp.payTo,
                       chain: sp.chain, asset: sp.asset)

proc openParts*(events: seq[Event], driverFor: DriverFor, chain, asset: string, nowSec: uint64): seq[Cover] =
  ## Every agreed split's unpaid part on `chain` in `asset`, as that split says it — its
  ## debtor, creditor, share and payTo — and not covered by a settle-up at `nowSec` (one
  ## that expired unpaid past the grace window covers nothing, coordination/covers).
  openPartsWhere(events, driverFor, nowSec, proc (sp: Split): bool = sp.chain == chain and sp.asset == asset)

proc openPartsAll*(events: seq[Event], driverFor: DriverFor, nowSec: uint64): seq[Cover] =
  ## openParts on every public split rail at once — Ethereum and Bitcoin, never the private
  ## split — each cover naming its own chain and asset (§4.13).
  openPartsWhere(events, driverFor, nowSec,
                 proc (sp: Split): bool = familyOfChain(sp.chain) in [EvmSplitFamily, BtcSplitFamily])

proc sharedAddressOn*(events: seq[Event], who, chain: string): string =
  ## The address `who` last shared into the room that a payment on `chain` reaches: their
  ## Ethereum address for an eip155 chain (sharedAddressOf), a Bitcoin address of that
  ## network for a bip122 one — "" when they shared none. Read over the room's authentic
  ## view: a share posted in `who`'s name by anyone else never reaches here.
  case familyOfChain(chain)
  of EvmSplitFamily: return sharedAddressOf(events, who)
  of BtcSplitFamily:
    var hrp = ""
    try: hrp = networkByCaip2(chain).hrp
    except CatchableError: return ""
    proc bare(s: string): string =
      result = s.toLowerAscii()
      if result.startsWith("0x"): result = result[2 .. ^1]
    for m in reduceMessages(events):             # oldest first: the newest share wins
      if bare(m.author) != bare(who): continue
      try:
        let b = parseJson(m.body)
        if b.kind != JObject or b{"kind"}.getStr() != "address-share" or b{"asset"}.getStr() != "BTC": continue
        let a = b{"address"}.getStr()
        if a == a.toLowerAscii() and decodeSegwitAddress(hrp, a).program.len > 0: result = a
      except CatchableError: discard
  else: return ""

proc settleUpAcross*(events: seq[Event], driverFor: DriverFor, payChain, payAsset: string,
                     rates: seq[SettleRate], memo: string, nowSec: uint64):
    tuple[effectJson, why: string, covers: seq[Cover]] =
  ## A settle-up paid on `payChain` in `payAsset` (§4.13): every open part in the payment
  ## asset or in one `rates` prices, each converted at its rate, netted, each recipient owed
  ## by no covered split on the payment chain paid at the address they last shared for it.
  ## `why`: "no open share in …" for a rate nothing is owed in; a conversion's refusal;
  ## "nothing-to-net" under two parts; "no-address:<identity>" for a recipient who shared no
  ## address on the payment chain — theirs to share, never the composer's to guess.
  let all = openPartsAll(events, driverFor, nowSec)
  for r in rates:
    if not all.anyIt(it.chain == r.chain and it.asset == r.asset):
      return ("", "no open share in " & r.asset & " on " & r.chain, @[])
  var covers: seq[Cover]
  for c in all:
    var priced = c.chain == payChain and c.asset == payAsset
    for r in rates:
      if r.chain == c.chain and r.asset == c.asset: priced = true
    if priced: covers.add c
  if covers.len < 2: return ("", "nothing-to-net", @[])
  for c in covers:
    let conv = convertedAmount(c, rates, payChain, payAsset)
    if not conv.ok: return ("", conv.why, @[])
  var vouched = initTable[string, string]()
  for c in covers:
    if c.creditor in vouched or covers.anyIt(it.creditor == c.creditor and it.chain == payChain): continue
    vouched[c.creditor] = sharedAddressOn(events, c.creditor, payChain)
  let ts = netTransfers(covers, rates, payChain, payAsset, vouched)
  for t in ts:
    if t.payTo.len == 0: return ("", "no-address:" & t.to, @[])
  (settleUpEffectJson(payChain, payAsset, covers, ts, memo, rates), "", covers)

proc settleCovered*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: PartSeam): seq[string] =
  ## The creditor's pump: for every settle-up that is final — or agreed and needing no
  ## payment at all (debts that cancel exactly) — mark each part it covered that I confirm
  ## received (no reference: settled by the settle-up, my word). Returns "<intent>/<part>"
  ## for each marked now.
  s.poll()
  let events = s.roomEvents()
  let me = myIdentity(ks)
  for v in reduceIntentViews(events, driverFor):
    var e: Effect
    try: e = effectFromJson(v.effectJson)
    except CatchableError: continue
    let drv = driverFor(v.policy)
    let claims = drv.covers(e)
    if claims.len == 0: continue
    let done = v.state == "final" or (v.state == "executable" and drv.settlementParts(e).len == 0)
    if not done: continue
    for c in claims:
      if c.confirmer.toLowerAscii() != me: continue
      let r = liveConfirmPart(s, ks, driverFor, c.intent, c.part, seam, "")
      if r in ["executable", "submitted", "settling", "final"]: result.add c.intent & "/" & c.part

proc renewalOf*(events: seq[Event], driverFor: DriverFor, intentId: string, nowSec: uint64):
    tuple[effectJson, why: string, covers: seq[Cover]] =
  ## A renewal of the split `intentId` (exo-a90.15, docs/design/split-the-bill.md §4.12): a
  ## settle-up covering exactly its unpaid shares, as the split says them, each paid by its
  ## own debtor to the split's payTo. Its memo names when it was made, so renewing again —
  ## after a renewal lapsed unpaid (exo-a90.16) — is a new intent with its own expiry, never
  ## the old one. `why` says what cannot be renewed: an unknown or final intent, one that is
  ## not a split, the private split (never netted: it is proposed again), or a split with
  ## no unpaid, unsettled share left.
  var found = false
  var v: IntentView
  for w in reduceIntentViews(events, driverFor):
    if w.id == intentId: (found = true; v = w)
  if not found: return ("", "unknown-intent", @[])
  if v.state == "final": return ("", "nothing to renew: the split is final", @[])
  var e: Effect
  try: e = effectFromJson(v.effectJson)
  except CatchableError: return ("", "not a split", @[])
  if e.schemaId != SplitSchema: return ("", "not a split", @[])
  if splitPolicy(v.policy).kind == "lez-split":
    return ("", "the private split is never netted: propose it again", @[])
  var sp: Split
  try: sp = splitOf(e)
  except ValueError: return ("", "not a split", @[])
  var covers: seq[Cover]
  for c in openParts(events, driverFor, sp.chain, sp.asset, nowSec):
    if c.intent == intentId: covers.add c
  if covers.len == 0:
    return ("", "nothing to renew: every share is paid, or already being settled", @[])
  let stamp = "Renewed " & fromUnix(int64(nowSec)).utc.format("yyyy-MM-dd HH:mm:ss") & " UTC"
  var memo = stamp & (if sp.memo.len > 0: " — " & sp.memo else: "")
  if memo.len > MaxMemo:                      # keep whole characters within the limit
    var cut = ""
    for r in memo.runes:
      if cut.len + r.size > MaxMemo: break
      cut.add $r
    memo = cut
  (settleUpEffectJson(sp.chain, sp.asset, covers, netTransfers(covers), memo), "", covers)
