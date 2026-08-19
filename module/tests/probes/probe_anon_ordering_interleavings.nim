## derived-exo-f60 s3/c3: the order contributions appear in state and in the log
## is a function of arrival and log position only — never of who signed. Stepper
## over (arrival order × signer assignment): for a fixed arrival order, permuting
## the signers leaves the observable order unchanged. Emits
## {"interleaving": "...", "ordering_signer_independent": ...}.

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/algorithm

let contribs = @[@[10'u8], @[20'u8], @[30'u8]]
let signers = @["alice", "bob", "carol"]

proc orderRepr(arrival, signerAssign: seq[int]): string =
  var co = newAnonCoordination(total = contribs.len)
  for k in 0 ..< arrival.len:
    co.ingest(Arrival(contribution: Contribution(bytes: contribs[arrival[k]]),
                      signer: signers[signerAssign[k]]))
  result = ""
  for c in co.state.contributions:
    for b in c: result.add $b
    result.add ">"
  for r in co.log: result.add $r.logPos & ","

var allIndep = true
var arrival = @[0, 1, 2]
sort(arrival)
while true:
  var sid = @[0, 1, 2]
  sort(sid)
  let baseline = orderRepr(arrival, sid)   # identity signer assignment, this arrival
  while true:
    let m = orderRepr(arrival, sid) == baseline
    if not m: allIndep = false
    echo "{\"interleaving\": \"", arrival, "/sig", sid,
         "\", \"ordering_signer_independent\": ", (if m: "true" else: "false"), "}"
    if not nextPermutation(sid): break
  if not nextPermutation(arrival): break

doAssert allIndep, "observable order depended on which signer filled a slot"
