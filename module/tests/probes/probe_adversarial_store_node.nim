## derived-exo-8dc s4/c4: nothing a store node or RPC endpoint returns is accepted
## on its authority — every datum is verified locally before it can change state.
##
## STEPPER (exo-dbc): state is the node's behavior; successors are every other
## behavior, each carrying the verdict quantified over BOTH local-verification
## outcomes, since the outcome is not part of the state. A lying or omitting node
## must degrade availability, never integrity.

import ../../src/transport/infra
import ./oracle_emit

const Behaviors = ["honest", "tampered", "omitting", "replaying", "garbage"]

proc acceptsUnverified(behavior: string): bool =
  ## Acceptance depends ONLY on local verification, never on the node's claim —
  ## so no behavior may yield an accepted-but-unverified datum.
  for verifiedLocally in [true, false]:
    if acceptFromNode(verifiedLocally) and not verifiedLocally: return true
  false

proc state(behavior: string): JsonNode =
  %*{"adversary": behavior, "accepted_unverified": acceptsUnverified(behavior)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "adversary", "honest")
var succ: seq[JsonNode]
for b in Behaviors:
  if b != here: succ.add state(b)
emitSuccessors(succ)

if arg == nil:
  for b in Behaviors:
    doAssert not acceptsUnverified(b), "an unverified datum from a node was accepted"
