## derived-exo-8dc s5/c5: no telemetry, no phone-home. On every code path —
## including error and crash — the client originates no request to any
## destination outside the visible list.
##
## METAMORPHIC (exo-dbc), relation_class `conservation`: the oracle sums the
## emitted `flows` and requires the total to be zero. The closed system here is
## "outbound dials are wholly accounted for by the visible list": each path
## contributes +(dials it makes) and −(those dials that are visible). Every dial
## therefore cancels, and the sum is exactly the number of dials that ESCAPED the
## visible list — zero iff no analytics, crash-reporting, or beacon destination
## was ever contacted. An added phone-home on any path, error and crash included,
## makes the sum positive.

import ../../src/transport/infra
import std/sets
import ./oracle_emit

let cfg = newConfig(@["store.test", "rpc.test"])
let visible = toHashSet(cfg.visibleList())

var flows: seq[int]
var escaped = 0
for path in [pStartup, pFetch, pPublish, pError, pCrash, pShutdown, pIdle]:
  let dials = dialsOnPath(cfg, path)
  var accounted = 0
  for d in dials:
    if d in visible: inc accounted
  flows.add dials.len          # everything the path sent out
  flows.add -accounted         # everything the visible list accounts for
  escaped += dials.len - accounted

emitMeasurement(%*{"flows": flows})

doAssert escaped == 0, "an outbound request escaped the visible list (telemetry/beacon)"
