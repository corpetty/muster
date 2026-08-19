## derived-exo-f60 s4/c4: the sequence and content of emitted state-update events
## — logical clock values, ordering, batching — are independent of signer
## identity (no wall-clock claim). Stepper over signer assignments: the logical
## event sequence must match the baseline at every assignment. Emits
## {"assignment": "...", "batching": "immediate",
##  "logical_event_sequence_matches_baseline": ...}.

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/algorithm

let contribs = @[@[1'u8], @[2'u8], @[3'u8], @[4'u8]]
let signers = @["alice", "bob", "carol", "dave"]

proc eventRepr(assignment: seq[int]): string =
  var co = newAnonCoordination(total = contribs.len)
  for i in 0 ..< contribs.len:
    co.ingest(Arrival(contribution: Contribution(bytes: contribs[i]),
                      signer: signers[assignment[i]]))
  result = ""
  for e in co.events:
    result.add $e.logicalClock & ":" & $e.filled & "/" & $e.total & ";"

var perm = @[0, 1, 2, 3]
sort(perm)
let baseline = eventRepr(perm)
var allMatch = true
while true:
  let m = eventRepr(perm) == baseline
  if not m: allMatch = false
  echo "{\"assignment\": \"", perm, "\", \"batching\": \"immediate\", ",
       "\"logical_event_sequence_matches_baseline\": ", (if m: "true" else: "false"), "}"
  if not nextPermutation(perm): break

doAssert allMatch, "logical state-update sequence varied with signer identity"
