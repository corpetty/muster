## Standalone test for the 2-round FROST-style driver. Unlike the full
## conformance_test (which also grades the Safe driver and so needs libsecp256k1),
## this exercises only Ed25519 + the core, so it runs with a bare `nim r`.
##
## It proves the thing this driver exists for: the multi-round core path
## (proposed → collecting round 1 → collecting round 2 → executable), which no
## real driver exercised before (Safe and threshold are both single-round).

import std/strutils
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/intents/signing_payload
import ../src/intents/lifecycle
import ../src/drivers/driver
import ../src/drivers/frost
import ../src/drivers/conformance
import ../src/crypto/curve25519

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc contrib(sig: Ed25519Sig): Contribution =
  var b: seq[byte]
  for x in sig: b.add x
  Contribution(bytes: b)

# A roster of two signers, k = 2 required in EACH round.
let m1 = encFromSeed(seed(1))
let m2 = encFromSeed(seed(2))
let drv = newFrostDriver(@[m1.identity().ed, m2.identity().ed], k = 2)

# 1) it declares two rounds — the defining property (invariant 6, from describe()).
doAssert drv.describe().rounds == 2, "FROST declares two rounds"
doAssert drv.describe().threshold == 2, "k-of-n per round"
doAssert drv.describe().serializationDomain == "muster.frost.v1"
echo "1. FROST declares rounds=2, k=2 OK"

# 2) conformance — a single-member roster (k=1) so the suite's convergence check,
#    which reuses one contribution across both rounds, drives 1*2 = 2 passes.
block:
  let cm = encFromSeed(seed(5))
  let cdrv = newFrostDriver(@[cm.identity().ed], k = 1)
  let e = Effect(schemaId: "muster.effect.transfer.v1",
                 fields: @[("to", cbText("0xdef")), ("value", cbUint(7'u64))])
  let t = Effect(schemaId: "muster.effect.transfer.v1",
                 fields: @[("to", cbText("0xdef")), ("value", cbUint(8'u64))])
  let r = checkConformance(cdrv, e, t, contrib(edSign(cm, canonicalize(cdrv, e).bytes)))
  doAssert r.allPass(), "FROST must conform: failed " & $r.failed()
  echo "2. FROST conforms (", r.checks.len, " checks) OK"

# 3) the multi-round lifecycle end to end — the path this driver exists to exercise.
let effect = Effect(schemaId: "muster.effect.transfer.v1",
                    fields: @[("to", cbText("0x1111")), ("value", cbUint(1000'u64))])
let mat = canonicalize(drv, effect)
let sig1 = edSign(m1, mat.bytes)
let sig2 = edSign(m2, mat.bytes)
drv.expectMaterialization(mat)

let ctx = SigningContext(environment: "", account: "coordinated", slot: "0",
                         expiry: high(uint64))
var it = newIntent(drv, effect, ctx)
it.apply(drv, IntentEvent(kind: iePropose, now: 1))
doAssert it.state == lsProposed

# round 1 — two distinct signers reach k; the core advances to round 2 but the
# intent is NOT executable yet (this is the branch single-round drivers never hit).
it.apply(drv, IntentEvent(kind: ieContribute, now: 2, contribution: contrib(sig1)))
it.apply(drv, IntentEvent(kind: ieContribute, now: 3, contribution: contrib(sig2)))
doAssert it.state == lsCollecting, "after round-1 threshold, still collecting"
doAssert it.collection.round == 2, "the core advanced to round 2"
doAssert not it.collection.complete
echo "3a. round 1 reached k → advanced to round 2, still collecting OK"

# round 2 — two more reach k; now the collection completes → executable.
it.apply(drv, IntentEvent(kind: ieContribute, now: 4, contribution: contrib(sig1)))
it.apply(drv, IntentEvent(kind: ieContribute, now: 5, contribution: contrib(sig2)))
doAssert it.collection.complete, "both rounds closed"
doAssert it.state == lsExecutable, "after round-2 threshold, executable"
echo "3b. round 2 reached k → executable OK"

# 4) a non-roster signature is refused — the core routes on the driver's boolean,
#    and only the driver reads the bytes (invariant 6).
let outsider = encFromSeed(seed(99))
doAssert not drv.verifyContribution(contrib(edSign(outsider, mat.bytes)), 1),
         "a non-member signature must not count"
doAssert drv.identifyContributor(mat, contrib(edSign(outsider, mat.bytes))) == "",
         "a non-member has no contributor identity"
echo "4. non-member signature refused OK"

echo "frost_test: 2-round driver — conformance + multi-round lifecycle + non-member refusal OK"
