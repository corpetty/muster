## derived-exo-525 s1/c1: adding a member advances the epoch, and the new member's
## derived key set is disjoint from every prior epoch's keys — the forward-secrecy
## boundary is real at the moment of joining. Across random add/remove histories
## then a fresh join at epoch J, the joiner derives no epoch < J and no prior
## epoch's key value. Emits {"disjoint": ...}.

import ../../src/crypto/epochs
import std/[random, sets]
import ./oracle_emit

var obs: seq[JsonNode]

var r = initRand(0x525)
var allDisjoint = true

for trial in 0 ..< 200:
  var g = newGroup(@["founder"])
  for step in 0 .. r.rand(0 .. 6):
    if r.rand(0 .. 1) == 0 or g.members.len <= 1:
      g.addMember("m" & $trial & "_" & $step)
    else:
      g.removeMember(g.members[r.rand(0 ..< g.members.len)])

  let joinEpoch = g.epoch + 1
  g.addMember("newbie")

  let epochs = g.derivedKeyEpochs("newbie")
  var priorEpochs, priorVals, newVals: HashSet[int]
  var priorValStrs, newValStrs: HashSet[string]
  for e in 0 ..< joinEpoch:
    priorEpochs.incl e
    priorValStrs.incl $g.keyValue(e)
  for e in epochs:
    newValStrs.incl $g.keyValue(e)

  let epochDisjoint = (epochs * priorEpochs).len == 0
  let valueDisjoint = (newValStrs * priorValStrs).len == 0
  let disjoint = epochDisjoint and valueDisjoint
  if not disjoint: allDisjoint = false
  obs.add flag("disjoint", disjoint)

emitTrials(obs)
doAssert allDisjoint, "a joiner's derived key set overlapped a pre-join epoch"
