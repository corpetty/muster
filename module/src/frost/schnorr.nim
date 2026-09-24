## BIP-340 with a tag prefix, key generation and ECDH — what ChillDKG's reference takes
## from secp256k1lab (bip340.py, keys.py, ecdh.py @ mllwchrry/bips 2b9b0b1), over the
## group of secp.nim (exo-fae).
##
## ChillDKG's proofs of possession are BIP-340 signatures under a DIFFERENT tag prefix
## ("BIP DKG/pop message"), which libsecp256k1's schnorrsig cannot make (its challenge tag
## is fixed), so signing and verification are written here in the draft's own terms. With
## the default prefix "BIP0340" they are plain BIP-340 (tests hold them to the BIP-340
## vectors). NOT constant time — see secp.nim.

import ./secp
import ../bitcoin/tx          # taggedHash
import ../hashing/sha256

proc th(tag: string, data: openArray[byte]): seq[byte] = @(taggedHash(tag, data))

proc seckeyScalar(seckey: openArray[byte]): Scalar =
  ## the secret key as a scalar in 1..n−1, else ValueError (the reference's message)
  if seckey.len != 32: raise newException(ValueError, "The secret key must be an integer in the range 1..n-1.")
  let d = scalarFromBytesWrapping(seckey)
  var raw = true
  try: discard scalarFromBytesChecked(seckey)
  except ValueError: raw = false
  if not raw or d.isZero: raise newException(ValueError, "The secret key must be an integer in the range 1..n-1.")
  d

proc pubkeyGenPlain*(seckey: openArray[byte]): seq[byte] =
  ## the 33-byte compressed public key; ValueError outside 1..n−1
  mulG(seckeyScalar(seckey)).toCompressed()

proc pubkeyGenXonly*(seckey: openArray[byte]): seq[byte] = mulG(seckeyScalar(seckey)).toXonly()

proc schnorrSign*(msg, seckey, auxRand: openArray[byte], tagPrefix = "BIP0340"): seq[byte] =
  let d0 = seckeyScalar(seckey)
  if auxRand.len != 32: raise newException(ValueError, "aux_rand must be 32 bytes instead of " & $auxRand.len & ".")
  let p = mulG(d0)
  let d = (if p.hasEvenY(): d0 else: -d0)
  let t = block:
    var x = d.toBytes()
    let a = th(tagPrefix & "/aux", auxRand)
    for i in 0 ..< 32: x[i] = x[i] xor a[i]
    x
  let k0 = scalarFromBytesWrapping(th(tagPrefix & "/nonce", t & p.toXonly() & @msg))
  if k0.isZero: raise newException(ValueError, "Failure. This happens only with negligible probability.")
  let r = mulG(k0)
  let k = (if r.hasEvenY(): k0 else: -k0)
  let e = scalarFromBytesWrapping(th(tagPrefix & "/challenge", r.toXonly() & p.toXonly() & @msg))
  result = r.toXonly() & (k + e * d).toBytes()

proc schnorrVerify*(msg, pubkey, sig: openArray[byte], tagPrefix = "BIP0340"): bool =
  if pubkey.len != 32: raise newException(ValueError, "The public key must be a 32-byte array.")
  if sig.len != 64: raise newException(ValueError, "The signature must be a 64-byte array.")
  var p: GE
  try: p = liftX(pubkey)
  except ValueError: return false
  var s: Scalar
  try: s = scalarFromBytesChecked(sig[32 ..< 64])
  except ValueError: return false
  # r must be a field element (< p); lift_x of r is not needed — compare x-coordinates
  let e = scalarFromBytesWrapping(th(tagPrefix & "/challenge", @(sig[0 ..< 32]) & @pubkey & @msg))
  let r = mulG(s) + -(e * p)
  if r.isInfinity or not r.hasEvenY(): return false
  r.toXonly() == @(sig[0 ..< 32])

proc ecdhLibsecp*(seckey, pubkey: openArray[byte]): seq[byte] =
  ## SHA-256 of the compressed shared point — libsecp256k1's default ECDH hash.
  ## ValueError for a seckey ≥ n or an invalid public key.
  let k = scalarFromBytesChecked(seckey)
  let shared = k * pointFromCompressed(pubkey)
  doAssert not shared.isInfinity, "prime-order group"
  @(sha256(shared.toCompressed()))
