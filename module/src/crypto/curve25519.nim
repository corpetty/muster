## The encryption/chat identity (F-14, two-identity model, ADR-010 2026-08-23).
##
## One Ed25519 key authenticates and authors room messages; X25519 (derived from
## it) does key agreement. This is deliberately the SAME shape as the platform
## chat/account layer (libchat: Ed25519 account, X25519 DH), so the secp↔encryption
## binding we sign over the Ed25519 key (see binding.nim) is exactly what consuming
## native chat later needs — the curve gap becomes a bridge.
##
## Grants are wrapped with libsodium sealed boxes, which ARE ECIES over X25519:
## an ephemeral X25519 key + crypto_box AEAD to the recipient's X25519 key. Only
## the recipient can open one, and it carries no sender identity — the wrapper is
## anonymous, which the epoch layer relies on. All primitives are libsodium; the
## secret never needs to leave a keystore that holds it.

type Curve25519Error* = object of CatchableError

{.push importc, cdecl.}
proc crypto_sign_seed_keypair(pk, sk, seed: ptr byte): cint
proc crypto_sign_detached(sig: ptr byte, siglen: ptr culonglong, m: ptr byte,
                          mlen: culonglong, sk: ptr byte): cint
proc crypto_sign_verify_detached(sig, m: ptr byte, mlen: culonglong, pk: ptr byte): cint
proc crypto_sign_ed25519_pk_to_curve25519(x25519_pk, ed25519_pk: ptr byte): cint
proc crypto_sign_ed25519_sk_to_curve25519(x25519_sk, ed25519_sk: ptr byte): cint
proc crypto_box_seal(c, m: ptr byte, mlen: culonglong, pk: ptr byte): cint
proc crypto_box_seal_open(m, c: ptr byte, clen: culonglong, pk, sk: ptr byte): cint
{.pop.}

const
  EdPubBytes* = 32
  EdSecBytes = 64          # libsodium ed25519 secret = seed(32) ++ pubkey(32)
  EdSigBytes* = 64
  XPubBytes* = 32
  XSecBytes = 32
  SealBytes = 48           # crypto_box_SEALBYTES: ephemeral pk(32) ++ MAC(16)

type
  Ed25519Pub* = array[EdPubBytes, byte]   ## the authentication/chat identity (bound to the secp key)
  Ed25519Sig* = array[EdSigBytes, byte]
  X25519Pub* = array[XPubBytes, byte]     ## the key-agreement identity (grants are wrapped to this)

  EncIdentity* = object
    ## A member's public encryption identity: the Ed25519 key we bind and the
    ## X25519 key we wrap to. X25519 is derived from Ed25519, so they are one
    ## identity in two forms — announcing both is a convenience, not a second key.
    ed*: Ed25519Pub
    x*: X25519Pub

  EncKeys* = object
    ## The local encryption keypair (both curves). Held behind a keystore; the
    ## secrets never leave it in the shipping design.
    edPk: Ed25519Pub
    edSk: array[EdSecBytes, byte]
    xPk: X25519Pub
    xSk: array[XSecBytes, byte]

proc encFromSeed*(seed: array[32, byte]): EncKeys =
  ## Deterministically derive the encryption identity from a 32-byte seed — so it
  ## persists across restarts from the same stored seed, exactly like the secp key.
  var s = seed
  if crypto_sign_seed_keypair(addr result.edPk[0], addr result.edSk[0], addr s[0]) != 0:
    raise newException(Curve25519Error, "ed25519 keygen failed")
  if crypto_sign_ed25519_pk_to_curve25519(addr result.xPk[0], addr result.edPk[0]) != 0:
    raise newException(Curve25519Error, "ed25519->x25519 pk conversion failed")
  if crypto_sign_ed25519_sk_to_curve25519(addr result.xSk[0], addr result.edSk[0]) != 0:
    raise newException(Curve25519Error, "ed25519->x25519 sk conversion failed")

proc identity*(k: EncKeys): EncIdentity = EncIdentity(ed: k.edPk, x: k.xPk)

proc edSign*(k: EncKeys, msg: openArray[byte]): Ed25519Sig =
  var m = @msg
  let mp = if m.len > 0: addr m[0] else: nil
  if crypto_sign_detached(addr result[0], nil, mp, culonglong(m.len), addr k.edSk[0]) != 0:
    raise newException(Curve25519Error, "ed25519 sign failed")

proc edVerify*(edPk: Ed25519Pub, msg: openArray[byte], sig: Ed25519Sig): bool =
  var m = @msg
  var s = sig
  var p = edPk
  let mp = if m.len > 0: addr m[0] else: nil
  crypto_sign_verify_detached(addr s[0], mp, culonglong(m.len), addr p[0]) == 0

proc sealTo*(recipient: X25519Pub, plaintext: openArray[byte]): seq[byte] =
  ## ECIES-wrap to a recipient's X25519 key (a sealed box: ephemeral key + AEAD).
  ## Anonymous — the output names no sender.
  var pt = @plaintext
  var pk = recipient
  result = newSeq[byte](pt.len + SealBytes)
  let mp = if pt.len > 0: addr pt[0] else: nil
  if crypto_box_seal(addr result[0], mp, culonglong(pt.len), addr pk[0]) != 0:
    raise newException(Curve25519Error, "seal failed")

proc sealOpen*(k: EncKeys, sealed: openArray[byte]): seq[byte] =
  ## Open a sealed box addressed to us. Raises if it was not for us or was tampered
  ## (the caller treats a raise as "not for me"). Reuses eciesUnwrap's contract.
  if sealed.len < SealBytes:
    raise newException(Curve25519Error, "sealed box too short")
  var c = @sealed
  var pk = k.xPk
  var sk = k.xSk
  result = newSeq[byte](c.len - SealBytes)
  let mp = if result.len > 0: addr result[0] else: nil
  if crypto_box_seal_open(mp, addr c[0], culonglong(c.len), addr pk[0], addr sk[0]) != 0:
    raise newException(Curve25519Error, "seal open failed (not for us or tampered)")
