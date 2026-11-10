## The charter in force, as a fold over the room's log (exo-267.1; invariant 4).
##
## Each charter is an intent under the `charter` kind (drivers/charter.nim), agreed by the
## electorate its own effect names. Which of the agreed ones is IN FORCE is this fold's:
##   * a founding charter (prev "") — its driver already holds that every member it names
##     decided it; among several agreed foundings, the lowest intent id;
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
  result.found = true
  result.id = founds[0].id
  result.body = founds[0].c.body
  result.history = @[founds[0].id]
  for f in founds[1 .. ^1]: result.superseded.add f.id
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
