## derived-exo-403 s3: the file's bytes are a pure function of the room's log and
## keys — reordering or duplicating the log yields the byte-identical file, exporting
## twice yields the same digest, and exporting writes nothing to any store.
##
## Trials: randomized rooms (policy, committed / pasted / declined mixes, settled or
## not) built through the hosted path. Per trial: export from the log as held; export
## again; export from a shuffled, duplicated copy of the same events — all three must
## be byte-identical with a non-empty file and equal digests; and alice's log and the
## network's traffic must be unchanged by exporting. Emits {"deterministic": ...}.
## Build: see live_room.nim.

import std/random
import ./audit_room
import ./oracle_emit

var rng = initRand(0x403)
var obs: seq[JsonNode]
var allOk = true

for trial in 0 ..< 16:
  let policy = LivePolicies[rng.rand(0 .. LivePolicies.len - 1)]
  var r = newRoom("/muster/1/audit-s3-" & $trial & "/proto")
  let id = r.propose(policy, effectFor(policy, 300 + trial))
  var approvals = 0
  for who in ["alice", "bob"]:
    case rng.rand(0 .. 3)
    of 0: discard
    of 1: (discard r.approveAs(who, id); inc approvals)
    of 2: (discard r.pasteAs(who, policy, id); inc approvals)
    else: r.declineAs(who, id)
  if policy == "safe" and approvals == 2 and rng.rand(0 .. 1) == 1: r.settle(id)
  let evs = r.alice.log.allEvents()
  let before = evs.len
  let a = exportAudit(evs, liveDriverFor, id, aliceKs)
  let b = exportAudit(evs, liveDriverFor, id, aliceKs)
  var other = evs
  for _ in 0 ..< rng.rand(1 .. evs.len): other.add evs[rng.rand(0 .. evs.high)]
  rng.shuffle(other)
  let c = exportAudit(other, liveDriverFor, id, aliceKs)
  r.alice.poll(); r.bob.poll()
  let ok = a.ok and b.ok and c.ok and a.bytes.len > 0 and
           a.bytes == b.bytes and b.bytes == c.bytes and
           auditDigest(a.bytes).len > 0 and auditDigest(a.bytes) == auditDigest(c.bytes) and
           r.alice.log.allEvents().len == before and r.bob.log.allEvents().len == before
  if not ok: allOk = false
  obs.add flag("deterministic", ok)

emitTrials(obs)
doAssert allOk, "the audit file was not a pure function of the log (or exporting wrote something)"
