## The identity binding (F-14): the secp256k1 Safe key vouches for an Ed25519/
## X25519 encryption identity, and the core verifies the mapping rather than
## trusting it. Needs libsecp256k1 + libsodium (see tests/README.md).

import std/strutils
import ../src/crypto/secp256k1
import ../src/crypto/curve25519
import ../src/crypto/binding

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

# An anvil owner's secp256k1 key, and a separate encryption identity to bind to it.
let ownerSec = key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let ownerAddr = addressOf(ownerSec)
let notOwner = key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
let enc = encFromSeed(seed(7)).identity()
let ctx = LinkContext(account: "0x5FbD...safe", slot: "0", expiry: 1000)

proc signerFor(sec: array[32, byte]): proc(h: array[32, byte]): Signature65 =
  (proc(h: array[32, byte]): Signature65 = signRecoverable(h, sec))

# 1. A binding the owner issues recovers to the owner's address.
let st = issueBinding(signerFor(ownerSec), enc, ctx)
doAssert bindingSigner(st, now = 0) == ownerAddr, "the binding recovers to its signer"
doAssert bindingBinds(st, @[ownerAddr], now = 0), "signer is a configured owner -> binds (F-9)"
echo "1. binding recovers to the owner OK"

# 2. A non-owner's binding does not bind against the owner set.
let stIntruder = issueBinding(signerFor(notOwner), enc, ctx)
doAssert not bindingBinds(stIntruder, @[ownerAddr], now = 0),
         "a non-owner's binding must not satisfy the owner check"
echo "2. non-owner binding refused OK"

# 3. A tampered encryption identity breaks the binding — the signature no longer
#    recovers to the owner (it was made over the original enc key).
var forged = st
forged.enc = encFromSeed(seed(8)).identity()   # swap in a different encryption key
doAssert not bindingBinds(forged, @[ownerAddr], now = 0),
         "swapping the bound key invalidates the binding"
echo "3. tampered binding refused OK"

# 4. Expiry is enforced independently of the signer being valid.
doAssert bindingBinds(st, @[ownerAddr], now = 1000), "valid at the expiry boundary"
doAssert not bindingBinds(st, @[ownerAddr], now = 1001), "refused past expiry"
var expiredRaised = false
try:
  discard bindingSigner(st, now = 1001)
except BindingError:
  expiredRaised = true
doAssert expiredRaised, "an expired binding raises rather than recovering"
echo "4. expiry enforced OK"

# 5. A binding is scoped to its context — the same keys under a different account
#    produce different bytes, so a binding cannot be lifted to another room.
let stOtherRoom = issueBinding(signerFor(ownerSec), enc,
                               LinkContext(account: "other-safe", slot: "0", expiry: 1000))
doAssert stOtherRoom.sig != st.sig, "a different account yields a different binding"
echo "5. binding is context-scoped OK"

echo "binding_test: all OK"
