## secp256k1 ECDSA recovery + Ethereum address derivation, over **nim-secp256k1**
## (Status/Nimbus) — one secp source for the whole module.
##
## Safe's checkSignatures recovers the signer address from an owner's ECDSA
## signature over the safeTxHash and checks it against the owner set; the keystore,
## the identity binding, and the driver all sign or recover through here. The curve
## operations are nim-secp256k1's (it vendors and compiles libsecp256k1 itself — no
## system lib is linked, and nim-eth reuses the same package, so there is exactly
## one copy of the C). Ethereum semantics stay ours: recover to an address, and the
## r‖s‖v (v = 27 + recid) packing Safe and EIP-155 expect.

import ../hashing/keccak256
import pkg/results
import pkg/secp256k1 as sk

type
  Secp256k1Error* = object of CatchableError
  Address* = array[20, byte]
  Signature65* = array[65, byte]   ## r(32) ++ s(32) ++ v(1)
  PubKey* = array[33, byte]        ## compressed secp256k1 public key

proc addressOfPub(pub: sk.SkPublicKey): Address =
  ## Ethereum address = last 20 bytes of keccak256 of the 64-byte pubkey body
  ## (the uncompressed serialization minus its 0x04 tag).
  let raw = pub.toRaw()            # 65 bytes: 0x04 ++ X(32) ++ Y(32)
  var body: array[64, byte]
  for i in 0 ..< 64: body[i] = raw[i + 1]
  let kh = keccak256(body)
  for i in 0 ..< 20: result[i] = kh[12 + i]

proc secKey(seckey: array[32, byte]): sk.SkSecretKey =
  let r = sk.SkSecretKey.fromRaw(seckey)
  if r.isErr: raise newException(Secp256k1Error, "invalid secret key")
  r.get()

proc ecrecover*(msgHash: array[32, byte], sig: Signature65): Address =
  ## Recover the Ethereum address that signed msgHash. `v` may be 27/28 or 0/1.
  var recid = int(sig[64])
  if recid >= 27: recid -= 27
  var raw: array[65, byte]          # nim-secp256k1 recoverable raw = r ++ s ++ recid(0-3)
  for i in 0 ..< 64: raw[i] = sig[i]
  raw[64] = byte(recid)
  let rs = sk.SkRecoverableSignature.fromRaw(raw)
  if rs.isErr: raise newException(Secp256k1Error, "bad recoverable signature")
  let pub = rs.get().recover(sk.SkMessage(msgHash))
  if pub.isErr: raise newException(Secp256k1Error, "recovery failed")
  addressOfPub(pub.get())

proc addressOf*(seckey: array[32, byte]): Address =
  ## The Ethereum address for a private key (for fixtures/tests).
  addressOfPub(secKey(seckey).toPublicKey())

proc signRecoverable*(msgHash: array[32, byte], seckey: array[32, byte]): Signature65 =
  ## Sign msgHash, producing an Ethereum-style 65-byte signature (v = 27 + recid).
  let rs = sk.signRecoverable(secKey(seckey), sk.SkMessage(msgHash))
  let raw = rs.toRaw()              # r ++ s ++ recid(0-3)
  for i in 0 ..< 64: result[i] = raw[i]
  result[64] = byte(27 + int(raw[64]))

proc recoversToOwner*(msgHash: array[32, byte], sig: Signature65, owners: openArray[Address]): bool =
  ## True iff the signature over msgHash recovers to one of the owners (Safe's
  ## checkSignatures, minus ordering/threshold which the collection core handles).
  let a = ecrecover(msgHash, sig)
  for o in owners:
    if o == a: return true
  false

proc pubKeyOf*(seckey: array[32, byte]): PubKey =
  ## The compressed public key for a secret — the account's public identity.
  secKey(seckey).toPublicKey().toRawCompressed()
