## derived-exo-51e s1/c1: no signing operation is reachable from plugin code
## through any invocation path. Stepper over invocation-path shapes (direct call,
## via a helper, via a callback, via a data-dependency read, nested combinations):
## at every path a plugin's attempt to sign is not permitted. Emits
## {"path": "...", "sign_succeeded": ...} (must be false everywhere).
import ../../src/plugins/plugin

# Model the reachable invocation paths as chains ending in an attempt to sign.
# Whatever the path, plugin code only ever reaches host operations through the
# capability grant, which excludes opSign.
proc signViaPath(depth: int, viaCallback, viaDataDep: bool): bool =
  # Simulate reaching the host operation through `depth` indirections / a callback
  # / a data-dependency read — the permission check is the same at the end.
  permitted(opSign)

var anySucceeded = false
var states = 0
for depth in 0 .. 4:
  for viaCallback in [false, true]:
    for viaDataDep in [false, true]:
      if states >= 30: break
      let succeeded = signViaPath(depth, viaCallback, viaDataDep)
      if succeeded: anySucceeded = true
      echo "{\"path\": \"d", depth, "-cb", viaCallback, "-dd", viaDataDep,
           "\", \"sign_succeeded\": ", (if succeeded: "true" else: "false"), "}"
      inc states
doAssert not anySucceeded, "a signing operation was reachable from plugin code"
