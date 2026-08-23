## Keystore — the module's persistent identity seam (FS-4).
##
## The module needs one stable secp256k1 identity that survives restarts: the key
## it signs Safe transactions with AND — per ADR-010, one curve, no second
## identity — the key it does epoch ECDH with. State is `reduce(log)` (inv 4);
## the key is the *other* half of "log + keys", the part that is never in the log,
## never in an export, and never reachable by a plugin (FS-4).
##
## This is an interface **on purpose**, and it exposes *operations*, never the raw
## secret. FS-4 says key material lives in "the OS keystore or Keycard" — and a
## Keycard never releases its private key, it signs and does key-agreement on the
## card. So `sign`/`ecdh` are the only shape a real backend can slot behind: the
## secret stays on the far side of the seam. Concrete backends:
##
##   FileKeystore  — the stopgap here: an Argon2id-encrypted keyfile on disk, held
##                   decrypted in module memory for the process lifetime.
##   (later)       — libsecret / Secret Service, or Keycard, behind this same seam;
##                   adopting one is a backend swap, not a caller rewrite.
##
## The stopgap holds the decrypted secret in process memory, which a Keycard would
## not — that is the honest gap between it and the real thing, and the reason it is
## labelled a stopgap rather than the answer.

import std/[os, streams]
import ./secp256k1
import ./sodium

type
  KeystoreError* = object of CatchableError

  Keystore* = ref object of RootObj
    ## The seam. Backends override every method; none exposes the secret.

method address*(ks: Keystore): Address {.base.} =
  ## The module's Ethereum address — its public, in-the-clear identity.
  raise newException(KeystoreError, "Keystore.address is abstract")

method pubKey*(ks: Keystore): PubKey {.base.} =
  ## The compressed secp256k1 public key — the module's encryption identity, the
  ## same key it signs with (ADR-010: no separate encryption curve).
  raise newException(KeystoreError, "Keystore.pubKey is abstract")

method sign*(ks: Keystore, msgHash: array[32, byte]): Signature65 {.base.} =
  ## Sign a 32-byte hash (e.g. a safeTxHash) without releasing the key. On a
  ## Keycard this happens on the card; here it happens over the in-memory secret.
  raise newException(KeystoreError, "Keystore.sign is abstract")

method ecdh*(ks: Keystore, peer: PubKey): array[32, byte] {.base.} =
  ## The shared secret with a peer's public key — the ECIES key agreement the
  ## epoch layer wraps epoch keys under. Also key-agreement-without-release.
  raise newException(KeystoreError, "Keystore.ecdh is abstract")

# ── FileKeystore — the Argon2id-encrypted-keyfile stopgap ──────────────────────

const
  Magic = "MKS1"                     # 4-byte tag; a wrong file fails fast, not weirdly
  Version = 1'u8
  HeaderLen = 4 + 1 + PwSaltBytes    # magic ++ version ++ salt

type
  FileKeystore* = ref object of Keystore
    secret: array[32, byte]          # decrypted, in memory for the process lifetime
    addr0: Address
    pub: PubKey

proc finish(fk: FileKeystore) =
  ## Derive the public identity once from the loaded secret.
  fk.addr0 = addressOf(fk.secret)
  fk.pub = pubKeyOf(fk.secret)

proc writeKeyfile(path: string, secret: array[32, byte], passphrase: string) =
  var salt: array[PwSaltBytes, byte]
  let s = randomBytes(PwSaltBytes)
  for i in 0 ..< PwSaltBytes: salt[i] = s[i]
  let wrapKey = pwhashKey(passphrase, salt)
  let sealed = secretboxSeal(wrapKey, secret)

  let dir = parentDir(path)
  if dir.len > 0: createDir(dir)
  var blob = @[byte Magic[0], byte Magic[1], byte Magic[2], byte Magic[3], Version]
  blob.add salt
  blob.add sealed
  let fs = newFileStream(path, fmWrite)
  if fs == nil: raise newException(KeystoreError, "cannot write keyfile: " & path)
  fs.writeData(addr blob[0], blob.len)
  fs.close()
  # Owner-only: the ciphertext is passphrase-gated, but the file is still ours.
  try: setFilePermissions(path, {fpUserRead, fpUserWrite})
  except CatchableError: discard   # best-effort; not all filesystems honour it

proc readKeyfile(path: string, passphrase: string): array[32, byte] =
  let raw = readFile(path)
  if raw.len < HeaderLen or raw[0 ..< 4] != Magic:
    raise newException(KeystoreError, "not a muster keyfile: " & path)
  if byte(raw[4]) != Version:
    raise newException(KeystoreError, "unsupported keyfile version")
  var salt: array[PwSaltBytes, byte]
  for i in 0 ..< PwSaltBytes: salt[i] = byte(raw[5 + i])
  var sealed = newSeq[byte](raw.len - HeaderLen)
  for i in 0 ..< sealed.len: sealed[i] = byte(raw[HeaderLen + i])
  let wrapKey = pwhashKey(passphrase, salt)
  let opened =
    try: secretboxOpen(wrapKey, sealed)
    except SodiumError:
      # Poly1305 failed → wrong passphrase or a tampered file. Same signal either
      # way: the caller cannot open this identity.
      raise newException(KeystoreError, "wrong passphrase or corrupt keyfile")
  if opened.len != 32:
    raise newException(KeystoreError, "keyfile payload is not a 32-byte secret")
  for i in 0 ..< 32: result[i] = opened[i]

proc openFileKeystore*(path: string, passphrase: string): FileKeystore =
  ## Load the identity at `path`, or mint a fresh one and persist it if none exists.
  ## First run generates a random secp256k1 secret; every later run re-opens the
  ## same identity — so the module's address is stable across restarts (R-3: the
  ## key half of "log + keys").
  result = FileKeystore()
  if fileExists(path):
    result.secret = readKeyfile(path, passphrase)
  else:
    result.secret = randomKey()
    writeKeyfile(path, result.secret, passphrase)
  result.finish()

method address*(fk: FileKeystore): Address = fk.addr0
method pubKey*(fk: FileKeystore): PubKey = fk.pub
method sign*(fk: FileKeystore, msgHash: array[32, byte]): Signature65 =
  signRecoverable(msgHash, fk.secret)
method ecdh*(fk: FileKeystore, peer: PubKey): array[32, byte] =
  secp256k1.ecdh(fk.secret, peer)

# ── InMemoryKeystore — no persistence, for tests and raw-key call sites ─────────
# The same operation seam over a secret held only in memory. Persistence is what
# FileKeystore adds; this is the seam without it, so code that already holds a raw
# key (the F-16 tests, the raw-key epoch constructors) can present it as a Keystore.

type
  InMemoryKeystore* = ref object of Keystore
    secret: array[32, byte]
    addr0: Address
    pub: PubKey

proc newInMemoryKeystore*(secret: array[32, byte]): InMemoryKeystore =
  InMemoryKeystore(secret: secret, addr0: addressOf(secret), pub: pubKeyOf(secret))

method address*(ik: InMemoryKeystore): Address = ik.addr0
method pubKey*(ik: InMemoryKeystore): PubKey = ik.pub
method sign*(ik: InMemoryKeystore, msgHash: array[32, byte]): Signature65 =
  signRecoverable(msgHash, ik.secret)
method ecdh*(ik: InMemoryKeystore, peer: PubKey): array[32, byte] =
  secp256k1.ecdh(ik.secret, peer)
