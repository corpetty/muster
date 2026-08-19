## derived-exo-f60 s5/c5: anonymity covers everything retained, not just what's
## shown. Walk the ENTIRE declared retention schema — log records, reduced state,
## state events, cache, export, crash dump — and no reachable field is derived
## from signer identity (and no signature-valued field is member-bound; the
## anonymous client retains none). Emits
## {"record_type": "...", "field": "...", "identity_derived_field": ...}.

import ../../src/intents/anon_state

var allClean = true
for f in retentionSchema():
  if f.identityDerived: allClean = false
  echo "{\"record_type\": \"", f.recordType, "\", \"field\": \"", f.field,
       "\", \"identity_derived_field\": ", (if f.identityDerived: "true" else: "false"), "}"

doAssert allClean, "a retained field is derived from signer identity"
