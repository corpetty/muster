## Conformance + behavior for the EIP-191 personal-sign driver (P-D6): a Tier-1
## (module-native) driver beyond Safe, the worked completion of the driver-derivation
## skeleton. It must grade identically under checkConformance, and its module-native
## canonicalize (EIP-191 digest) + verifyContribution (secp ecrecover) must work.

import std/strutils
import ../src/drivers/driver
import ../src/drivers/eip191
import ../src/drivers/registry
import ../src/drivers/conformance
import ../src/intents/materialization
import ../src/dcbor/dcbor
import ../src/crypto/secp256k1
import std/json

proc hex32(s: string): array[32, byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc addrHex(a: Address): string =
  ## "0x" + lowercase hex of the 20 address bytes — the form the registry's hexToAddr
  ## round-trips (Address's own `$` may checksum/format differently).
  const hexd = "0123456789abcdef"
  result = "0x"
  for b in a: (result.add hexd[int(b shr 4)]; result.add hexd[int(b and 0x0F)])

# A known key (anvil account 0) — the signer whose personal_sign counts.
const sk0 = hex32("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let signer0 = addressOf(sk0)

let effect = Effect(schemaId: "muster.effect.statement.v1", fields: @[
  ("text", cbText("the room attests: ship v0.1")), ("nonce", cbUint(0'u64))])
let tampered = Effect(schemaId: "muster.effect.statement.v1", fields: @[
  ("text", cbText("the room attests: ship v0.2")), ("nonce", cbUint(0'u64))])

# ── 1. describe: a 1-round, named, immediate-finality attestation ──────────────
block:
  let d = newPersonalSignDriver(signers = @[signer0], threshold = 1)
  let desc = d.describe()
  doAssert desc.rounds == 1
  doAssert desc.membership == mmNamed
  doAssert desc.finality == finImmediate, "an attestation settles nothing on-chain"
  doAssert desc.serializationDomain == EIP191_DOMAIN
  echo "1. describe() — named, immediate-finality personal-sign attestation OK"

# ── 2. canonicalize is the EIP-191 digest, distinct from a generic dCBOR array ──
block:
  let d = newPersonalSignDriver(signers = @[signer0], threshold = 1)
  let m = canonicalize(d, effect)
  doAssert m.bytes.len == 32, "the materialization is a 32-byte EIP-191 digest"
  # the prefix must be the personal_sign prefix (proves it isn't the base dCBOR)
  let direct = eip191Digest(effectMessage(effect, EIP191_DOMAIN))
  doAssert m.bytes == @direct, "canonicalize == eip191Digest(effectMessage) — re-derivable"
  echo "2. canonicalize is the EIP-191 personal_sign digest OK"

# ── 3. conformance: grades identically to Safe/stub with a real signature ───────
block:
  let d = newPersonalSignDriver(signers = @[signer0], threshold = 1)
  let digest = canonicalize(d, effect).bytes
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = digest[i]
  let sig = signRecoverable(h, sk0)          # a real personal_sign by signer0
  let r = checkConformance(d, effect, tampered, Contribution(bytes: @sig))
  doAssert r.allPass(), "eip191 driver must conform: failed " & $r.failed()
  echo "3. eip191 driver conforms (", r.checks.len, " checks) OK"

# ── 4. verify + identify: recovers a configured signer, rejects a stranger ──────
block:
  let d = newPersonalSignDriver(signers = @[signer0], threshold = 1)
  let m = canonicalize(d, effect)
  d.expectMaterialization(m)
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = m.bytes[i]
  let sig = signRecoverable(h, sk0)
  doAssert d.verifyContribution(Contribution(bytes: @sig), 1), "signer0's signature counts"
  doAssert d.identifyContributor(m, Contribution(bytes: @sig)) == addrHex(signer0), "identifies signer0"

  # a stranger's key must NOT count (module-native auth beyond the room roster)
  const skX = hex32("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
  let sigX = signRecoverable(h, skX)
  doAssert not d.verifyContribution(Contribution(bytes: @sigX), 1), "a non-signer is refused"
  doAssert d.identifyContributor(m, Contribution(bytes: @sigX)) == "", "a non-signer is not identified"
  echo "4. verify/identify — configured signer counts, stranger refused OK"

# ── 5. the registry builds it by kind + config (invariant 6, turnkey) ───────────
block:
  let d = newDriver("eip191", %*{
    "signers": [addrHex(signer0)], "threshold": 1})
  let digest = canonicalize(d, effect).bytes
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = digest[i]
  let sig = signRecoverable(h, sk0)
  let r = checkConformance(d, effect, tampered, Contribution(bytes: @sig))
  doAssert r.allPass(), "registry-built eip191 driver must conform: " & $r.failed()
  echo "5. registry newDriver(\"eip191\", …) builds a conforming driver OK"

echo "eip191_test: all OK"
