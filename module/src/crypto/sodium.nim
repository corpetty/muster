## libsodium binding — the authenticated symmetric cipher under the epoch layer's
## ECIES (F-16). We bind `crypto_secretbox` (XSalsa20-Poly1305 AEAD) rather than
## hand-roll a cipher: on the signing/encryption path we lean on a vetted library,
## the same way we consume secp256k1. Symbols resolve at link (the module build
## adds libsodium via nix.packages); ABI-stable, so no header is needed.

type SodiumError* = object of CatchableError

{.push importc, cdecl.}
proc sodium_init(): cint
proc crypto_secretbox_easy(c, m: ptr byte, mlen: culonglong, n, k: ptr byte): cint
proc crypto_secretbox_open_easy(m, c: ptr byte, clen: culonglong, n, k: ptr byte): cint
proc randombytes_buf(buf: pointer, size: csize_t)
{.pop.}

const
  KeyBytes* = 32
  NonceBytes = 24
  MacBytes = 16

# One-time init (thread-safe, idempotent in libsodium). Runs at module load.
discard sodium_init()

proc randomBytes*(n: int): seq[byte] =
  result = newSeq[byte](n)
  if n > 0: randombytes_buf(addr result[0], csize_t(n))

proc randomKey*(): array[32, byte] =
  randombytes_buf(addr result[0], csize_t(32))

proc secretboxSeal*(key: array[32, byte], plaintext: openArray[byte]): seq[byte] =
  ## AEAD encrypt. Output is nonce(24) ++ (MAC(16) ++ ciphertext) — self-contained,
  ## a fresh random nonce every call.
  var nonce: array[NonceBytes, byte]
  randombytes_buf(addr nonce[0], csize_t(NonceBytes))
  var m = @plaintext
  var k = key
  var ct = newSeq[byte](m.len + MacBytes)
  let mp = if m.len > 0: addr m[0] else: nil
  if crypto_secretbox_easy(addr ct[0], mp, culonglong(m.len), addr nonce[0], addr k[0]) != 0:
    raise newException(SodiumError, "secretbox seal failed")
  result = @nonce & ct

proc secretboxOpen*(key: array[32, byte], sealed: openArray[byte]): seq[byte] =
  ## AEAD decrypt + verify. Raises if the key is wrong or the bytes were tampered
  ## (Poly1305 authentication) — the caller treats a raise as "not for me".
  if sealed.len < NonceBytes + MacBytes:
    raise newException(SodiumError, "sealed payload too short")
  var nonce: array[NonceBytes, byte]
  for i in 0 ..< NonceBytes: nonce[i] = sealed[i]
  let ctLen = sealed.len - NonceBytes
  var ct = newSeq[byte](ctLen)
  for i in 0 ..< ctLen: ct[i] = sealed[NonceBytes + i]
  var k = key
  var m = newSeq[byte](ctLen - MacBytes)
  let mp = if m.len > 0: addr m[0] else: nil
  if crypto_secretbox_open_easy(mp, addr ct[0], culonglong(ctLen), addr nonce[0], addr k[0]) != 0:
    raise newException(SodiumError, "secretbox open failed (wrong key or tampered)")
  m
