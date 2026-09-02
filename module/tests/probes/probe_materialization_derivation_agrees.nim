## derived-exo-8e7 s1/c1: given a reviewed effect, the client independently
## computes what the materialization should be — and that derivation is real,
## reproducing an independently-assembled reference for the same scheme (not a
## stub that echoes whatever it was handed). Emits one `agrees` observation per trial.

import ../../src/dcbor/dcbor
import ../../src/drivers/driver
import ../../src/intents/materialization
import std/random
import ./oracle_emit

# Independent reference for the canonicalization framing, assembled here rather
# than via canonicalize() — so agreement proves canonicalize() does the framing
# work, not that it was stubbed to match its input.
proc referenceBytes(domain, schemaId: string, fields: seq[(string, CborValue)]): seq[byte] =
  var pairs: seq[(CborValue, CborValue)]
  for (k, v) in fields: pairs.add (cbText(k), v)
  encode(cbArray(@[cbText(domain), cbText(schemaId), cbMap(pairs)]))

var r = initRand(0x8E7)
var allAgree = true
var obs: seq[JsonNode]
for trial in 0 ..< 200:
  let domain = ["muster.stub.v1", "d2", "muster.safe.v1"][r.rand(0 .. 2)]
  let drv = newStubDriver(domain = domain)
  var fields: seq[(string, CborValue)]
  for f in 0 ..< r.rand(0 .. 4):
    fields.add ("f" & $f, cbUint(uint64(r.rand(0 .. 1000))))
  let e = Effect(schemaId: "muster.effect.transfer.v1", fields: fields)

  # The driver's honest materialization and the client's independent derivation
  # are both canonicalize(); agreement with the independent reference proves the
  # derivation path actually computes rather than passing a value through.
  let derived = canonicalize(drv, e)
  let agrees = derived.bytes == referenceBytes(domain, e.schemaId, fields)
  if not agrees: allAgree = false
  obs.add flag("agrees", agrees)

emitTrials(obs)
doAssert allAgree, "independent materialization derivation did not reproduce the reference"
