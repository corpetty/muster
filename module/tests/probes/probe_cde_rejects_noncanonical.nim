## derived-exo-d7c s4/c4: the encoder never emits indefinite-length markers or
## floats — it REJECTS such inputs rather than coercing them to some encoding.
## Emits {"input_rejected": ...} per input and fails if any is accepted, whether
## the offending value is top-level or nested inside an array/map.

import ../../src/dcbor/dcbor
import ./oracle_emit

var allRejected = true
var obs: seq[JsonNode]
proc expectReject(v: CborValue, what: string) =
  var rejected = false
  try:
    discard encode(v)
  except CborError:
    rejected = true
  if not rejected: allRejected = false
  obs.add %*{"input_rejected": rejected, "case": what}

# Floats — every width, special values, and nested positions.
expectReject(cbFloat(0.0), "float_zero")
expectReject(cbFloat(1.5), "float_val")
expectReject(cbFloat(-3.14), "float_neg")
expectReject(cbFloat(Inf), "float_inf")
expectReject(cbFloat(NaN), "float_nan")
expectReject(cbArray(@[cbUint(1'u64), cbFloat(2.0)]), "float_in_array")
expectReject(cbMap(@[(cbText("k"), cbFloat(1.0))]), "float_in_map_value")
expectReject(cbMap(@[(cbFloat(1.0), cbText("v"))]), "float_in_map_key")

# Indefinite-length markers.
expectReject(cbIndefinite(), "indefinite_top")
expectReject(cbArray(@[cbIndefinite()]), "indefinite_in_array")

emitTrials(obs)
doAssert allRejected, "a non-canonical input (float or indefinite) was accepted"
