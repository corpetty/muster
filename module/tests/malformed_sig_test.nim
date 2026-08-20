## Regression: a malformed 65-byte contribution is REJECTED, never a crash.
##
## Found driving approve() through the cdylib ABI with a garbage signature: a
## recovery id outside 0..3 reached libsecp256k1's parse_compact and tripped its
## illegal-argument callback, which calls abort() — an uncatchable process kill
## (DoS on a hostile contribution). recoversToOwner must return false for ANY
## malformed signature, so the driver just doesn't count it (invariant: the core
## never trusts contribution bytes; a bad one is rejected, not fatal).
##
## Needs libsecp256k1 linked — see tests/README.md.

import ../src/crypto/secp256k1

# An owner keypair for the valid-path sanity checks.
var sk: array[32, byte]
for i in 0 ..< 32: sk[i] = byte(i + 1)
let owner = addressOf(sk)

var hash: array[32, byte]
for i in 0 ..< 32: hash[i] = 0xAB'u8

# 1. A valid owner signature still recovers (the fix doesn't break the happy path).
let good = signRecoverable(hash, sk)
doAssert recoversToOwner(hash, good, @[owner]), "valid owner signature must recover"

# 2. Every out-of-range v byte — the abort window was v in {4..26} ∪ {31..255} —
#    must be rejected gracefully, never crash.
for v in [4'u8, 5, 12, 26, 31, 64, 100, 200, 255]:
  var s = good
  s[64] = v
  doAssert not recoversToOwner(hash, s, @[owner]),
    "v=" & $v & " must be rejected without aborting"

# 3. Valid recid but all-zero r/s — recovery fails cleanly → not an owner.
var garbage: Signature65
garbage[64] = 27                       # recid 0, in range; r/s are zero
doAssert not recoversToOwner(hash, garbage, @[owner]), "garbage r/s must be rejected"

# 4. A valid signature must not recover to a DIFFERENT owner set.
var sk2: array[32, byte]
for i in 0 ..< 32: sk2[i] = byte(i + 100)
doAssert not recoversToOwner(hash, good, @[addressOf(sk2)]),
  "a signature must not recover to a non-signer"

echo "malformed_sig: all malformed contributions rejected, no abort"
