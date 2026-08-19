## derived-exo-8dc s5/c5: no telemetry, no phone-home. On every code path —
## including error and crash — the client originates no request to any destination
## outside the visible list. Metamorphic: under input transforms (more events,
## error injection, crash, shutdown) the set of outbound destinations never grows
## beyond the visible list — no analytics/crash-reporting/beacon appears. Emits
## {"transform": "...", "outbound_conserved": ...}.
import ../../src/transport/infra
import std/sets

let cfg = newConfig(@["store.test", "rpc.test"])
let visible = toHashSet(cfg.visibleList())

# The metamorphic relation: for any path (the "transform"), the outbound dial set
# is a subset of the visible list. Error/crash/shutdown add no new destination.
var allConserved = true
for path in [pStartup, pFetch, pPublish, pError, pCrash, pShutdown, pIdle]:
  let dials = toHashSet(dialsOnPath(cfg, path))
  let conserved = dials <= visible          # subset — no destination outside the list
  if not conserved: allConserved = false
  echo "{\"transform\": \"", $path, "\", \"outbound_conserved\": ",
       (if conserved: "true" else: "false"), "}"
doAssert allConserved, "an outbound request escaped the visible list (telemetry/beacon)"
