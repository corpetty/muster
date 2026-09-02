## derived-exo-3a1 s6/c6: the provenance record is confined to the conversation
## and scoped to the membership epoch of the entries it describes — an actor
## lacking epoch E's keys reconstructs no provenance entry describing an epoch-E
## input, and a later joiner cannot reach earlier lineage.
##
## STEPPER (exo-dbc): state is (epoch, keys_held), the dimensions the spec's
## `initial` names. Successors step the epoch or switch the key situation. Each
## state's verdict quantifies over every membership configuration reachable at
## that epoch by adds and removals, which is the group-level BFS this probe used
## to run itself.

import ../../src/crypto/epochs
import ../../src/intents/provenance
import std/[deques, sets, tables]
import ./oracle_emit

const MaxEpoch = 5
const KeySituations = ["current", "prior"]

let pool = ["x", "y", "z"]

proc groupsAtEpoch(target: int): seq[Group] =
  ## Every membership configuration reachable at `target` by adds and removals.
  var q = initDeque[Group]()
  q.addLast newGroup(@["f1", "f2"])
  var seen: HashSet[string]
  while q.len > 0:
    let g = q.popFirst()
    let sig = $g.epoch & "|" & $g.members & "|" & $g.transitions
    if sig in seen: continue
    seen.incl sig
    if g.epoch == target: result.add g
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

proc scopeHolds(epoch: int, keysHeld: string): bool =
  ## "prior" is the confinement half: no member reaches an epoch before they
  ## joined. "current" is the liveness half: a member CAN reach their own join
  ## epoch — without it, a record nobody can reconstruct would pass the
  ## confinement check vacuously.
  for g in groupsAtEpoch(epoch):
    for m in g.members:
      if keysHeld == "prior":
        for e in 0 ..< g.joinEpoch[m]:
          if canReconstruct(g, m, e): return false
      else:
        if not canReconstruct(g, m, g.joinEpoch[m]): return false
  true

proc state(epoch: int, keysHeld: string): JsonNode =
  %*{"epoch": epoch, "keys_held": keysHeld,
     "no_cross_epoch_reconstruction": scopeHolds(epoch, keysHeld)}

let arg = oracleStateArg()
let hereEpoch = oracleStateInt(arg, "epoch", 0)
let hereKeys = oracleStateStr(arg, "keys_held", "current")

var succ: seq[JsonNode]
for e in [hereEpoch - 1, hereEpoch + 1]:
  if e in 0 .. MaxEpoch: succ.add state(e, hereKeys)
for k in KeySituations:
  if k != hereKeys: succ.add state(hereEpoch, k)
emitSuccessors(succ)

if arg == nil:
  for e in 0 .. MaxEpoch:
    for k in KeySituations:
      doAssert scopeHolds(e, k),
        "an actor reconstructed provenance for an epoch before they joined"
