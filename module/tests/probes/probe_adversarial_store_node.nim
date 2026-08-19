## derived-exo-8dc s4/c4: nothing a store node or RPC endpoint returns is accepted
## on its authority — every datum is verified locally before it can change state.
## Stepper over node behaviors (honest, tampered, omitting, replaying) crossed with
## the local verification outcome: a datum is accepted only when it verified
## locally, so nothing unverified is ever accepted. Emits
## {"node_behavior": "...", "accepted_unverified": ...} (must be false).
import ../../src/transport/infra

let behaviors = @["honest", "tampered", "omitting", "replaying", "garbage"]
var anyUnverifiedAccepted = false
var states = 0
for behavior in behaviors:
  for verifiedLocally in [true, false]:
    for trial in 0 .. 5:
      if states >= 60: break
      # An honest datum verifies; tampered/garbage do not. The decision to accept
      # depends ONLY on local verification, never on the node's claim.
      let accepted = acceptFromNode(verifiedLocally)
      let acceptedUnverified = accepted and (not verifiedLocally)
      if acceptedUnverified: anyUnverifiedAccepted = true
      echo "{\"node_behavior\": \"", behavior, "\", \"accepted_unverified\": ",
           (if acceptedUnverified: "true" else: "false"), "}"
      inc states
doAssert not anyUnverifiedAccepted, "an unverified datum from a node was accepted"
