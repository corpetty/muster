## derived-exo-3a1 s6/c6: the provenance record is confined to the conversation and
## scoped to the membership epoch of the entries it describes — an actor lacking
## epoch E's keys reconstructs no provenance entry describing an epoch-E input, and
## a later joiner cannot reach earlier lineage. BFS over the membership/epoch state
## space (joins, removals): at every reachable state no member reconstructs
## provenance for a pre-join epoch. Emits
## {"epoch": n, "no_cross_epoch_reconstruction": ...}.
import ../../src/crypto/epochs
import ../../src/intents/provenance
import std/[deques, sets, tables]

proc crossEpochLeak(g: Group): bool =
  for m in g.members:
    for e in 0 ..< g.joinEpoch[m]:
      if canReconstruct(g, m, e): return true
  false

let pool = ["x", "y", "z"]
var q = initDeque[Group]()
q.addLast newGroup(@["f1", "f2"])
var seen: HashSet[string]
var explored = 0
var allClean = true
while q.len > 0 and explored < 60:
  let g = q.popFirst()
  let sig = $g.epoch & "|" & $g.members & "|" & $g.transitions
  if sig in seen: continue
  seen.incl sig
  let leak = crossEpochLeak(g)
  if leak: allClean = false
  echo "{\"epoch\": ", g.epoch, ", \"no_cross_epoch_reconstruction\": ",
       (if not leak: "true" else: "false"), "}"
  inc explored
  if g.epoch < 5:
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
doAssert allClean, "an actor reconstructed provenance for an epoch before they joined"
