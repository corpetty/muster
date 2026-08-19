## derived-exo-548 s2/c2: applying the same event twice never changes state
## beyond applying it once. Across randomized event sets, reducing a set equals
## reducing the same set with an arbitrary member duplicated (and duplicated
## twice). Emits {"idempotent": ...} per trial; the at-least-once delivery
## guarantee depends on this holding always.

import ../../src/log/log
import std/random

proc randKey(r: var Rand): string = "k" & $r.rand(0 .. 3)
proc randVal(r: var Rand): string = "v" & $r.rand(0 .. 5)

proc randomEvents(r: var Rand, n: int): seq[Event] =
  var ids: seq[EventId]
  for i in 0 ..< n:
    var parents: seq[EventId]
    # reference a random subset of earlier events as causal parents
    for pid in ids:
      if r.rand(0 .. 2) == 0: parents.add pid
    let e = Event(parents: parents, key: randKey(r), value: randVal(r))
    result.add e
    ids.add eventId(e)

var r = initRand(0xD7C449)
var allIdem = true
for trial in 0 ..< 200:
  let n = r.rand(1 .. 8)
  let events = randomEvents(r, n)
  let once = stateDigest(reduce(events))
  # Duplicate an arbitrary member once, and twice.
  let e = events[r.rand(0 ..< events.len)]
  let dup1 = stateDigest(reduce(events & @[e]))
  let dup2 = stateDigest(reduce(events & @[e, e]))
  let idem = (once == dup1) and (once == dup2)
  if not idem: allIdem = false
  echo "{\"idempotent\": ", (if idem: "true" else: "false"), "}"

doAssert allIdem, "reducing a duplicated event drifted state beyond applying it once"
