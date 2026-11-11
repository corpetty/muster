## Member and threshold changes from the room (exo-267.6; docs/design/logos-world-plan.md
## Phase 1, The pieces). A LEZ multisig changes its members and threshold by ProposeConfig /
## ExecuteConfig, counting only current members' votes (drivers/lez_multisig.nim: the config
## effect, its S5 re-read; settlement: ExecuteConfig). Removing someone is an org act in two
## places: on chain they can no longer vote or be counted, and in the room they can no longer
## read. This module is the room's half:
##   * configReadingOf — a config proposal in words, naming the room member whose shared
##     account it adds or removes (member_accounts: an account counts as theirs only when
##     they proved it with its own key), or saying no member shared it;
##   * removalsDue — the room-side removals THIS member's client owes: a removal the chain
##     executed (the intent is final), of an account a room member shared, who still holds
##     the room's key. Only the proposer's client does it, so the room re-keys once and never
##     forks an epoch (CoordinationSession.expel).
## Pure functions of the event set (invariant 4).

import std/[json, strutils, sequtils]
import ../log/log
import ../drivers/driver
import ../drivers/lez_multisig
import ../lez/multisig
import ./intents
import ./member_accounts

proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc memberOfAccount*(events: seq[Event], room: string, account: seq[byte]): string =
  ## The room member who shared `account` with the room (proved by its own key), "" if none.
  let want = hx(account)
  for a in memberAccounts(events, room):
    if hx(a.address) == want: return a.member
  ""

proc configReadingOf*(events: seq[Event], effectJson: string, room: string): tuple[ok: bool, reading: JsonNode] =
  ## A config proposal as its card reads it: {index, change (add | remove | threshold),
  ## account?, member? (the room identity that shared it, "" when no member did),
  ## threshold?}; not ok for any other effect.
  let e = effectFromJson(effectJson)
  if e.schemaId != ConfigSchema: return (false, newJNull())
  try:
    let (idx, c) = lezConfigOf(e)
    var j = %*{"index": idx}
    case c.kind
    of caAddMember, caRemoveMember:
      j["change"] = %(if c.kind == caAddMember: "add" else: "remove")
      j["account"] = %hx(c.member)
      j["member"] = %memberOfAccount(events, room, c.member)
    of caChangeThreshold:
      j["change"] = %"threshold"
      j["threshold"] = %c.threshold
    (true, j)
  except ValueError: (false, newJNull())

proc removalsDue*(events: seq[Event], driverFor: DriverFor, room: string, holders: seq[string],
                  me: string): seq[(string, string)] =
  ## (member, intent) for each removal the chain executed that THIS member proposed, of an
  ## account a room member shared, who is still among `holders` (the room's current key
  ## holders, as identity hex). The proposer's client re-keys them out; nobody else does.
  let mine = me.toLowerAscii()
  let held = holders.mapIt(it.toLowerAscii())
  for v in reduceIntentViews(events, driverFor):
    if v.state != "final" or v.effectJson.len == 0: continue
    if not v.proposers.anyIt(it.toLowerAscii() == mine): continue
    let (ok, r) = configReadingOf(events, v.effectJson, room)
    if not ok or r["change"].getStr() != "remove": continue
    let who = r["member"].getStr()
    if who.len > 0 and who in held and (who, v.id) notin result: result.add (who, v.id)
