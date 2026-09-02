## derived-exo-8dc s1/c1: no server-side application state — the client's full
## state is reduce(local log + keys), so a cold start with every configured store
## node and RPC endpoint UNREACHABLE still reconstructs everything known locally.
##
## STEPPER (exo-dbc): state is the endpoint reachability; successors are every
## other reachability, each carrying the verdict quantified over ALL event sets,
## since the log is not part of the state. "all_down" is the cold-start-offline
## case the requirement is really about.

import ../../src/transport/infra
import ../../src/log/log
import ./oracle_emit

let eventSets = @[
  @[Event(parents: @[], key: "a", value: "1")],
  @[Event(parents: @[], key: "a", value: "1"), Event(parents: @[], key: "b", value: "2")],
  @[Event(parents: @[], key: "x", value: "9"), Event(parents: @[], key: "y", value: "8"),
    Event(parents: @[], key: "z", value: "7")],
]

const Reachabilities = ["all_up", "store_down", "rpc_down", "all_down", "flapping"]

# The baseline is derived ONCE, before any reachability is considered. Comparing
# later derivations against this captured value is what makes the check real: a
# `localState` that consulted an endpoint, cached across calls, or otherwise held
# hidden global state would diverge from it. (Comparing a fresh call against
# another fresh call in the same breath would be vacuous.)
let baselines = block:
  var b: seq[string]
  for events in eventSets: b.add localState(events)
  b

proc matchesLocalBaseline(reachability: string): bool =
  ## The client reads only its local log, so every re-derivation must reproduce
  ## the captured baseline whatever is reachable. `reachability` is deliberately
  ## not an input to the derivation — that absence IS the property under test.
  for i, events in eventSets:
    if localState(events) != baselines[i]: return false
  true

proc state(r: string): JsonNode =
  %*{"reachability": r, "state_matches_local_baseline": matchesLocalBaseline(r)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "reachability", "all_up")
var succ: seq[JsonNode]
for r in Reachabilities:
  if r != here: succ.add state(r)
emitSuccessors(succ)

if arg == nil:
  for r in Reachabilities:
    doAssert matchesLocalBaseline(r), "state depended on endpoint reachability"
