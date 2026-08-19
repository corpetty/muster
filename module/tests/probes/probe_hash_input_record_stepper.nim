## derived-exo-449 s1/c1: every signing-path hash goes through the typed,
## domain-separated hash-input record — never ad-hoc concatenation.
##
## Stepper over hash-input record shapes (domain tag × field sets). At each state
## the module's encodeHashInput is compared to an INDEPENDENTLY assembled
## reference for the declared framing ([domain, {fields}] in dCBOR). An encoder
## that concatenated domain and content bytes ad hoc — instead of framing them as
## the structured record — would diverge from the reference and fail. Emits
## {"record_shape": "...", "matches_reference_encoder": ...}.

import ../../src/dcbor/dcbor
import ../../src/hashing/hash_input

# Independent reference for the hash-input framing, assembled here rather than
# calling the module's encodeHashInput — so agreement is evidence the module uses
# this structured scheme, not something that merely looks similar for one input.
proc referenceEncode(domain: string, fields: seq[(string, CborValue)]): seq[byte] =
  var arr = @[cbText(domain)]
  var pairs: seq[(CborValue, CborValue)]
  for (k, v) in fields: pairs.add (cbText(k), v)
  arr.add cbMap(pairs)
  encode(cbArray(arr))

let domains = @["", "muster.event.transfer.v1", "muster.event.membership.v1", "x"]
let fieldSets: seq[seq[(string, CborValue)]] = @[
  @[],
  @[("amount", cbUint(100'u64))],
  @[("amount", cbUint(100'u64)), ("to", cbText("alice"))],
  @[("to", cbText("alice")), ("amount", cbUint(100'u64)), ("ok", cbBool(true))],
  @[("nested", cbArray(@[cbUint(1'u64), cbText("q")])), ("n", cbInt(-5))],
]

var allMatch = true
var shape = 0
for d in domains:
  for fs in fieldSets:
    let hi = hashInput(d, fs)
    let matches = encodeHashInput(hi) == referenceEncode(d, fs)
    if not matches: allMatch = false
    echo "{\"record_shape\": \"", shape, "\", \"matches_reference_encoder\": ",
         (if matches: "true" else: "false"), "}"
    inc shape

doAssert allMatch, "hash-input encoding diverged from the structured-record reference"
