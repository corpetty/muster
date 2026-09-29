## Settle up (exo-3c6; docs/design/split-the-bill.md §4.11): net several splits into fewer
## payments. The composing half and the finishing half — the effect, its checks and its
## parts are the split driver's (a settle-up is a second effect of the same families) and
## the cross-intent checks are the core's (coordination/covers).
##
##   openParts     the room's agreed, unpaid split parts on one chain and asset, each as its
##                 split says — what a settle-up can cover (none already covered by one);
##   settleCovered once a settle-up is final (or needs no payment at all), the creditor's
##                 client marks each part it covered received — the creditor's word, as for
##                 a share received outside muster, and the split goes final as ever.

import std/[strutils]
import ../log/log
import ../crypto/keystore
import ../intents/materialization
import ../drivers/driver
import ../drivers/split
import ./session
import ./authorship
import ./intents
import ./covers
import ./parts

proc openParts*(events: seq[Event], driverFor: DriverFor, chain, asset: string, nowSec: uint64): seq[Cover] =
  ## Every agreed split's unpaid part on `chain` in `asset`, as that split says it — its
  ## debtor, creditor, share and payTo — and not covered by a settle-up at `nowSec` (one
  ## that expired unpaid past the grace window covers nothing, coordination/covers).
  for v in reduceIntentViews(events, driverFor):
    if v.parts.len == 0 or v.state notin ["executable", "submitted", "settling"]: continue
    var e: Effect
    try: e = effectFromJson(v.effectJson)
    except CatchableError: continue
    if e.schemaId != SplitSchema: continue
    var sp: Split
    try: sp = splitOf(e)
    except ValueError: continue
    if sp.chain != chain or sp.asset != asset: continue
    for sh in sp.shares:
      let part = partName(sh.who)
      var paid = false
      for p in v.parts:
        if p.part == part and (p.settled or p.confirmed): paid = true
      if paid or coveringIntent(events, driverFor, v.id, part, nowSec).len > 0: continue
      result.add Cover(intent: v.id, debtor: sh.who, creditor: sp.creditor, amount: sh.amount, payTo: sp.payTo)

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
