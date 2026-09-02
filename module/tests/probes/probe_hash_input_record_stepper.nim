## derived-exo-449 s1/c1: every signing-path hash goes through the typed,
## domain-separated hash-input record — never ad-hoc concatenation.
##
## STEPPER (exo-dbc): state is the record shape "d<i>-f<j>" over (domain tag ×
## field set); successors are every other shape. At each, the module's
## encodeHashInput is compared to an INDEPENDENTLY assembled reference for the
## declared framing ([domain, {fields}] in dCBOR) — an encoder that concatenated
## domain and content ad hoc instead of framing them as the structured record
## would diverge. The spec's initial id "minimal" is the empty domain with no
## fields.

import ../../src/dcbor/dcbor
import ../../src/hashing/hash_input
import std/strutils
import ./oracle_emit

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

const Minimal = "d0-f0"

proc shapeIds(): seq[string] =
  for i in 0 ..< domains.len:
    for j in 0 ..< fieldSets.len:
      result.add "d" & $i & "-f" & $j

proc matchesReference(id: string): bool =
  let parts = id.split('-')
  doAssert parts.len == 2, "malformed record_shape: " & id
  let d = domains[parseInt(parts[0][1 .. ^1])]
  let fs = fieldSets[parseInt(parts[1][1 .. ^1])]
  encodeHashInput(hashInput(d, fs)) == referenceEncode(d, fs)

proc state(id: string): JsonNode =
  %*{"record_shape": id, "matches_reference_encoder": matchesReference(id)}

let arg = oracleStateArg()
var here = oracleStateStr(arg, "record_shape", "minimal")
if here == "minimal": here = Minimal
var succ: seq[JsonNode]
for id in shapeIds():
  if id != here: succ.add state(id)
emitSuccessors(succ)

if arg == nil:
  for id in shapeIds():
    doAssert matchesReference(id),
      "hash-input encoding diverged from the structured-record reference"
