## The card renders an intent only from a schema it recognizes (exo-1ec.3): an unknown
## one gets a named "schema unknown" state and no Approve. So every effect a BUILT driver
## canonicalizes must be recognized by the rendering gate (effectSchema), under the same
## schema id the driver signs over — or that family's cards can never be approved from the
## UI. Held over every generated (kind, variant) (module/tools/action_corpus.nim), so a new
## effect kind cannot ship its driver without its card. Found by the action-atlas
## authoring: the LEZ-FROST `lez-call` effect rendered as "schema unknown".
## Needs the full closure (run-suite.sh supplies it).

import std/[json, strutils]
import ../tools/action_corpus
import ../src/intents/materialization
import ../src/coordination/intent_events

var checked = 0
for (kind, variant) in Variants:
  let key = kind & "/" & variant
  let ej = proposedEffectJson(key)
  let (id, known) = effectSchema(ej)
  let signed = effectFromJson(ej).schemaId
  doAssert known, key & ": the card does not recognize " & id & " — its Approve is hidden"
  doAssert id == signed, key & ": the card names " & id & ", the driver signs over " & signed
  inc checked
echo "1. every built (kind, variant)'s effect is recognized by the card, under its signed schema id (", checked, ") OK"
echo "schema_coverage_test: all OK"
