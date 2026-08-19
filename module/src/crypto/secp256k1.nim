## secp256k1 ECDSA recovery + Ethereum address derivation (P2).
##
## Safe's checkSignatures recovers the signer address from an owner's ECDSA
## signature over the safeTxHash and checks it against the owner set. This is the
## FFI over libsecp256k1's recovery module that the Safe driver's verify() uses.
## Linking is caller/flake-provided (the module build supplies secp256k1 via
## nix.packages); no library path is baked in here.

import ../hashing/keccak256

type
  Secp256k1Error* = object of CatchableError
  Address* = array[20, byte]
  Signature65* = array[65, byte]   ## r(32) ++ s(32) ++ v(1)

  secp256k1_context = object
  secp256k1_pubkey = object
    data: array[64, byte]
  secp256k1_ecdsa_recoverable_signature = object
    data: array[65, byte]

{.push importc, cdecl.}
proc secp256k1_context_create(flags: cuint): ptr secp256k1_context
proc secp256k1_ecdsa_recoverable_signature_parse_compact(
  ctx: ptr secp256k1_context, sig: ptr secp256k1_ecdsa_recoverable_signature,
  input64: ptr byte, recid: cint): cint
proc secp256k1_ecdsa_recover(
  ctx: ptr secp256k1_context, pubkey: ptr secp256k1_pubkey,
  sig: ptr secp256k1_ecdsa_recoverable_signature, msg32: ptr byte): cint
proc secp256k1_ec_pubkey_serialize(
  ctx: ptr secp256k1_context, output: ptr byte, outputlen: ptr csize_t,
  pubkey: ptr secp256k1_pubkey, flags: cuint): cint
# Helpers used for self-consistent testing (sign, derive pubkey).
proc secp256k1_ec_pubkey_create(
  ctx: ptr secp256k1_context, pubkey: ptr secp256k1_pubkey, seckey: ptr byte): cint
proc secp256k1_ecdsa_sign_recoverable(
  ctx: ptr secp256k1_context, sig: ptr secp256k1_ecdsa_recoverable_signature,
  msg32: ptr byte, seckey: ptr byte, noncefp: pointer, ndata: pointer): cint
proc secp256k1_ecdsa_recoverable_signature_serialize_compact(
  ctx: ptr secp256k1_context, output64: ptr byte, recid: ptr cint,
  sig: ptr secp256k1_ecdsa_recoverable_signature): cint
{.pop.}

const
  SECP256K1_CONTEXT_NONE = cuint(1)
  SECP256K1_EC_UNCOMPRESSED = cuint(2)

var ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE)

proc pubkeyToAddress(pub: ptr secp256k1_pubkey): Address =
  var out65: array[65, byte]
  var outlen = csize_t(65)
  discard secp256k1_ec_pubkey_serialize(ctx, addr out65[0], addr outlen, pub, SECP256K1_EC_UNCOMPRESSED)
  # Ethereum address = last 20 bytes of keccak256 of the 64-byte pubkey (drop 0x04).
  var body: array[64, byte]
  for i in 0 ..< 64: body[i] = out65[i+1]
  let kh = keccak256(body)
  for i in 0 ..< 20: result[i] = kh[12+i]

proc ecrecover*(msgHash: array[32, byte], sig: Signature65): Address =
  ## Recover the Ethereum address that signed msgHash. `v` may be 27/28 or 0/1.
  var recid = cint(sig[64])
  if recid >= 27: recid -= 27
  var input64: array[64, byte]
  for i in 0 ..< 64: input64[i] = sig[i]
  var rsig: secp256k1_ecdsa_recoverable_signature
  if secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, addr rsig, addr input64[0], recid) != 1:
    raise newException(Secp256k1Error, "bad recoverable signature")
  var msg = msgHash
  var pub: secp256k1_pubkey
  if secp256k1_ecdsa_recover(ctx, addr pub, addr rsig, addr msg[0]) != 1:
    raise newException(Secp256k1Error, "recovery failed")
  pubkeyToAddress(addr pub)

proc addressOf*(seckey: array[32, byte]): Address =
  ## The Ethereum address for a private key (for fixtures/tests).
  var sk = seckey
  var pub: secp256k1_pubkey
  if secp256k1_ec_pubkey_create(ctx, addr pub, addr sk[0]) != 1:
    raise newException(Secp256k1Error, "invalid secret key")
  pubkeyToAddress(addr pub)

proc signRecoverable*(msgHash: array[32, byte], seckey: array[32, byte]): Signature65 =
  ## Sign msgHash, producing an Ethereum-style 65-byte signature (v = 27 + recid).
  var msg = msgHash
  var sk = seckey
  var rsig: secp256k1_ecdsa_recoverable_signature
  if secp256k1_ecdsa_sign_recoverable(ctx, addr rsig, addr msg[0], addr sk[0], nil, nil) != 1:
    raise newException(Secp256k1Error, "signing failed")
  var out64: array[64, byte]
  var recid: cint
  discard secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, addr out64[0], addr recid, addr rsig)
  for i in 0 ..< 64: result[i] = out64[i]
  result[64] = byte(27 + recid)

proc recoversToOwner*(msgHash: array[32, byte], sig: Signature65, owners: openArray[Address]): bool =
  ## True iff the signature over msgHash recovers to one of the owners (Safe's
  ## checkSignatures, minus ordering/threshold which the collection core handles).
  let a = ecrecover(msgHash, sig)
  for o in owners:
    if o == a: return true
  false
