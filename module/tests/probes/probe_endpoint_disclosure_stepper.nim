## derived-exo-8dc s2/c2: every endpoint the client will contact is enumerable and
## shown before traffic; no destination is reachable that isn't in that visible
## list. Stepper over (path × config): every dial on every path is a member of the
## visible list. Emits {"path": "...", "all_dials_disclosed": ...}.
import ../../src/transport/infra
import std/sets

let configs = @[
  newConfig(@["store.test", "rpc.test"]),
  newConfig(@["s1", "s2", "rpc"]),
  newConfig(@[]),
]
var allOk = true
var states = 0
for cfg in configs:
  let visible = toHashSet(cfg.visibleList())
  for path in [pStartup, pFetch, pPublish, pError, pCrash, pShutdown, pIdle]:
    if states >= 40: break
    var disclosed = true
    for d in dialsOnPath(cfg, path):
      if d notin visible: disclosed = false
    if not disclosed: allOk = false
    echo "{\"path\": \"", $path, "\", \"all_dials_disclosed\": ",
         (if disclosed: "true" else: "false"), "}"
    inc states
doAssert allOk, "the client dialed a destination outside the visible list"
