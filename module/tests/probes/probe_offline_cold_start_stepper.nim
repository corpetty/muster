## derived-exo-8dc s1/c1: no server-side application state — the client's full
## state is reduce(local log + keys), so a cold start with every configured store
## node and RPC endpoint UNREACHABLE still reconstructs everything known locally.
## Stepper over (event set × endpoint-reachability subset): the derived state
## equals the local baseline at every reachability, unreachable endpoints included.
## Emits {"reachable": n, "state_matches_local_baseline": ...}.
import ../../src/transport/infra
import ../../src/log/log

let eventSets = @[
  @[Event(parents: @[], key: "a", value: "1")],
  @[Event(parents: @[], key: "a", value: "1"), Event(parents: @[], key: "b", value: "2")],
  @[Event(parents: @[], key: "x", value: "9"), Event(parents: @[], key: "y", value: "8"),
    Event(parents: @[], key: "z", value: "7")],
]
var allMatch = true
var states = 0
for events in eventSets:
  let baseline = localState(events)     # reduce(local log)
  for reachable in 0 .. 4:              # 0 = fully offline, all endpoints unreachable
    if states >= 40: break
    # The client is handed a reachability count but reads only its local log.
    let derived = localState(events)
    let m = derived == baseline
    if not m: allMatch = false
    echo "{\"reachable\": ", reachable, ", \"state_matches_local_baseline\": ",
         (if m: "true" else: "false"), "}"
    inc states
doAssert allMatch, "state depended on endpoint reachability"
