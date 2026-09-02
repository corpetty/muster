## derived-exo-525 s2/c2: across the full reachable membership/epoch state space
## (any sequence of adds and removes), no member can decrypt content from any
## epoch before their join epoch.
##
## STEPPER (exo-dbc): state is (epoch, member count), the coordinates the spec's
## `membership_state_id` names, with its initial id "empty" being the genesis
## group. Successors are the states one add or one remove away. Each state's
## verdict quantifies over EVERY group configuration reachable at those
## coordinates, so collapsing many groups onto one id loses no coverage — the
## group-level walk still happens, nested inside the oracle's own.

import ../../src/crypto/epochs
import std/[deques, sets, tables, strutils]
import ./oracle_emit

const MaxEpoch = 6
let pool = ["x", "y", "z"]

proc leaks(g: Group): bool =
  for m in g.members:
    let je = g.joinEpoch[m]
    for e in 0 ..< je:
      if g.canDerive(m, e): return true
  false

proc reachableGroups(): seq[Group] =
  var q = initDeque[Group]()
  q.addLast newGroup(@["f1", "f2"])
  var seen: HashSet[string]
  while q.len > 0:
    let g = q.popFirst()
    let sig = $g.epoch & "|" & $g.members & "|" & $g.transitions
    if sig in seen: continue
    seen.incl sig
    result.add g
    if g.epoch < MaxEpoch:
      for p in pool:
        if p notin g.members:
          var g2 = g
          g2.addMember(p)
          q.addLast g2
      if g.members.len > 1:
        for m in g.members:
          var g2 = g
          g2.removeMember(m)
          q.addLast g2

let allGroups = reachableGroups()

proc stateId(epoch, members: int): string = "e" & $epoch & "-m" & $members

proc coordinates(): seq[(int, int)] =
  for g in allGroups:
    let c = (g.epoch, g.members.len)
    if c notin result: result.add c

proc leakAt(epoch, members: int): bool =
  ## Any group at these coordinates that leaks is a leak at this state.
  for g in allGroups:
    if g.epoch == epoch and g.members.len == members and leaks(g): return true
  false

proc state(epoch, members: int): JsonNode =
  %*{"membership_state_id": stateId(epoch, members), "leak_detected": leakAt(epoch, members)}

proc parseCoord(id: string): (int, int) =
  if id == "empty": return (0, 2)          # genesis: two founders at epoch 0
  let p = id.split('-')
  doAssert p.len == 2, "malformed membership_state_id: " & id
  (parseInt(p[0][1 .. ^1]), parseInt(p[1][1 .. ^1]))

let arg = oracleStateArg()
let (hereEpoch, hereMembers) = parseCoord(oracleStateStr(arg, "membership_state_id", "empty"))

var succ: seq[JsonNode]
for (e, m) in coordinates():
  # One add or one remove: the epoch advances by one and membership moves by one.
  if e == hereEpoch + 1 and (m == hereMembers + 1 or m == hereMembers - 1):
    succ.add state(e, m)
emitSuccessors(succ)

if arg == nil:
  for (e, m) in coordinates():
    doAssert not leakAt(e, m), "a member could derive a key for an epoch before they joined"
