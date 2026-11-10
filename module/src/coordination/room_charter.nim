## The charter in force, as a fold over the room's log (exo-267.1; invariant 4).
##
## Each charter is an intent under the `charter` kind (drivers/charter.nim), agreed by the
## electorate its own effect names. Which of the agreed ones is IN FORCE is this fold's:
##   * a founding charter (prev "") — its driver already holds that every member it names
##     decided it. Among several agreed foundings, the one whose members include every
##     other's: a founding by fewer people never displaces one by more, since anyone may
##     found a charter naming only themselves and agree to it alone, and an id is the
##     proposer's to grind. Among those naming the same members, the lowest id (they all
##     agreed to each). Foundings by groups neither of which includes the other are
##     CONTESTED: no charter is in force until a founding naming them all is agreed;
##   * then, repeatedly, an amendment whose prev is the charter in force AND whose
##     electorate and k are that charter's own members and amend k — the rule for
##     changing rules, applied by the rules in force. An agreed amendment decided under
##     any other electorate or k is out of rule and never takes force; among several in
##     rule, the lowest intent id, the rest superseded.
## A pure function of the event set: every member, in any order, with any duplicates,
## folds the same charter (R-2/R-3). Nothing here asks what kind of room it is — the
## circle is a template that fills a body (doctrine: capabilities, never types).

import std/[json, tables, sequtils, algorithm, strutils]
import ../log/log
import ../drivers/charter
import ./intents
import ./accounts
export charter

type CharterView* = object
  found*: bool
  id*: string                 ## the intent id of the charter in force
  body*: CharterBody
  history*: seq[string]       ## the charters that took force, founding first
  superseded*: seq[string]    ## agreed, in rule, but another amendment of the same charter held
  outOfRule*: seq[string]     ## agreed by their own count, but not under the charter they amend
  contested*: seq[string]     ## agreed foundings by groups neither of which includes the other

proc charterInForce*(events: seq[Event], driverFor: DriverFor): CharterView =
  let folded = reduceIntents(events, driverFor)
  var agreed: seq[tuple[id: string, c: CharterEffect]]
  for id, it in folded:
    if it.state notin {lsExecutable, lsSubmitted, lsSettling, lsFinal}: continue
    if intentPolicyOf(events, id, "") != CharterKind: continue
    let (ok, c, _) = charterOf(it.effect)
    if ok: agreed.add (id, c)
  agreed.sort(proc (a, b: tuple[id: string, c: CharterEffect]): int = cmp(a.id, b.id))

  let founds = agreed.filterIt(it.c.prev.len == 0)
  if founds.len == 0: return
  proc covers(a, b: CharterEffect): bool = b.electorate.allIt(it in a.electorate)
  var widest: seq[tuple[id: string, c: CharterEffect]]
  for f in founds:
    if founds.allIt(f.c.covers(it.c)): widest.add f
  if widest.len == 0:
    result.contested = founds.mapIt(it.id)
    return
  result.found = true
  result.id = widest[0].id
  result.body = widest[0].c.body
  result.history = @[widest[0].id]
  for f in founds:
    if f.id != widest[0].id: result.superseded.add f.id
  while true:
    let cur = result
    var inRule: seq[tuple[id: string, c: CharterEffect]]
    for a in agreed:
      if a.c.prev != cur.id: continue
      if sorted(a.c.electorate) == sorted(cur.body.members) and a.c.k == cur.body.amendK: inRule.add a
      else: result.outOfRule.add a.id
    if inRule.len == 0: break
    result.id = inRule[0].id
    result.body = inRule[0].c.body
    result.history.add inRule[0].id
    for a in inRule[1 .. ^1]: result.superseded.add a.id
  result.superseded.sort()
  result.outOfRule.sort()

proc amendmentEffect*(current: CharterView, body: JsonNode): string =
  ## The effect JSON that amends the charter in force: decided by its members, as many as
  ## its amend rule asks. Proposed under the `charter` kind.
  amendEffectJson(current.id, current.body.members, current.body.amendK, body)

proc charterAccountProblems*(b: CharterBody, accounts: seq[RoomAccount]): seq[string] =
  ## Whether the account the charter names is one the room was shown, and agrees with it.
  ## The chain enforces the account's own members and threshold; the charter names who
  ## the room's members are. A disagreement is shown, never silently trusted.
  if b.account.len == 0: return
  let want = b.account.toLowerAscii()
  for a in accounts:
    if a.id.toLowerAscii() != want: continue
    if a.conflict: result.add "members disclosed different configurations for the charter's account"
    if a.signers.len != b.members.len:
      result.add "the charter's account has " & $a.signers.len & " members; the charter names " & $b.members.len
    return
  result.add "the charter's account (" & b.account & ") has not been disclosed in this room"

# ── the hosted surface's halves (coordinate_charter, coordinate_propose_charter) ─────
proc toJson*(b: CharterBody): JsonNode =
  ## A charter body as JSON, the shape parseCharterBody reads back.
  result = %*{"name": b.name, "purpose": b.purpose, "members": b.members, "amend": {"k": b.amendK},
              "roles": b.roles.mapIt(%*{"slot": it.slot, "name": it.name, "holders": it.holders}),
              "rules": newJObject()}
  for (k, v) in b.rules: result["rules"][k] = %v
  if b.account.len > 0: result["account"] = %b.account
  if b.hasSchedule:
    result["schedule"] = %*{"cadence": b.schedule.cadenceSec, "share": b.schedule.share,
                            "asset": b.schedule.asset, "order": b.schedule.order}

proc charterProposal*(current: CharterView, spec: JsonNode, roomMembers: seq[string]):
    tuple[ok: bool, effectJson: string, founding: bool, why: string] =
  ## The effect a member proposes under the `charter` kind: a founding when no charter is
  ## in force, else an amendment of the one in force, decided under its rule. spec is a
  ## charter body, or {template: "circle", name, purpose?, amendK?, members?, account?,
  ## share?, asset?, cadence?}. Founding from the template, members default to the room's;
  ## amending from it, every field it does not name carries over from the charter in force. Refused, with the reason, when the body would not parse: nothing malformed is
  ## ever proposed for anyone to sign.
  template no(msg: string) = return (false, "", false, msg)
  if spec.kind != JObject: no("a charter proposal is a body or a template")
  var body = spec
  if spec.hasKey("template") and current.found:
    # an amendment from the template changes only what it names: the rest — the schedule,
    # the account and the rules that act from it, the roles — carries over from the charter
    # in force, so a rename never silently ends a circle
    if spec["template"].getStr() != "circle": no("unknown template: " & spec["template"].getStr() & " (circle)")
    body = current.body.toJson()
    for k in ["name", "purpose"]:
      if spec.hasKey(k): body[k] = %spec[k].getStr()
    if spec.hasKey("members"):
      var ms: seq[string]
      for m in spec["members"].getElems(): ms.add m.getStr()
      body["members"] = %ms
      if body.hasKey("schedule"): body["schedule"]["order"] = %ms
      for r in body["roles"]: r["holders"] = %r["holders"].getElems().filterIt(it.getStr() in ms)
    if spec.hasKey("amendK"): body["amend"] = %*{"k": spec["amendK"].getInt()}
    if spec.hasKey("account"):
      let a = spec["account"].getStr()
      let fresh = circleTemplate("x", "", @[], 1, account = a)
      for cls in ["payout", "member-change"]:
        if body["rules"].hasKey(cls): body["rules"].delete(cls)
        if fresh["rules"].hasKey(cls): body["rules"][cls] = fresh["rules"][cls]
      if a.len > 0: body["account"] = %a
      elif body.hasKey("account"): body.delete("account")
    if spec.hasKey("share") or spec.hasKey("asset") or spec.hasKey("cadence"):
      if not body.hasKey("schedule"):
        body["schedule"] = %*{"cadence": 0, "share": "", "asset": "", "order": body["members"]}
      if spec.hasKey("share"): body["schedule"]["share"] = %spec["share"].getStr()
      if spec.hasKey("asset"): body["schedule"]["asset"] = %spec["asset"].getStr()
      if spec.hasKey("cadence"): body["schedule"]["cadence"] = %spec["cadence"].getBiggestInt()
  elif spec.hasKey("template"):
    if spec["template"].getStr() != "circle": no("unknown template: " & spec["template"].getStr() & " (circle)")
    var members = roomMembers
    if spec.hasKey("members"):
      members = @[]
      for m in spec["members"].getElems(): members.add m.getStr()
    let k = (if spec.hasKey("amendK"): spec["amendK"].getInt() else: members.len div 2 + 1)
    body = circleTemplate(name = spec{"name"}.getStr(), purpose = spec{"purpose"}.getStr(),
                          members = members, amendK = k, account = spec{"account"}.getStr(),
                          share = spec{"share"}.getStr(), asset = spec{"asset"}.getStr(),
                          cadenceSec = spec{"cadence"}.getBiggestInt())
  let (ok, _, why) = parseCharterBody(body)
  if not ok: no(why)
  if current.found: (true, amendmentEffect(current, body), false, "")
  else: (true, foundingEffect(body), true, "")

proc charterJson*(events: seq[Event], driverFor: DriverFor, accounts: seq[RoomAccount]): JsonNode =
  ## The room's charter for its members: the one in force (its body, how it came to be,
  ## whether its account is one the room was shown and agrees), and every charter
  ## proposal with its standing — said before anyone signs, so nobody agrees to one that
  ## can never take force:
  ##   in force | replaced (was in force, amended since) | pending (would take force once
  ##   agreed) | out of rule (not decided under the rule of the charter it amends) |
  ##   stale (amends a charter no longer in force) | superseded (another one held) |
  ##   contested (a founding competing with one by a group neither includes).
  ## A pure function of the event set (invariant 4).
  let v = charterInForce(events, driverFor)
  result = %*{"found": v.found, "id": v.id, "history": v.history, "superseded": v.superseded,
              "outOfRule": v.outOfRule, "contested": v.contested, "problems": newJArray(),
              "proposals": newJArray()}
  if v.found:
    result["body"] = v.body.toJson()
    for p in charterAccountProblems(v.body, accounts): result["problems"].add %p
  var props: seq[JsonNode]
  for iv in reduceIntentViews(events, driverFor):
    if iv.policy != CharterKind or iv.effectJson.len == 0: continue
    let (ok, c, _) = charterOf(effectFromJson(iv.effectJson))
    if not ok: continue
    let founding = c.prev.len == 0
    let inRule = founding or (v.found and c.prev == v.id and
                              sorted(c.electorate) == sorted(v.body.members) and c.k == v.body.amendK)
    let standing =
      if v.found and iv.id == v.id: "in force"
      elif iv.id in v.history: "replaced"
      elif iv.id in v.superseded: "superseded"
      elif iv.id in v.contested: "contested"
      elif iv.id in v.outOfRule: "out of rule"
      elif founding: "pending"
      elif not v.found or c.prev != v.id: "stale"
      elif not inRule: "out of rule"
      else: "pending"
    var bj: JsonNode
    try: bj = parseJson(c.bodyText)
    except CatchableError: bj = newJNull()
    props.add %*{"id": iv.id, "founding": founding, "prev": c.prev, "electorate": c.electorate, "k": c.k,
                 "state": iv.state, "approvals": iv.approvals, "decliners": iv.decliners,
                 "proposers": iv.proposers, "standing": standing, "body": bj}
  result["proposals"] = %props
