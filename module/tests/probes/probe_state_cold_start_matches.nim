## derived-exo-548 s1/c1: state derived by cold-start replay of the log always
## equals state maintained incrementally as events arrive — nothing lives outside
## the log. Across randomized arrival sequences, the incrementally-ingested log's
## state equals a fresh reduce() of the persisted event set, and equals the same
## reduce() from the reversed arrival order. Emits {"matches": ...} per trial.

import ../../src/log/log
import std/random
import ./oracle_emit

var obs: seq[JsonNode]

proc randomEvents(r: var Rand, n: int): seq[Event] =
  var ids: seq[EventId]
  for i in 0 ..< n:
    var parents: seq[EventId]
    for pid in ids:
      if r.rand(0 .. 1) == 0: parents.add pid
    let e = Event(parents: parents, key: "k" & $r.rand(0 .. 4), value: "v" & $r.rand(0 .. 6))
    result.add e
    ids.add eventId(e)

var r = initRand(0x548C0)
var allMatch = true
for trial in 0 ..< 200:
  let events = randomEvents(r, r.rand(1 .. 10))

  # Incremental: ingest in arrival order; state() is reduce(persisted set).
  var live: Log
  for e in events: live.ingest(e)
  let incremental = stateDigest(live.state())

  # Cold start: rebuild from the persisted event set alone.
  let coldStart = stateDigest(reduce(live.allEvents()))

  # Reversed arrival must land the same place (delivery-order independence).
  var rev: Log
  for i in countdown(events.high, 0): rev.ingest(events[i])
  let reversed = stateDigest(rev.state())

  let matches = (incremental == coldStart) and (incremental == reversed)
  if not matches: allMatch = false
  obs.add flag("matches", matches)

emitTrials(obs)
doAssert allMatch, "cold-start replay diverged from incrementally-maintained state"
