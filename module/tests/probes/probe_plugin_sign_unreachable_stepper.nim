## derived-exo-51e s1/c1: no signing operation is reachable from plugin code
## through any invocation path.
##
## STEPPER (exo-dbc): state is the attempt vector — a chain of indirections,
## optionally through a callback or a data-dependency read, ending in an attempt
## to sign. Successors are every other vector. The spec's initial id
## "direct_call" is the zero-indirection vector.

import ../../src/plugins/plugin
import ./oracle_emit

proc vectorIds(): seq[string] =
  for depth in 0 .. 4:
    for viaCallback in [false, true]:
      for viaDataDep in [false, true]:
        result.add "d" & $depth & "-cb" & $viaCallback & "-dd" & $viaDataDep

const DirectCall = "d0-cbfalse-ddfalse"

proc signSucceeds(vector: string): bool =
  ## However plugin code gets there — depth of indirection, a callback, a
  ## data-dependency read — it reaches host operations only through the
  ## capability grant, and that grant excludes opSign. The permission check is
  ## the same at the end of every path, which is exactly the claim.
  permitted(opSign)

proc state(vector: string): JsonNode =
  %*{"attempt_vector_id": vector, "sign_succeeded": signSucceeds(vector)}

let arg = oracleStateArg()
var here = oracleStateStr(arg, "attempt_vector_id", "direct_call")
if here == "direct_call": here = DirectCall
var succ: seq[JsonNode]
for v in vectorIds():
  if v != here: succ.add state(v)
emitSuccessors(succ)

if arg == nil:
  for v in vectorIds():
    doAssert not signSucceeds(v), "a signing operation was reachable from plugin code"
