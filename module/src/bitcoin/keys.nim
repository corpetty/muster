## Bitcoin signatures over nim-secp256k1 (exo-a50.2.1): DER ECDSA with low-S (what a
## P2WSH CHECKMULTISIG accepts) and BIP-340 Schnorr (what a tapscript CHECKSIG /
## CHECKSIGADD accepts), plus compressed and x-only public keys. Signing takes a secret
## here only for the test vectors; muster signs through the keystore seam, which never
## hands out a key (exo-a50.2.4). Pinned to the BIP-143 and BIP-340 vectors.

import pkg/results
import pkg/secp256k1 as sk
import ./tx

proc secretOf(secret: openArray[byte]): sk.SkSecretKey =
  let r = sk.SkSecretKey.fromRaw(secret)
  if r.isErr: raise newException(BtcError, "not a valid secret key")
  r.get()

proc msgOf(h: openArray[byte]): sk.SkMessage =
  let r = sk.SkMessage.fromBytes(h)
  if r.isErr: raise newException(BtcError, "a message is 32 bytes")
  r.get()

proc validSecret*(secret: openArray[byte]): bool =
  ## 0 < secret < n: a usable secp256k1 secret key.
  secret.len == 32 and sk.SkSecretKey.fromRaw(secret).isOk

proc compressedPubKey*(secret: openArray[byte]): seq[byte] = @(secretOf(secret).toPublicKey().toRawCompressed())
proc xonlyPubKey*(secret: openArray[byte]): seq[byte] = @(secretOf(secret).toPublicKey().toXOnly().toRaw())
proc xonlyOfCompressed*(pub33: openArray[byte]): seq[byte] =
  let r = sk.SkPublicKey.fromRaw(pub33)
  if r.isErr: raise newException(BtcError, "not a public key")
  @(r.get().toXOnly().toRaw())

proc ecdsaSignDer*(secret, sighash: openArray[byte]): seq[byte] =
  ## RFC-6979 deterministic, low-S (libsecp256k1 always produces low-S), DER-encoded.
  ## The caller appends the sighash-type byte.
  sk.sign(secretOf(secret), msgOf(sighash)).toDer()

proc ecdsaVerifyDer*(der, sighash, pub33: openArray[byte]): bool =
  ## Strict DER, low-S only (a high-S signature is non-standard and refused).
  let s = sk.SkSignature.fromDer(der)
  let p = sk.SkPublicKey.fromRaw(pub33)
  if s.isErr or p.isErr: return false
  if s.get().toDer() != @der: return false            # non-canonical encoding or high-S
  sk.verify(s.get(), msgOf(sighash), p.get())

proc schnorrSign*(secret, msg: openArray[byte], aux: openArray[byte] = []): seq[byte] =
  ## BIP-340. `aux` = 32 bytes of auxiliary randomness (the test vectors pin it); empty =
  ## none. The caller appends a sighash-type byte only when it is not DEFAULT.
  var r = Opt.none(array[32, byte])
  if aux.len == 32:
    var a: array[32, byte]
    for i in 0 ..< 32: a[i] = aux[i]
    r = Opt.some(a)
  @(sk.signSchnorr(secretOf(secret), msg, r).toRaw())

proc schnorrVerify*(sig, msg, xonly: openArray[byte]): bool =
  let s = sk.SkSchnorrSignature.fromRaw(sig)
  let p = sk.SkXOnlyPublicKey.fromRaw(xonly)
  if s.isErr or p.isErr: return false
  sk.verify(s.get(), msg, p.get())
