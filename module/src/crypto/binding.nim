## The identity binding (F-14 two-identity model, ADR-010 2026-08-23).
##
## The secp256k1 authorization key vouches for an Ed25519/X25519 encryption
## identity by signing a domain-separated statement over it. This is the
## authenticated join F-9 needs: a room member proves "the key that signs Safe
## transactions is the same actor as this encryption identity", and the core
## VERIFIES it on ingest (recovers the secp signer, checks it is a Safe owner)
## rather than trusting an asserted mapping.
##
## The statement is a signing payload in the invariant-2 sense — it commits to the
## account context and an expiry, so a binding is worthless outside its room and
## goes stale on its own — and it hashes through the invariant-5 domain-separated
## hash-input record, never ad-hoc bytes. Issuing takes a signing closure, not a
## key, so it composes with the Keystore seam (and a Keycard) without this module
## ever seeing a secret.

import ../dcbor/dcbor
import ../hashing/hash_input
import ./secp256k1
import ./curve25519

type
  LinkContext* = object
    account*: string     ## the account / room this binding is scoped to (inv 2)
    slot*: string        ## serialization slot
    expiry*: uint64      ## unix-time expiry; the binding is refused at/after this

  LinkStatement* = object
    enc*: EncIdentity    ## the encryption identity being vouched for
    ctx*: LinkContext
    sig*: Signature65    ## secp256k1 recoverable signature over linkDigest

  BindingError* = object of CatchableError

proc linkDigest*(enc: EncIdentity, ctx: LinkContext): array[32, byte] =
  ## The exact bytes the secp256k1 key signs — domain-separated, committing to both
  ## halves of the encryption identity and the full context. Change any field and
  ## these bytes change, so a binding cannot be lifted to another key or room.
  digest(hashInput("muster.identity-binding.v1", @[
    ("ed25519", cbBytes(@(enc.ed))),
    ("x25519", cbBytes(@(enc.x))),
    ("account", cbText(ctx.account)),
    ("slot", cbText(ctx.slot)),
    ("expiry", cbUint(ctx.expiry)),
  ]))

proc issueBinding*(signHash: proc(h: array[32, byte]): Signature65 {.closure.},
                   enc: EncIdentity, ctx: LinkContext): LinkStatement =
  ## Sign a binding with whatever holds the secp256k1 key (a Keystore, a Keycard).
  ## The closure is the only thing that touches the secret.
  LinkStatement(enc: enc, ctx: ctx, sig: signHash(linkDigest(enc, ctx)))

proc bindingSigner*(st: LinkStatement, now: uint64): Address =
  ## Recover the secp256k1 address that vouched for this encryption identity — or
  ## raise if the binding has expired. The caller (F-9 / admit) then checks the
  ## address against the Safe owner set. Recovery over a tampered statement yields
  ## a different address, so a forged binding simply fails the owner check.
  if now > st.ctx.expiry:
    raise newException(BindingError, "binding expired")
  ecrecover(linkDigest(st.enc, st.ctx), st.sig)

proc encodeLink*(st: LinkStatement): seq[byte] =
  ## Wire form for carrying a binding on the topic (in a join-request):
  ## enc(64) ++ accountLen(2 BE) ++ account ++ slotLen(2 BE) ++ slot ++
  ## expiry(8 BE) ++ sig(65).
  proc str(s: string): seq[byte] =
    result = @[byte((s.len shr 8) and 0xFF), byte(s.len and 0xFF)]
    for c in s: result.add byte(c)
  result = st.enc.toBytes()
  result.add str(st.ctx.account)
  result.add str(st.ctx.slot)
  let e = st.ctx.expiry
  for i in countdown(7, 0): result.add byte((e shr (8 * i)) and 0xFF)
  result.add st.sig

proc decodeLink*(b: seq[byte]): LinkStatement =
  ## Inverse of encodeLink; raises on a malformed frame.
  var off = 0
  proc take(n: int): seq[byte] =
    if off + n > b.len: raise newException(BindingError, "link frame truncated")
    result = b[off ..< off + n]; off += n
  proc str(): string =
    let n = (int(b[off]) shl 8) or int(b[off + 1]); off += 2
    let raw = take(n)
    for x in raw: result.add char(x)
  result.enc = encIdentityFromBytes(take(64))
  result.ctx.account = str()
  result.ctx.slot = str()
  let e = take(8)
  for x in e: result.ctx.expiry = (result.ctx.expiry shl 8) or uint64(x)
  let s = take(65)
  for i in 0 ..< 65: result.sig[i] = s[i]

proc bindingBinds*(st: LinkStatement, owners: openArray[Address], now: uint64): bool =
  ## True iff the binding is unexpired and its secp256k1 signer is a configured
  ## owner — i.e. this encryption identity provably belongs to a Safe owner (F-9).
  try:
    let signer = bindingSigner(st, now)
    for o in owners:
      if o == signer: return true
    false
  except BindingError:
    false
