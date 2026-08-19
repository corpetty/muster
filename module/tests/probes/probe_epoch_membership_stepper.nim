## derived-exo-525 s2/c2: across the full reachable membership/epoch state space
## (any sequence of adds and removes), no member can decrypt content from any
## epoch before their join epoch. BFS over add/remove operations from a small
## pool; at every reachable group state, no current member can derive a key for a
## pre-join epoch. Emits {"membership_state_id": "...", "leak_detected": ...}.

import ../../src/crypto/epochs
import std/[deques, sets, tables]

proc leaks(g: Group): bool =
  for m in g.members:
    let je = g.joinEpoch[m]
    for e in 0 ..< je:
      if g.canDerive(m, e): return true
  false

let pool = ["x", "y", "z"]
var q = initDeque[Group]()
q.addLast newGroup(@["f1", "f2"])
var seen: HashSet[string]
var explored = 0
var allClean = true

while q.len > 0 and explored < 200:
  let g = q.popFirst()
  let sig = $g.epoch & "|" & $g.members & "|" & $g.transitions
  if sig in seen: continue
  seen.incl sig

  let leak = leaks(g)
  if leak: allClean = false
  echo "{\"membership_state_id\": \"e", g.epoch, "-m", g.members.len,
       "\", \"leak_detected\": ", (if leak: "true" else: "false"), "}"
  inc explored

  if g.epoch < 6:
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

doAssert allClean, "a member could derive a key for an epoch before they joined"
