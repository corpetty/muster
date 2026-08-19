## Safe driver / EIP-712 safeTxHash test (P2). Validates the EIP-712 machinery
## against the published Safe 1.4.1 type-hash constants, and that safeTxHash binds
## chainId / Safe address / nonce (the wrong-chainid / wrong-safe / wrong-nonce
## rejections, and invariant-2 replay binding).

import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/intents/materialization

proc hx(b: seq[byte]): string =
  const d = "0123456789abcdef"
  for x in b:
    result.add d[int(x shr 4)]; result.add d[int(x and 15)]

block typehashes:
  # The on-chain Safe 1.4.1 constants — if these match, the EIP-712 encoding +
  # keccak256 are correct against published vectors.
  doAssert hx(DOMAIN_TYPEHASH) ==
    "47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218", hx(DOMAIN_TYPEHASH)
  doAssert hx(SAFE_TX_TYPEHASH) ==
    "bb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8", hx(SAFE_TX_TYPEHASH)
  echo "Safe EIP-712 type hashes match published 1.4.1 constants: OK"

block replayBinding:
  var safe: Address
  for i in 0 ..< 20: safe[i] = byte(i + 1)
  let tx = SafeTx(to: safe, value: 1000, nonce: 5)
  let base = safeTxHash(tx, 1, safe)
  doAssert safeTxHash(tx, 2, safe) != base                    # wrong chainId
  var safe2 = safe; safe2[0] = 0xFF'u8
  doAssert safeTxHash(tx, 1, safe2) != base                   # wrong Safe
  var tx2 = tx; tx2.nonce = 6
  doAssert safeTxHash(tx2, 1, safe) != base                   # wrong nonce
  doAssert safeTxHash(tx, 1, safe) == base                    # same context reproduces
  echo "safeTxHash binds chainId, Safe, and nonce (wrong-* rejected): OK"

block driverCanonicalize:
  var safe: Address
  for i in 0 ..< 20: safe[i] = byte(0xA0 + i)
  let drv = newSafeDriver(chainId = 1, safe = safe, threshold = 2)
  doAssert drv.describe().rounds == 1
  doAssert drv.describe().membership == mmNamed
  doAssert drv.describe().finality == finExternal
  let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
    ("to", cbText("0x00112233445566778899aabbccddeeff00112233")),
    ("value", cbUint(500'u64)), ("nonce", cbUint(3'u64))])
  let mat = canonicalizeSafe(drv, effect)
  doAssert mat.bytes.len == 32
  doAssert canonicalizeSafe(drv, effect).bytes == mat.bytes   # invariant 1: re-derivable
  echo "SafeDriver canonicalize -> 32-byte safeTxHash, deterministic: OK"

echo "safe: all checks passed"
