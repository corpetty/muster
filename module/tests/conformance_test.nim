## Conformance gate (invariant 6): the stub driver must be conformant across a
## descriptor matrix, and a malformed descriptor must be REJECTED (the gate has
## teeth). Pure Nim — runs everywhere. See src/drivers/conformance.nim.
## The Safe driver's conformance runs in safe_conformance_test.nim (secp-linked).

import ../src/drivers/driver
import ../src/drivers/conformance

var total = 0
var nonconformant = 0
for rounds in [1, 2, 3]:
  for threshold in [1, 2, 3]:
    for membership in [mmAnonymous, mmNamed]:
      for finality in [finImmediate, finProbabilistic, finExternal]:
        let d = newStubDriver(rounds = rounds, threshold = threshold,
          domain = "muster.stub.v1", membership = membership,
          finality = finality, verifyResult = true)
        let fails = checkConformance(d)
        inc total
        if fails.len > 0:
          inc nonconformant
          echo "NONCONFORMANT rounds=", rounds, " threshold=", threshold,
               " membership=", membership, " finality=", finality
          for f in fails: echo "  - ", f

echo total, " stub descriptor configs checked, ", nonconformant, " nonconformant"
doAssert nonconformant == 0, "stub driver must be conformant across the descriptor matrix"

# Teeth: a malformed descriptor (rounds/threshold < 1, empty domain) must fail.
let broken = newStubDriver(rounds = 0, threshold = 0, domain = "")
doAssert checkConformance(broken).len > 0, "conformance must reject a malformed descriptor"

echo "conformance: stub matrix conformant; malformed descriptor rejected"
