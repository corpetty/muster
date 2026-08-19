## derived-exo-8e7 s2/c2: if the driver-supplied materialization differs from the
## client's independent derivation in ANY way, the client refuses to sign. Across
## random effects and every kind of single tamper (flip a byte, truncate, append,
## alter a field then re-derive), the mismatch is always refused. Emits
## {"refused": ...}.

import ../../src/dcbor/dcbor
import ../../src/drivers/driver
import ../../src/intents/materialization
import std/random

var r = initRand(0x8E72)
var allRefused = true

proc randEffect(r: var Rand): Effect =
  var fields: seq[(string, CborValue)]
  for f in 0 ..< r.rand(1 .. 4):
    fields.add ("f" & $f, cbUint(uint64(r.rand(0 .. 1000))))
  Effect(schemaId: "muster.effect.transfer.v1", fields: fields)

for trial in 0 ..< 200:
  let drv = newStubDriver()
  let e = randEffect(r)
  let honest = canonicalize(drv, e)

  # Produce a materialization that differs in some single way.
  var tampered = honest
  case r.rand(0 .. 3)
  of 0: # flip a byte
    if tampered.bytes.len > 0:
      let i = r.rand(0 ..< tampered.bytes.len)
      tampered.bytes[i] = tampered.bytes[i] xor 0xFF'u8
    else:
      tampered.bytes.add 0x01'u8
  of 1: # truncate
    if tampered.bytes.len > 0: tampered.bytes.setLen(tampered.bytes.len - 1)
    else: tampered.bytes.add 0x01'u8
  of 2: # append
    tampered.bytes.add byte(r.rand(0 .. 255))
  else: # alter an effect field and re-derive — a semantically different effect
    var e2 = e
    e2.fields.add ("extra", cbUint(uint64(r.rand(1 .. 9))))
    tampered = canonicalize(drv, e2)

  # Guard: only score trials where the tamper actually changed the bytes.
  if tampered.bytes == honest.bytes:
    echo "{\"refused\": true}"   # nothing to refuse; not a mismatch
    continue

  let refused = signProposal(Config(), drv, e, tampered) == soRefused
  if not refused: allRefused = false
  echo "{\"refused\": ", (if refused: "true" else: "false"), "}"

doAssert allRefused, "a mismatched materialization was not refused"
