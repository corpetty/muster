## secp256k1 ECDH (via core point-multiply) + pubkey recovery — the key agreement
## under the F-16 epoch layer's ECIES wrap. Needs libsecp256k1 linked (see
## tests/README.md). Reuses the members' existing secp256k1 keys (no second curve).
import std/strutils
import ../src/crypto/secp256k1

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0]=='0' and (h[1]=='x' or h[1]=='X'): h = h[2..^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

let a = key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let b = key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
let c = key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a")

# 1. ECDH symmetry: ecdh(a, pub(b)) == ecdh(b, pub(a))
let sab = ecdh(a, pubKeyOf(b))
doAssert sab == ecdh(b, pubKeyOf(a)), "ECDH must be symmetric"
doAssert sab != default(array[32, byte]), "shared secret must be non-zero"
echo "1. ECDH symmetry OK"

# 2. distinct peers -> distinct secrets
doAssert ecdh(a, pubKeyOf(b)) != ecdh(a, pubKeyOf(c)), "different peer -> different secret"
echo "2. distinctness OK"

# 3. pubkey recovered from a signature == the signer's pubkey (the reuse mechanism)
var msg: array[32, byte]
for i in 0 ..< 32: msg[i] = byte(i)
doAssert recoverPubKey(msg, signRecoverable(msg, a)) == pubKeyOf(a),
         "recovered pubkey must equal the signer's own pubkey"
echo "3. pubkey recovery OK"
echo "ecdh_test: all OK"
