## secp256k1 ECDSA recovery test (P2). Validates address derivation against a
## published Ethereum vector (privkey 1) and a sign->recover round-trip.
import ../src/crypto/secp256k1

proc hx(a: Address): string =
  const d = "0123456789abcdef"
  for x in a:
    result.add d[int(x shr 4)]; result.add d[int(x and 15)]

block knownAddress:
  var sk: array[32, byte]; sk[31] = 1
  doAssert hx(addressOf(sk)) == "7e5f4552091a69125d5dfcb7b8c2659029395bdf", hx(addressOf(sk))
  echo "privkey 1 -> published address 0x7E5F...Bdf: OK"

block signRecoverRoundTrip:
  var sk: array[32, byte]
  for i in 0 ..< 32: sk[i] = byte(i + 1)
  let a = addressOf(sk)
  var hash: array[32, byte]
  for i in 0 ..< 32: hash[i] = byte(0xAB xor i)
  let sig = signRecoverable(hash, sk)
  doAssert ecrecover(hash, sig) == a
  doAssert recoversToOwner(hash, sig, [a])
  var other = a; other[0] = other[0] xor 0xFF'u8
  doAssert not recoversToOwner(hash, sig, [other])
  echo "sign -> recover round-trip + owner check: OK"

echo "secp256k1: all checks passed"
