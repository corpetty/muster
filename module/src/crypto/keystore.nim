## Keystore — the module's persistent identity seam (FS-4, two-identity model).
##
## The module custodies TWO bound identities (F-14, ADR-010 2026-08-23):
##   • a secp256k1 **authorization** key — signs Safe transactions and the identity
##     binding (Keycard-backed in v1);
##   • an Ed25519/X25519 **encryption** identity — encrypts to members and authors
##     room messages.
## They are joined by a signed binding this keystore can issue (bindingFor). State
## is `reduce(log)` (inv 4); these keys are the *other* half of "log + keys" — never
## in the log, never in an export, never reachable by a plugin (FS-4).
##
## This is an interface on purpose, and it exposes *operations*, never a secret.
## FS-4 puts key material in "the OS keystore or Keycard", and a Keycard never
## releases its private key — it signs on the card — so sign/sealOpen are the only
## shape a real backend can slot behind. Concrete backends:
##   FileKeystore  — the stopgap: an Argon2id-encrypted keyfile on disk, both
##                   secrets held decrypted in module memory for the process life.
##   InMemoryKeystore — no persistence; for tests and raw-key call sites.

import std/[os, streams]
import ./secp256k1
import ./sodium
import ./curve25519
import ./binding

type
  KeystoreError* = object of CatchableError

  KeyRef* = string
    ## An opaque handle to ONE authorization key the keystore holds (exo-45e K2b). It is
    ## the key's address hex ("0x…") — stable and unique — never the secret. A caller
    ## selects a key by ref (`signWith`); the secret never leaves the keystore (a Keycard
    ## with several slots slots behind the same seam).

  Keystore* = ref object of RootObj
    ## The seam. Backends override every method; none exposes a secret.

proc refOf*(a: Address): KeyRef =
  const d = "0123456789abcdef"
  result = "0x"
  for b in a: (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])

method address*(ks: Keystore): Address {.base.} =
  ## The module's Ethereum address — its public authorization identity.
  raise newException(KeystoreError, "Keystore.address is abstract")

method sign*(ks: Keystore, msgHash: array[32, byte]): Signature65 {.base.} =
  ## secp256k1-sign a 32-byte hash (a safeTxHash, or a binding digest) without
  ## releasing the key. On a Keycard this happens on the card.
  raise newException(KeystoreError, "Keystore.sign is abstract")

method edSign*(ks: Keystore, msg: openArray[byte]): Ed25519Sig {.base.} =
  ## Ed25519-sign a message with the ENCRYPTION identity. This is how a member
  ## endorses an intent under a room-native driver (threshold / FROST): the
  ## contribution is the member's own signature over the intent's materialization,
  ## and the member's Ed25519 key is in the room's roster. Like sign(), the secret
  ## never leaves the keystore — a Keycard backend signs on the card.
  raise newException(KeystoreError, "Keystore.edSign is abstract")

method encIdentity*(ks: Keystore): EncIdentity {.base.} =
  ## Our public encryption identity (Ed25519 + X25519) — announced to be admitted,
  ## and what a binding vouches for.
  raise newException(KeystoreError, "Keystore.encIdentity is abstract")

method sealOpen*(ks: Keystore, sealed: seq[byte]): seq[byte] {.base.} =
  ## Open a sealed box (an epoch-key grant) addressed to our X25519 key, without
  ## releasing the key. Raises if it was not for us.
  raise newException(KeystoreError, "Keystore.sealOpen is abstract")

method bindingFor*(ks: Keystore, ctx: LinkContext): LinkStatement {.base.} =
  ## Issue the secp256k1-signed binding vouching that our encryption identity is
  ## ours — the authenticated join F-9 verifies.
  raise newException(KeystoreError, "Keystore.bindingFor is abstract")

# ── keyed operations (exo-45e K2b) ─────────────────────────────────────────────
# The keystore custodies a SET of authorization keys; a caller selects one by ref. The
# single-key methods above act on the PRIMARY key (ref == address()), so every existing
# caller is unchanged. The default keyed methods below delegate to the primary, so a
# single-key backend needs no override; a multi-key backend overrides them to route by
# ref. signWith on an unknown ref is a refusal, never a silent fall-through to another key.

method keyRefs*(ks: Keystore): seq[KeyRef] {.base.} =
  ## Every authorization key held. Default: the one primary key.
  @[refOf(ks.address())]

method hasKey*(ks: Keystore, r: KeyRef): bool {.base.} = r in ks.keyRefs()

method signWith*(ks: Keystore, r: KeyRef, msgHash: array[32, byte]): Signature65 {.base.} =
  ## secp-sign with the key named by `r`. Refuses an unknown ref (never signs with a
  ## different key than the caller chose).
  if not ks.hasKey(r): raise newException(KeystoreError, "unknown key ref: " & r)
  ks.sign(msgHash)

method edSignWith*(ks: Keystore, r: KeyRef, msg: openArray[byte]): Ed25519Sig {.base.} =
  if not ks.hasKey(r): raise newException(KeystoreError, "unknown key ref: " & r)
  ks.edSign(msg)

method bindingForKey*(ks: Keystore, r: KeyRef, ctx: LinkContext): LinkStatement {.base.} =
  if not ks.hasKey(r): raise newException(KeystoreError, "unknown key ref: " & r)
  ks.bindingFor(ctx)

# ── shared assembly ────────────────────────────────────────────────────────────

proc makeBinding(ks: Keystore, ctx: LinkContext): LinkStatement =
  ## Sign our encryption identity with our secp key via the seam's sign op — the
  ## secret never leaves the keystore (issueBinding takes a closure, not a key).
  issueBinding((proc(h: array[32, byte]): Signature65 = ks.sign(h)),
               ks.encIdentity(), ctx)

# ── FileKeystore — the Argon2id-encrypted-keyfile stopgap ──────────────────────

const
  Magic = "MKS"                      # 3-byte tag; a wrong file fails fast
  Version = 2'u8                     # v2: secp secret(32) ++ enc seed(32); v1 was secp only
  HeaderLen = 3 + 1 + PwSaltBytes    # magic ++ version ++ salt

type
  FileKey = tuple[secret: array[32, byte], enc: EncKeys, addr0: Address, path: string]
  FileKeystore* = ref object of Keystore
    secret: array[32, byte]          # secp256k1 authorization secret (PRIMARY key)
    enc: EncKeys                     # Ed25519/X25519 encryption identity (PRIMARY)
    addr0: Address
    path: string
    pass: string
    extra: seq[FileKey]              # additional keyfiles loaded into the set (K2b)

proc finish(fk: FileKeystore) =
  fk.addr0 = addressOf(fk.secret)

proc writeKeyfile(path: string, secret: array[32, byte], encSeed: array[32, byte],
                  passphrase: string) =
  var salt: array[PwSaltBytes, byte]
  let s = randomBytes(PwSaltBytes)
  for i in 0 ..< PwSaltBytes: salt[i] = s[i]
  let wrapKey = pwhashKey(passphrase, salt)
  var payload: seq[byte]
  payload.add secret
  payload.add encSeed
  let sealed = secretboxSeal(wrapKey, payload)

  let dir = parentDir(path)
  if dir.len > 0: createDir(dir)
  var blob = @[byte Magic[0], byte Magic[1], byte Magic[2], Version]
  blob.add salt
  blob.add sealed
  let fs = newFileStream(path, fmWrite)
  if fs == nil: raise newException(KeystoreError, "cannot write keyfile: " & path)
  fs.writeData(addr blob[0], blob.len)
  fs.close()
  try: setFilePermissions(path, {fpUserRead, fpUserWrite})
  except CatchableError: discard

proc readKeyfile(path, passphrase: string): (array[32, byte], array[32, byte], bool) =
  ## Returns (secpSecret, encSeed, upgradedFromV1). A v1 keyfile held only the secp
  ## secret; we mint a fresh encryption seed for it and signal an in-place upgrade,
  ## keeping the stable address while adding the encryption identity.
  let raw = readFile(path)
  if raw.len < 4 or raw[0 ..< 3] != Magic:
    raise newException(KeystoreError, "not a muster keyfile: " & path)
  let ver = byte(raw[3])
  if ver notin {1'u8, 2'u8}:
    raise newException(KeystoreError, "unsupported keyfile version")
  let hdr = 3 + 1 + PwSaltBytes
  var salt: array[PwSaltBytes, byte]
  for i in 0 ..< PwSaltBytes: salt[i] = byte(raw[4 + i])
  var sealed = newSeq[byte](raw.len - hdr)
  for i in 0 ..< sealed.len: sealed[i] = byte(raw[hdr + i])
  let wrapKey = pwhashKey(passphrase, salt)
  let opened =
    try: secretboxOpen(wrapKey, sealed)
    except SodiumError:
      raise newException(KeystoreError, "wrong passphrase or corrupt keyfile")
  var secret: array[32, byte]
  var encSeed: array[32, byte]
  if ver == 1'u8:
    if opened.len != 32:
      raise newException(KeystoreError, "v1 keyfile payload is not a 32-byte secret")
    for i in 0 ..< 32: secret[i] = opened[i]
    encSeed = randomKey()
    return (secret, encSeed, true)
  if opened.len != 64:
    raise newException(KeystoreError, "v2 keyfile payload is not 64 bytes")
  for i in 0 ..< 32: secret[i] = opened[i]
  for i in 0 ..< 32: encSeed[i] = opened[32 + i]
  (secret, encSeed, false)

proc openFileKeystore*(path, passphrase: string, secpSeed: seq[byte] = @[]): FileKeystore =
  ## Load both identities at `path`, or mint fresh ones and persist them if none
  ## exists. A v1 keyfile (secp only) is upgraded in place to add the encryption
  ## identity, preserving the address.
  ##
  ## `secpSeed` (32 bytes) seeds the secp AUTHORIZATION key when MINTING a new
  ## keyfile — so a dev/demo instance can be given a known account, e.g. an anvil
  ## Safe owner key, and thus sign Safe intents in-app AS a real on-chain owner
  ## (exo-001). It is honoured only on first mint; an existing keyfile keeps its
  ## identity. Empty ⇒ a fresh random key, the normal path.
  result = FileKeystore(path: path, pass: passphrase)
  var encSeed: array[32, byte]
  if fileExists(path):
    let (secret, seed, upgraded) = readKeyfile(path, passphrase)
    result.secret = secret
    encSeed = seed
    if upgraded: writeKeyfile(path, secret, encSeed, passphrase)
  else:
    if secpSeed.len == 32:
      for i in 0 ..< 32: result.secret[i] = secpSeed[i]
    else:
      result.secret = randomKey()
    encSeed = randomKey()
    writeKeyfile(path, result.secret, encSeed, passphrase)
  result.enc = encFromSeed(encSeed)
  result.finish()

method address*(fk: FileKeystore): Address = fk.addr0
method sign*(fk: FileKeystore, msgHash: array[32, byte]): Signature65 =
  signRecoverable(msgHash, fk.secret)
method edSign*(fk: FileKeystore, msg: openArray[byte]): Ed25519Sig =
  curve25519.edSign(fk.enc, msg)
method encIdentity*(fk: FileKeystore): EncIdentity = fk.enc.identity()
method sealOpen*(fk: FileKeystore, sealed: seq[byte]): seq[byte] =
  curve25519.sealOpen(fk.enc, sealed)
method bindingFor*(fk: FileKeystore, ctx: LinkContext): LinkStatement =
  makeBinding(fk, ctx)

proc loadKeyfile*(fk: FileKeystore, path, passphrase: string) =
  ## Add another Argon2id keyfile to the set (K2b, keyfile-set-first, open Q1). Its key
  ## becomes selectable by ref alongside the primary; the secret stays in the keystore.
  let (secret, seed, _) = readKeyfile(path, passphrase)
  fk.extra.add (secret: secret, enc: encFromSeed(seed), addr0: addressOf(secret), path: path)

method keyRefs*(fk: FileKeystore): seq[KeyRef] =
  result = @[refOf(fk.addr0)]
  for k in fk.extra: result.add refOf(k.addr0)

method signWith*(fk: FileKeystore, r: KeyRef, msgHash: array[32, byte]): Signature65 =
  if r == refOf(fk.addr0): return signRecoverable(msgHash, fk.secret)
  for k in fk.extra:
    if r == refOf(k.addr0): return signRecoverable(msgHash, k.secret)
  raise newException(KeystoreError, "unknown key ref: " & r)

method edSignWith*(fk: FileKeystore, r: KeyRef, msg: openArray[byte]): Ed25519Sig =
  if r == refOf(fk.addr0): return curve25519.edSign(fk.enc, msg)
  for k in fk.extra:
    if r == refOf(k.addr0): return curve25519.edSign(k.enc, msg)
  raise newException(KeystoreError, "unknown key ref: " & r)

# ── InMemoryKeystore — no persistence, for tests and raw-key call sites ─────────

type
  MemKey = tuple[secret: array[32, byte], enc: EncKeys, addr0: Address]
  InMemoryKeystore* = ref object of Keystore
    secret: array[32, byte]
    enc: EncKeys
    addr0: Address
    extra: seq[MemKey]              # additional keys in the set (K2b)

proc newInMemoryKeystore*(secret: array[32, byte], encSeed: array[32, byte]): InMemoryKeystore =
  InMemoryKeystore(secret: secret, enc: encFromSeed(encSeed), addr0: addressOf(secret))

proc addKey*(ik: InMemoryKeystore, secret: array[32, byte], encSeed: array[32, byte]): KeyRef =
  ## Add another authorization key to the set; returns its ref. For tests and raw-key
  ## call sites — a multi-account instance without the file backend.
  ik.extra.add (secret: secret, enc: encFromSeed(encSeed), addr0: addressOf(secret))
  refOf(addressOf(secret))

method address*(ik: InMemoryKeystore): Address = ik.addr0
method sign*(ik: InMemoryKeystore, msgHash: array[32, byte]): Signature65 =
  signRecoverable(msgHash, ik.secret)
method edSign*(ik: InMemoryKeystore, msg: openArray[byte]): Ed25519Sig =
  curve25519.edSign(ik.enc, msg)
method encIdentity*(ik: InMemoryKeystore): EncIdentity = ik.enc.identity()
method sealOpen*(ik: InMemoryKeystore, sealed: seq[byte]): seq[byte] =
  curve25519.sealOpen(ik.enc, sealed)
method bindingFor*(ik: InMemoryKeystore, ctx: LinkContext): LinkStatement =
  makeBinding(ik, ctx)

method keyRefs*(ik: InMemoryKeystore): seq[KeyRef] =
  result = @[refOf(ik.addr0)]
  for k in ik.extra: result.add refOf(k.addr0)

method signWith*(ik: InMemoryKeystore, r: KeyRef, msgHash: array[32, byte]): Signature65 =
  if r == refOf(ik.addr0): return signRecoverable(msgHash, ik.secret)
  for k in ik.extra:
    if r == refOf(k.addr0): return signRecoverable(msgHash, k.secret)
  raise newException(KeystoreError, "unknown key ref: " & r)

method edSignWith*(ik: InMemoryKeystore, r: KeyRef, msg: openArray[byte]): Ed25519Sig =
  if r == refOf(ik.addr0): return curve25519.edSign(ik.enc, msg)
  for k in ik.extra:
    if r == refOf(k.addr0): return curve25519.edSign(k.enc, msg)
  raise newException(KeystoreError, "unknown key ref: " & r)
