## derived-exo-8dc s3/c3: every entry in the endpoint list — defaults included —
## can be changed or removed; the client operates correctly against an arbitrary
## operator-supplied set, with no privileged endpoint it keeps dialing.
##
## STEPPER (exo-dbc): state is the endpoint set in force; successors are every
## other set, including the shipped defaults and the empty set. Each carries both
## halves of the verdict: local state still reconstructs, and no dial escapes the
## set currently in force.

import ../../src/transport/infra
import ../../src/log/log
import std/sets
import ./oracle_emit

let events = @[Event(parents: @[], key: "a", value: "1"),
               Event(parents: @[], key: "b", value: "2")]
let baseline = localState(events)

const Sets = ["shipped_defaults", "operator_two", "operator_one", "empty", "operator_three"]

proc endpointsOf(name: string): seq[string] =
  case name
  of "shipped_defaults": @["default.store", "default.rpc"]
  of "operator_two": @["op1.store", "op1.rpc"]
  of "operator_one": @["only.mine"]
  of "empty": @[]                       # remove everything — state still reconstructs
  of "operator_three": @["op.store", "op.rpc", "op.extra"]
  else: raiseAssert "unknown endpoint set: " & name

proc substitutionHolds(name: string): bool =
  let cfg = newConfig(endpointsOf(name))
  let visible = toHashSet(cfg.visibleList())
  # State is still derivable from the local log, unchanged by the endpoint swap.
  if localState(events) != baseline: return false
  # No dial escapes the set currently in force. This subsumes the privileged-
  # default leak: a client still dialing `default.store` under an operator set
  # that does not contain it dials outside `visible` and is caught here. Testing
  # membership of the shipped defaults directly would instead flag the operator
  # who legitimately KEEPS a default.
  for path in [pFetch, pPublish, pIdle]:
    for d in dialsOnPath(cfg, path):
      if d notin visible: return false
  true

proc state(name: string): JsonNode =
  %*{"endpoint_set": name, "matches_baseline_and_no_default_dials": substitutionHolds(name)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "endpoint_set", "shipped_defaults")
var succ: seq[JsonNode]
for s in Sets:
  if s != here: succ.add state(s)
emitSuccessors(succ)

if arg == nil:
  for s in Sets:
    doAssert substitutionHolds(s), "a default was privileged or state changed under substitution"
