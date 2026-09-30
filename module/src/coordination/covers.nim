## Effects that settle parts of OTHER intents (exo-3c6): the generic half. A driver says
## what an effect covers (Driver.covers); the core never knows what a split or a settle-up
## is — it checks each claim against the covered intent's own agreed effect, read by that
## intent's own driver (invariant 1 across intents: what everyone agrees to settle is what
## those intents say), and answers "is this part already being settled elsewhere?".
##
## A covering intent's expiry (exo-a90.16). Its own payments are refused past its expiry
## (invariant 2), so a cover must not outlive it for ever, or the parts it covered could never
## be paid at all. The rule has two sides:
##   * one that paid nothing lapses: once its expiry AND CoverReleaseGraceS have passed, it
##     covers nothing, and its parts can be paid directly or covered again;
##   * one whose payments have begun is finished, never abandoned. Its remaining payments go
##     ahead past the expiry, and it keeps covering, because what it already moved replaced
##     the parts it covers, and paying those directly would pay twice.
## One with nothing to pay (debts that cancel exactly) is settled on agreement and never lapses.

import std/[strutils, tables]
import ../log/log
import ../intents/materialization
import ../drivers/driver
import ./intents
import ./attest

const AgreedStates = ["executable", "submitted", "settling"]

const CoverReleaseGraceS* = 86_400'u64
  ## How long past its expiry an unpaid covering intent still covers. A payment sent just
  ## before the expiry may land and be reported after it; this outlasts every seam's
  ## payDeadlineS (settle_up_expiry_test holds that), so a report of one lands inside it.

proc coveringIntent*(events: seq[Event], driverFor: DriverFor, intentId, part: string,
                     nowSec: uint64): string

proc coverLapsed*(events: seq[Event], driverFor: DriverFor, v: IntentView, nowSec: uint64): bool =
  ## True when `v` (an intent covering others' parts) paid nothing and its expiry and the
  ## grace window have passed: it covers nothing any more. Checked at action time against
  ## the clock, never inside the fold (invariant 4). With no clock (nowSec 0) it never lapses.
  if v.state != "executable" or nowSec == 0: return false
  var e: Effect
  try: e = effectFromJson(v.effectJson)
  except CatchableError: return false
  if driverFor(v.policy).settlementParts(e).len == 0: return false   # settled on agreement
  let ctx = intentContext(events, v.id)
  if ctx.isPlaceholder: return false
  nowSec > ctx.expiry and nowSec - ctx.expiry > CoverReleaseGraceS

proc beganSettling*(v: IntentView): bool =
  ## A parts intent at least one of whose parts is reported settled.
  v.state in ["submitted", "settling", "final"]

proc coverRefusal*(events: seq[Event], driverFor: DriverFor, drv: Driver, e: Effect, selfId = "",
                   nowSec: uint64 = 0): string =
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
    let other = coveringIntent(events, driverFor, c.intent, c.part, nowSec)
    if other.len > 0 and other != selfId:
      return "the covered part of " & c.intent & " is already being settled by " & other
  ""

proc coveringIntent*(events: seq[Event], driverFor: DriverFor, intentId, part: string,
                     nowSec: uint64): string =
  ## The agreed intent (or one already final) that settles `part` of `intentId` at `nowSec`
  ## — "" when none does. Once one does, the part is paid through it, never directly. One
  ## that lapsed (coverLapsed: paid nothing, expired past the grace window) covers nothing.
  for v in reduceIntentViews(events, driverFor):
    if v.id == intentId or v.state notin ["executable", "submitted", "settling", "final"]: continue
    if coverLapsed(events, driverFor, v, nowSec): continue
    var e: Effect
    try: e = effectFromJson(v.effectJson)
    except CatchableError: continue
    for c in driverFor(v.policy).covers(e):
      if c.intent == intentId and c.part == part: return v.id
  ""

proc coverIndex*(events: seq[Event], driverFor: DriverFor, views: seq[IntentView],
                 nowSec: uint64): Table[string, string] =
  ## "<intent>/<part>" → the intent covering that part at `nowSec`, from one fold (`views`,
  ## reduceIntentViews of `events`): coveringIntent for many lookups at once.
  for v in views:
    if v.state notin ["executable", "submitted", "settling", "final"]: continue
    if coverLapsed(events, driverFor, v, nowSec): continue
    var e: Effect
    try: e = effectFromJson(v.effectJson)
    except CatchableError: continue
    for c in driverFor(v.policy).covers(e):
      let k = c.intent & "/" & c.part
      if c.intent != v.id and k notin result: result[k] = v.id
