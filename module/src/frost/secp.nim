## secp256k1 group and scalar arithmetic for threshold Schnorr (exo-b9c, Phase D1).
##
## BIP-445 (FROST signing) and ChillDKG are written over a group with a point at infinity
## and a scalar field with inverses (secp256k1lab's GE / Scalar). libsecp256k1's public
## API has neither: a `secp256k1_pubkey` cannot be infinity, and there is no scalar
## inverse. So:
##   * a point is libsecp's `secp256k1_pubkey` plus an explicit infinity flag; addition is
##     `ec_pubkey_combine` (which fails exactly when the sum is infinity), k·P is
##     `ec_pubkey_tweak_mul`, k·G is `ec_pubkey_create`, −P is `ec_pubkey_negate`;
##   * a scalar is a stint UInt256 kept reduced mod n; multiplication is `mulmod`, the
##     inverse is Fermat's a^(n−2) (`powmod`).
## NOT constant time: stint's arithmetic branches on values. This is the demo-grade FROST
## the family registry calls a candidate; the production gate for threshold schemes
## (landscape §9, "Threshold ECDSA") applies here too — re-choose the implementation
## before real funds.

import std/strutils
import stint
import pkg/secp256k1/abi

type
  Scalar* = object
    v: UInt256                ## always reduced: 0 ≤ v < n

  GE* = object
    inf: bool
    pk: secp256k1_pubkey

let secpCtx = secp256k1_context_create(SECP256K1_CONTEXT_NONE)
let N = UInt256.fromHex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")

# ── scalars ─────────────────────────────────────────────────────────────────────
proc scalarOf(v: UInt256): Scalar = Scalar(v: v mod N)

proc scalarFromBytesWrapping*(b: openArray[byte]): Scalar =
  if b.len != 32: raise newException(ValueError, "a scalar is 32 bytes")
  scalarOf(UInt256.fromBytesBE(b))

proc scalarFromBytesChecked*(b: openArray[byte]): Scalar =
  if b.len != 32: raise newException(ValueError, "a scalar is 32 bytes")
  let v = UInt256.fromBytesBE(b)
  if v >= N: raise newException(ValueError, "the value is not below the group order")
  Scalar(v: v)

proc scalarFromBytesNonzeroChecked*(b: openArray[byte]): Scalar =
  result = scalarFromBytesChecked(b)
  if result.v.isZero: raise newException(ValueError, "the scalar is zero")

proc toBytes*(s: Scalar): seq[byte] = @(s.v.toBytesBE())
proc isZero*(s: Scalar): bool = s.v.isZero
proc `==`*(a, b: Scalar): bool = a.v == b.v
proc `+`*(a, b: Scalar): Scalar = Scalar(v: addmod(a.v, b.v, N))
proc `-`*(a: Scalar): Scalar = (if a.v.isZero: a else: Scalar(v: N - a.v))
proc `-`*(a, b: Scalar): Scalar = a + (-b)
proc `*`*(a, b: Scalar): Scalar = Scalar(v: mulmod(a.v, b.v, N))
proc inv*(a: Scalar): Scalar =
  if a.v.isZero: raise newException(ValueError, "zero has no inverse")
  Scalar(v: powmod(a.v, N - u256(2), N))
proc `/`*(a, b: Scalar): Scalar = a * b.inv

proc scalar*(x: int64): Scalar =
  ## A small integer, negative ones as n − |x|.
  if x >= 0: scalarOf(u256(uint64(x))) else: -scalarOf(u256(uint64(-x)))

# ── points ──────────────────────────────────────────────────────────────────────
proc infinity*(): GE = GE(inf: true)
proc isInfinity*(p: GE): bool = p.inf

proc pointFromCompressed*(b: openArray[byte]): GE =
  if b.len != 33: raise newException(ValueError, "a compressed point is 33 bytes")
  var pk: secp256k1_pubkey
  if b[0] notin {0x02'u8, 0x03'u8} or
     secp256k1_ec_pubkey_parse(secpCtx, addr pk, unsafeAddr b[0], 33) != 1:
    raise newException(ValueError, "not a point on secp256k1")
  GE(inf: false, pk: pk)

proc pointFromCompressedWithInfinity*(b: openArray[byte]): GE =
  ## As pointFromCompressed, and 33 zero bytes are the point at infinity.
  if b.len == 33:
    var zero = true
    for x in b:
      if x != 0: zero = false
    if zero: return infinity()
  pointFromCompressed(b)

proc toCompressed*(p: GE): seq[byte] =
  if p.inf: raise newException(ValueError, "the point at infinity has no compressed encoding")
  result = newSeq[byte](33)
  var outLen = csize_t(33)
  var pk = p.pk
  discard secp256k1_ec_pubkey_serialize(secpCtx, addr result[0], addr outLen, addr pk, SECP256K1_EC_COMPRESSED)

proc toCompressedWithInfinity*(p: GE): seq[byte] =
  if p.inf: newSeq[byte](33) else: p.toCompressed()

proc toXonly*(p: GE): seq[byte] = p.toCompressed()[1 .. 32]
proc hasEvenY*(p: GE): bool = p.toCompressed()[0] == 0x02'u8

proc liftX*(x: openArray[byte]): GE =
  ## The point with this x-coordinate and an even y (BIP-340 lift_x).
  if x.len != 32: raise newException(ValueError, "an x-coordinate is 32 bytes")
  pointFromCompressed(@[0x02'u8] & @x)

proc `==`*(a, b: GE): bool =
  if a.inf or b.inf: return a.inf and b.inf
  a.toCompressed() == b.toCompressed()

proc `-`*(p: GE): GE =
  if p.inf: return p
  result = p
  discard secp256k1_ec_pubkey_negate(secpCtx, addr result.pk)

proc `+`*(a, b: GE): GE =
  if a.inf: return b
  if b.inf: return a
  var pa = a.pk
  var pb = b.pk
  var ins = [addr pa, addr pb]
  var o: secp256k1_pubkey
  if secp256k1_ec_pubkey_combine(secpCtx, addr o, addr ins[0], csize_t(2)) != 1:
    return infinity()              # combine fails exactly when the sum is infinity
  GE(inf: false, pk: o)

proc generator*(): GE =
  var one = newSeq[byte](32)
  one[31] = 1
  var pk: secp256k1_pubkey
  discard secp256k1_ec_pubkey_create(secpCtx, addr pk, addr one[0])
  GE(inf: false, pk: pk)

proc `*`*(k: Scalar, p: GE): GE =
  if k.isZero or p.inf: return infinity()
  var kb = k.toBytes()
  result = p
  if secp256k1_ec_pubkey_tweak_mul(secpCtx, addr result.pk, addr kb[0]) != 1:
    raise newException(ValueError, "scalar multiplication failed")

proc mulG*(k: Scalar): GE =
  ## k·G via libsecp's key derivation (the fast path for the generator)
  if k.isZero: return infinity()
  var kb = k.toBytes()
  var pk: secp256k1_pubkey
  if secp256k1_ec_pubkey_create(secpCtx, addr pk, addr kb[0]) != 1:
    raise newException(ValueError, "k·G failed")
  GE(inf: false, pk: pk)

proc hexOf*(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))
