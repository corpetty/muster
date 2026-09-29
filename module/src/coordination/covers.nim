## Effects that settle parts of OTHER intents (exo-3c6): the generic half. A driver says
## what an effect covers (Driver.covers); the core never knows what a split or a settle-up
## is — it checks each claim against the covered intent's own agreed effect, read by that
## intent's own driver (invariant 1 across intents: what everyone agrees to settle is what
## those intents say), and answers "is this part already being settled elsewhere?".

import std/[strutils]
import ../log/log
import ../intents/materialization
import ../drivers/driver
import ./intents

const AgreedStates = ["executable", "submitted", "settling"]

proc coveringIntent*(events: seq[Event], driverFor: DriverFor, intentId, part: string): string

proc coverRefusal*(events: seq[Event], driverFor: DriverFor, drv: Driver, e: Effect, selfId = ""): string =
  ## Before anyone agrees to `e` (the intent `selfId`): every part it claims to settle must
  ## be a part of an agreed intent in this room, still unpaid, not already being settled by
  ## another agreed intent, and exactly as that intent says — its chain and asset, its
  ## amount and address, its counterparty. "" when every claim holds (or none).
  let claims = drv.covers(e)
  if claims.len == 0: return ""
  let views = reduceIntentViews(events, driverFor)
  for c in claims:
    var found = false
    for v in views:
      if v.id != c.intent: continue
      found = true
      if v.state notin AgreedStates:
        return "the covered intent " & c.intent & " is " & v.state & ", not agreed and unsettled"
      let od = driverFor(v.policy)
      var oe: Effect
      try: oe = effectFromJson(v.effectJson)
      except CatchableError: return "the covered intent " & c.intent & " carries no effect to check against"
      if c.part notin od.settlementParts(oe): return "the covered intent " & c.intent & " has no part " & c.part
      let t = od.partTransfer(oe, c.part)
      if not t.ok: return "the covered part cannot be read: " & t.error
      if t.chain != c.chain or t.asset != c.asset:
        return "the cover of " & c.intent & " says " & c.asset & " on " & c.chain & "; it pays " & t.asset & " on " & t.chain
      if t.amount != c.amount:
        return "the cover of " & c.intent & " says " & c.amount & "; its part is " & t.amount
      if t.to.toLowerAscii() != c.payTo.toLowerAscii():
        return "the cover of " & c.intent & " pays " & c.payTo & "; its part pays " & t.to
      if od.partAuthor(oe, c.part, "confirmed").toLowerAscii() != c.confirmer.toLowerAscii():
        return "the cover of " & c.intent & " names another counterparty than its part does"
      for p in v.parts:
        if p.part == c.part and (p.settled or p.confirmed):
          return "the covered part of " & c.intent & " is already paid"
    if not found: return "the covered intent " & c.intent & " is not in this room"
    let other = coveringIntent(events, driverFor, c.intent, c.part)
    if other.len > 0 and other != selfId:
      return "the covered part of " & c.intent & " is already being settled by " & other
  ""

proc coveringIntent*(events: seq[Event], driverFor: DriverFor, intentId, part: string): string =
  ## The agreed intent (or one already final) that settles `part` of `intentId` — "" when
  ## none does. Once one does, the part is paid through it, never directly.
  for v in reduceIntentViews(events, driverFor):
    if v.id == intentId or v.state notin ["executable", "submitted", "settling", "final"]: continue
    var e: Effect
    try: e = effectFromJson(v.effectJson)
    except CatchableError: continue
    for c in driverFor(v.policy).covers(e):
      if c.intent == intentId and c.part == part: return v.id
  ""
