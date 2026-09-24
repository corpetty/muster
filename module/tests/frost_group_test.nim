## secp256k1 group and scalar arithmetic for threshold Schnorr (exo-b9c, Phase D1): what
## BIP-445 (FROST signing) and ChillDKG need that libsecp256k1's public API does not give —
## the point at infinity (an aggregate nonce may be it), scalar inverse (Lagrange
## coefficients), full arithmetic mod n.
##   1. scalars: checked parsing refuses n and above, wrapping parsing reduces mod n,
##      nonzero parsing refuses 0; small integers (negative too) map mod n; the field laws
##      hold, including a · a⁻¹ = 1 and n − 1 = −1;
##   2. points: k·G is the generator's multiples (G, 2G, 3G as published); addition and
##      negation with the point at infinity; k·P matches libsecp's own multiplication;
##      compressed round trips, the 33-zero-byte encoding of infinity, x-only and even-y;
##   3. BIP-340 verification written in these operations — s·G = R + e·P — agrees with
##      libsecp's schnorrsig_verify on the BIP-340 vectors.
## Needs the secp closure + stint — see tests/README.md.

import std/[strutils, sequtils, parsecsv, os]
import ../src/frost/secp
import ../src/bitcoin/[tx, keys]

proc hb(s: string): seq[byte] = hexToBytes(s)
const Order = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
const Gc = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
const G2c = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
const G3c = "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

# ── 1. scalars ─────────────────────────────────────────────────────────────────
block:
  var raised = false
  try: discard scalarFromBytesChecked(hb(Order))
  except ValueError: raised = true
  doAssert raised, "n itself is not a scalar"
  doAssert scalarFromBytesWrapping(hb(Order)).isZero, "n wraps to 0"
  doAssert toHex(scalarFromBytesChecked(hb(Order[0 ..< 63] & "0")).toBytes()) == Order[0 ..< 63] & "0"
  raised = false
  try: discard scalarFromBytesNonzeroChecked(newSeq[byte](32))
  except ValueError: raised = true
  doAssert raised, "0 is refused where a nonzero scalar is required"
  doAssert toHex(scalar(-1).toBytes()) == Order[0 ..< 63] & "0", "−1 is n − 1"
  let a = scalarFromBytesWrapping(hb("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"))
  let b = scalar(7)
  doAssert a + b - b == a and a * b / b == a and (a * a.inv) == scalar(1)
  doAssert -a + a == scalar(0) and a * scalar(0) == scalar(0) and (a + b) * b == a * b + b * b
  doAssert scalar(3) / scalar(2) * scalar(2) == scalar(3)
  echo "1. scalars mod n: checked / wrapping / nonzero parsing; the field laws, inverse included OK"

# ── 2. points ──────────────────────────────────────────────────────────────────
block:
  doAssert toHex(generator().toCompressed()) == Gc
  doAssert toHex((scalar(2) * generator()).toCompressed()) == G2c
  doAssert toHex((generator() + generator() + generator()).toCompressed()) == G3c
  let inf = infinity()
  doAssert inf.isInfinity and (generator() + inf) == generator() and (inf + generator()) == generator()
  doAssert (generator() + -generator()).isInfinity, "P + (−P) = ∞"
  doAssert (scalar(0) * generator()).isInfinity and (scalar(5) * inf).isInfinity
  let k = scalarFromBytesWrapping(hb("c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9"))
  let P = k * generator()
  doAssert P.toCompressed() == compressedPubKey(k.toBytes()), "k·G matches libsecp's key derivation"
  doAssert (scalar(3) * P) == P + P + P and (scalar(-1) * P) == -P
  doAssert pointFromCompressed(P.toCompressed()) == P
  doAssert pointFromCompressedWithInfinity(newSeq[byte](33)).isInfinity
  doAssert inf.toCompressedWithInfinity() == newSeq[byte](33)
  doAssert P.toCompressedWithInfinity() == P.toCompressed()
  var raised = false
  try: discard pointFromCompressed(newSeq[byte](33))
  except ValueError: raised = true
  doAssert raised, "infinity has no plain compressed encoding"
  raised = false
  try: discard pointFromCompressed(@[0x02'u8] & newSeq[byte](31) & @[0x05'u8])
  except ValueError: raised = true
  doAssert raised, "an x off the curve is refused"
  doAssert P.toXonly() == P.toCompressed()[1 .. 32]
  doAssert P.hasEvenY() == (P.toCompressed()[0] == 0x02)
  let lifted = liftX(P.toXonly())
  doAssert lifted.hasEvenY() and lifted.toXonly() == P.toXonly()
  doAssert (if P.hasEvenY(): lifted == P else: lifted == -P)
  echo "2. points: multiples of G, infinity, negation, k·P, compressed / x-only / even-y OK"

# ── 3. BIP-340 in these operations ─────────────────────────────────────────────
block:
  let csv = currentSourcePath().parentDir() / "vectors" / "bip-0340-test-vectors.csv"
  var p: CsvParser
  p.open(csv)
  p.readHeaderRow()
  var checked = 0
  while p.readRow():
    let pk = hb(p.rowEntry("public key"))
    let msg = hb(p.rowEntry("message"))
    let sig = hb(p.rowEntry("signature"))
    if msg.len != 32 or pk.len != 32 or sig.len != 64: continue
    var ours = false
    try:
      let Pt = liftX(pk)
      let R = liftX(sig[0 ..< 32])
      let s = scalarFromBytesChecked(sig[32 .. 63])
      let e = scalarFromBytesWrapping(@(taggedHash("BIP0340/challenge", sig[0 ..< 32] & pk & msg)))
      let lhs = s * generator()
      # BIP-340: R' = s·G − e·P must have even y and x(R') = r
      let Rp = lhs + -(e * Pt)
      ours = not Rp.isInfinity and Rp.hasEvenY() and Rp.toXonly() == sig[0 ..< 32]
      discard R
    except ValueError: ours = false
    doAssert ours == schnorrVerify(sig, msg, pk), "vector " & p.rowEntry("index")
    inc checked
  p.close()
  doAssert checked >= 15
  echo "3. BIP-340 verification in these operations agrees with libsecp on ", checked, " vectors OK"

echo "frost_group_test: secp256k1 points with infinity and scalars mod n — all OK"
