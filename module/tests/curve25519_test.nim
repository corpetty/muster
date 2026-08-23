## The encryption/chat identity (F-14 two-identity model): Ed25519 auth + X25519
## key-agreement, both derived from one seed, with sealed-box (ECIES) wrapping.
## Needs libsodium (see tests/README.md).

import ../src/crypto/curve25519

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

# 1. Deterministic from a seed — the identity survives a restart from the same seed.
let a = encFromSeed(seed(1))
let a2 = encFromSeed(seed(1))
doAssert a.identity() == a2.identity(), "same seed -> same encryption identity"
let b = encFromSeed(seed(2))
doAssert a.identity() != b.identity(), "different seed -> different identity"
echo "1. deterministic encryption identity OK"

# 2. Ed25519 sign/verify roundtrip, and a tampered message is rejected.
let msg = @[byte 10, 20, 30, 40]
let sig = a.edSign(msg)
doAssert edVerify(a.identity().ed, msg, sig), "our ed25519 signature verifies"
doAssert not edVerify(b.identity().ed, msg, sig), "another identity's key does not verify it"
var bad = msg
bad[0] = 99
doAssert not edVerify(a.identity().ed, bad, sig), "a tampered message is rejected"
echo "2. ed25519 sign/verify OK"

# 3. Sealed-box (ECIES over X25519) wrap: only the recipient opens it.
let secret = @[byte 1, 2, 3, 4, 5, 6, 7, 8]
let sealed = sealTo(b.identity().x, secret)
doAssert b.sealOpen(sealed) == secret, "the recipient opens the sealed box"
var otherFailed = false
try:
  discard a.sealOpen(sealed)          # a is not the recipient
except Curve25519Error:
  otherFailed = true
doAssert otherFailed, "a non-recipient cannot open the sealed box"
echo "3. sealed-box wrap/unwrap OK"

echo "curve25519_test: all OK"
