## derived-exo-f60 s3/c3: the order contributions appear in state and in the log
## is a function of arrival and log position only — never of who signed. Stepper
## over (arrival order × signer assignment): for a fixed arrival order, permuting
## the signers leaves the observable order unchanged. STEPPER (exo-dbc): state is the (arrival, signer) interleaving encoded
## "arrival/signers"; successors are one transposition away in either
## permutation. The spec's initial id "arrival_order" is the identity of both.

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/algorithm
import ./oracle_emit
import std/strutils

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

proc independent(arrival, sid: seq[int]): bool =
  ## For THIS arrival order, does permuting the signers leave the order alone?
  orderRepr(arrival, sid) == orderRepr(arrival, @[0, 1, 2])

proc state(arrival, sid: seq[int]): JsonNode =
  %*{"interleaving": permString(arrival) & "/" & permString(sid),
     "ordering_signer_independent": independent(arrival, sid)}

let arg = oracleStateArg()
let raw = oracleStateStr(arg, "interleaving", "arrival_order")
let parts = raw.split('/')
let hereArrival = parsePerm(if parts.len == 2: parts[0] else: "", contribs.len)
let hereSid = parsePerm(if parts.len == 2: parts[1] else: "", contribs.len)

var succ: seq[JsonNode]
for a in swapNeighbours(hereArrival): succ.add state(a, hereSid)
for sg in swapNeighbours(hereSid): succ.add state(hereArrival, sg)
emitSuccessors(succ)

if arg == nil:
  var arrival = @[0, 1, 2]
  sort(arrival)
  while true:
    var sid = @[0, 1, 2]
    sort(sid)
    while true:
      doAssert independent(arrival, sid),
        "observable order depended on which signer filled a slot"
      if not nextPermutation(sid): break
    if not nextPermutation(arrival): break
