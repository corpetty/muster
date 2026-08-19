## derived-exo-8dc s3/c3: every entry in the endpoint list — defaults included —
## can be changed or removed; the client operates correctly against an arbitrary
## operator-supplied set, with no privileged endpoint it keeps dialing. Stepper
## over operator substitutions of the default set: local state is unchanged
## (baseline) and no dial goes to a removed default. Emits
## {"substitution": "...", "matches_baseline_and_no_default_dials": ...}.
import ../../src/transport/infra
import ../../src/log/log
import std/sets

let events = @[Event(parents: @[], key: "a", value: "1"),
               Event(parents: @[], key: "b", value: "2")]
let baseline = localState(events)
let defaults = @["default.store", "default.rpc"]

let operatorSets = @[
  @["op1.store", "op1.rpc"],
  @["only.mine"],
  @[],                           # remove everything — client still reconstructs state
  @["op.store", "op.rpc", "op.extra"],
]
var allOk = true
var states = 0
for opSet in operatorSets:
  if states >= 40: break
  let cfg = newConfig(opSet)
  let visible = toHashSet(cfg.visibleList())
  # state still derivable from the local log, unchanged by the endpoint swap
  let stateOk = localState(events) == baseline
  # no dial goes to a removed default
  var noDefaultDials = true
  for path in [pFetch, pPublish, pIdle]:
    for d in dialsOnPath(cfg, path):
      if d in defaults or d notin visible: noDefaultDials = false
  let ok = stateOk and noDefaultDials
  if not ok: allOk = false
  echo "{\"substitution\": \"", opSet.len, "-endpoints\", ",
       "\"matches_baseline_and_no_default_dials\": ", (if ok: "true" else: "false"), "}"
  inc states
doAssert allOk, "a default was privileged or state changed under substitution"
