## derived-exo-8dc s2/c2: every endpoint the client will contact is enumerable and
## shown before traffic; no destination is reachable that isn't in that visible
## list.
##
## STEPPER (exo-dbc): state is the operation/path (`op`); successors are every
## other path, each carrying the disclosure verdict quantified over ALL configs —
## the config is not part of the state, so a path's verdict must hold for every
## one of them.

import ../../src/transport/infra
import std/sets
import ./oracle_emit

let configs = @[
  newConfig(@["store.test", "rpc.test"]),
  newConfig(@["s1", "s2", "rpc"]),
  newConfig(@[]),
]

const OpNames = ["startup", "fetch", "publish", "error", "crash", "shutdown", "idle"]
const Paths = [pStartup, pFetch, pPublish, pError, pCrash, pShutdown, pIdle]

proc pathOf(op: string): Path =
  let i = OpNames.find(op)
  doAssert i >= 0, "unknown op: " & op
  Paths[i]

proc allDisclosed(op: string): bool =
  ## Every dial on this path, under every config, is in that config's visible list.
  for cfg in configs:
    let visible = toHashSet(cfg.visibleList())
    for d in dialsOnPath(cfg, pathOf(op)):
      if d notin visible: return false
  true

proc state(op: string): JsonNode =
  %*{"op": op, "all_dials_disclosed": allDisclosed(op)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "op", "idle")
var succ: seq[JsonNode]
for op in OpNames:
  if op != here: succ.add state(op)
emitSuccessors(succ)

if arg == nil:
  for op in OpNames:
    doAssert allDisclosed(op), "the client dialed a destination outside the visible list"
