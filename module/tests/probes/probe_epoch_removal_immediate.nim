## derived-exo-525 s3/c3: removing a member rotates the epoch immediately —
## content encrypted in the very next step after a removal is unreadable with the
## removed member's last-held key. Across random remove-then-encrypt trials, none
## of the keys the victim held before removal can derive the post-removal epoch
## key (the removal's fresh transition breaks every ratchet chain). Emits
## {"decrypt_failed": ...}.

import ../../src/crypto/epochs
import std/[random, sets]

var r = initRand(0x5253)
var allFailed = true

for trial in 0 ..< 200:
  var g = newGroup(@["founder", "victim"])
  for step in 0 .. r.rand(0 .. 5):
    g.addMember("m" & $trial & "_" & $step)

  # The victim's full key knowledge before removal (all epochs they can derive).
  let before = g.derivedKeyEpochs("victim")
  let couldReadBefore = before.len > 0 and g.canDerive("victim", g.epoch)

  g.removeMember("victim")
  let newEpoch = g.epoch

  # Can ANY key the victim retained derive the post-removal key? Only via an
  # unbroken ratchet chain reaching newEpoch — which the fresh transition breaks.
  var canStillDerive = false
  for e in before:
    if e > newEpoch: continue
    var chainOk = true
    for x in (e + 1) .. newEpoch:
      if g.transitions[x] != tkRatchet: chainOk = false; break
    if chainOk: canStillDerive = true

  let ok = couldReadBefore and (not canStillDerive)
  if not ok: allFailed = false
  echo "{\"decrypt_failed\": ", (if ok: "true" else: "false"), "}"

doAssert allFailed, "a removed member's key could still derive the post-removal epoch"
