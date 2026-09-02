## derived-exo-f60 s4/c4: the sequence and content of emitted state-update events
## — logical clock values, ordering, batching — are independent of signer
## identity (no wall-clock claim). Stepper over signer assignments: the logical
## event sequence must match the baseline at every assignment. STEPPER (exo-dbc): state is the signer assignment (batching is a single
## declared mode); successors are the assignments one transposition away.

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/algorithm
import ./oracle_emit

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

let baseline = eventRepr(@[0, 1, 2, 3])

proc state(p: seq[int]): JsonNode =
  %*{"assignment": permString(p), "batching": "immediate",
     "logical_event_sequence_matches_baseline": eventRepr(p) == baseline}

let here = parsePerm(oracleStateStr(oracleStateArg(), "assignment", "identity"), contribs.len)
var succ: seq[JsonNode]
for q in swapNeighbours(here): succ.add state(q)
emitSuccessors(succ)

if oracleStateArg() == nil:
  var perm = @[0, 1, 2, 3]
  sort(perm)
  while true:
    doAssert eventRepr(perm) == baseline,
      "logical state-update sequence varied with signer identity"
    if not nextPermutation(perm): break
