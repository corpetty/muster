## derived-exo-8e7 s3/c3: the re-derive-or-refuse check cannot be bypassed by any
## configuration flag, plugin, or user preference — it is unconditional core
## behavior. Stepper over the reachable config space (toggling each setting from
## the default); a mismatched materialization is refused at every reachable state.
## A config surface that quietly suppressed the check anywhere would surface here
## as a counterexample. Emits {"config_id": "...", "mismatch_refused": ...}.

import ../../src/dcbor/dcbor
import ../../src/drivers/driver
import ../../src/intents/materialization

let drv = newStubDriver()
let e = Effect(schemaId: "muster.effect.transfer.v1",
               fields: @[("amount", cbUint(100'u64)), ("to", cbText("alice"))])
# A materialization that does NOT match the effect's derivation — must be refused
# no matter how the config is set.
let honest = canonicalize(drv, e)
var mismatched = honest
mismatched.bytes.add 0xAA'u8

var allRefused = true
var cid = 0
for skip in [false, true]:
  for prefs in ["", "auto-sign", "trust-driver"]:
    for pluginSet in @[@[], @["balance"], @["balance", "decision"], @["evil-bypass"]]:
      let cfg = Config(skipReviewRequested: skip, plugins: pluginSet, userPreference: prefs)
      let refused = signProposal(cfg, drv, e, mismatched) == soRefused
      if not refused: allRefused = false
      echo "{\"config_id\": \"skip=", skip, ",pref=", prefs, ",plugins=", pluginSet.len,
           "\", \"mismatch_refused\": ", (if refused: "true" else: "false"), "}"
      inc cid

doAssert allRefused, "a config value bypassed the unconditional materialization check"
