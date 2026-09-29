## The home surface is a query over intents (F-18): for THIS member, every intent in a
## room is needs-you, waiting-on-others, or settled (exo-ed5).
##
## It reads the room's authentic log and the member's own keys, nothing else. What it
## says about anyone else is only what they disclosed (invariant 9): who agreed, who
## declined, which parts were reported paid. Whether YOUR contribution would count is
## the driver's to say (`mayContribute`, from its own signer set). An intent whose driver
## does not say is never "needs you".
##
##   collecting    needs you to agree / approve: you may contribute, and you have
##                 neither contributed nor declined. Anyone else: waiting.
##   agreed        a family settled in parts (a split): needs each party whose own part
##                 is unpaid. The counterparty's confirmation is their client's own read,
##                 not a click. Otherwise, with finality outside the room, needs someone
##                 to settle it; anyone in the room may, so it needs you. Final in the
##                 room: settled.
##   submitted     waiting on the chain (or on the remaining parts, as above).
##   final         settled.

import std/[json, strutils]
import ../log/log
import ../intents/materialization
import ../drivers/driver
import ../crypto/curve25519
import ./intents
import ./attest

type
  HomeClass* = enum
    hcNeedsYou = "needs-you"
    hcWaiting = "waiting-on-others"
    hcSettled = "settled"
  HomeItem* = object
    id*: string
    state*: string        ## the intent's lifecycle state, as folded
    cls*: HomeClass
    what*: string         ## needs-you: "agree" | "pay" | "approve" | "submit"; otherwise ""
    policy*: string
    effectJson*: string   ## what the intent does, for a surface to summarize

proc bare(s: string): string =
  result = s.toLowerAscii()
  if result.startsWith("0x"): result = result[2 .. ^1]

proc homeItems*(events: seq[Event], driverFor: DriverFor, me: EncIdentity,
                myNames: seq[string]): seq[HomeItem] =
  ## Every intent in `events` (a room's authentic view), classed for the member whose
  ## encryption identity is `me` and whose contributor names are `myNames`
  ## (attest.myContributorNames).
  const hexd = "0123456789abcdef"
  var meHex = ""
  for b in me.toBytes(): (meHex.add hexd[int(b shr 4)]; meHex.add hexd[int(b and 0x0F)])
  let mine = bareNames(myNames)
  for v in reduceIntentViews(events, driverFor):
    var it = HomeItem(id: v.id, state: v.state, cls: hcWaiting, policy: v.policy, effectJson: v.effectJson)
    if v.state == "final":
      it.cls = hcSettled
      result.add it
      continue
    let drv = driverFor(v.policy)
    var e: Effect
    try: e = effectFromJson(v.effectJson)
    except CatchableError:
      result.add it
      continue
    var whos: seq[string]
    for g in approvalGrades(events, driverFor, v.id):
      if g.grade != agRejected and g.who notin whos: whos.add g.who
    let agreed = approvedByMe(events, v.id, whos, me, myNames)
    var declined = false
    for d in v.decliners:
      if bare(d) == meHex: declined = true
    case v.state
    of "proposed", "collecting":
      if not agreed and not declined and drv.mayContribute(e, myNames) == elYes:
        it.cls = hcNeedsYou
        it.what = (if v.parts.len > 0: "agree" else: "approve")
    of "executable", "submitted", "settling":
      if v.parts.len > 0:
        # a family settled in parts: each party pays its own — the parts the driver says I
        # settle (a settle-up payer may owe two people); nobody else's click is needed
        for p in v.parts:
          if bare(drv.partAuthor(e, p.part, "settled")) == meHex and not p.settled:
            it.cls = hcNeedsYou
            it.what = "pay"
      elif v.state == "executable":
        if describeFor(drv, e).finality == finExternal:
          it.cls = hcNeedsYou
          it.what = "submit"
        else:
          it.cls = hcSettled      # agreed, and final in the room
    else: discard
    result.add it

proc toJson*(it: HomeItem): JsonNode =
  %*{"id": it.id, "state": it.state, "class": $it.cls, "what": it.what, "policy": it.policy}
