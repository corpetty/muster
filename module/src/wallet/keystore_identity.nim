## A keystore_module account as this member's authorization identity (exo-149.5 K5). Pure.
##
## The F-14 key binding says: this secp256k1 key and this member's encryption identity
## are the same party. Muster's own keystore signs one per approval. A keystore_module
## account cannot, because every signature it makes is a human's approval, so the binding is
## requested ONCE, when the member selects the account, and reused by every approval it
## then makes (docs/design/keystore-module-backend.md §4, option C).
##
## Its context is the account itself, scoped "keystore_module" and valid 30 days. Readers
## check what a binding names, not where it was issued: approvedByMe takes a binding whose
## statement names the member's identity and recovers to the approver, ignoring context
## and expiry, so one binding serves every room and intent until it is renewed. It
## reaches the signer as a digest leg, opaque to the human, like the attestation: the
## same flagged interim, until typed forms land (exo-149.6).

import std/[json, strutils]
import ../crypto/binding
import ../crypto/curve25519
import ../crypto/secp256k1
import ./keystore_legs
import ./keystore_requests

const
  KeystoreBindingSlot* = "keystore_module"
  KeystoreBindingTtlS* = 30 * 86_400
  RenewWithinS = 86_400        ## inside a day of expiry the binding reads "expiring"
  BindingPurpose* =
    "Muster key binding (interim): links this account to your Muster identity, so the " &
    "people in your rooms can tell its approvals are yours. Muster's own commitment, " &
    "shown as a hash; the signer cannot read it."

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)])

proc keystoreBindingContext*(account: string, now: uint64, ttl = KeystoreBindingTtlS): LinkContext =
  LinkContext(account: account.toLowerAscii(), slot: KeystoreBindingSlot, expiry: now + uint64(ttl))

proc bindingApproval*(enc: EncIdentity, ctx: LinkContext, account: string):
    tuple[intent: JsonNode, legs: seq[SignLeg]] =
  ## The one-leg request: a digest over exactly linkDigest(enc, ctx).
  let d = linkDigest(enc, ctx)
  result.intent = approvalIntent(account.toLowerAscii(), "Link this account to your Muster identity",
                                 @[digestLeg(d, BindingPurpose)])
  result.legs = @[SignLeg(kind: "binding", hash: d)]

proc bindingFromSignature*(enc: EncIdentity, ctx: LinkContext, sigHex, account: string,
                           now: uint64): LinkStatement =
  ## The binding statement, only if the returned signature recovers to `account`.
  let signer = hexOf(signerOf(linkDigest(enc, ctx), sigHex))   # raises KeystoreLegError when malformed
  if signer != account.toLowerAscii():
    raise newException(KeystoreLegError, "the binding signature does not recover to " & account)
  var sig: Signature65
  let raw = bytesOfHex(sigHex)
  for i in 0 ..< 65: sig[i] = raw[i]
  result = LinkStatement(enc: enc, ctx: ctx, sig: sig)
  try:
    if hexOf(bindingSigner(result, now)) != account.toLowerAscii():
      raise newException(KeystoreLegError, "the binding does not verify")
  except BindingError as e:
    raise newException(KeystoreLegError, e.msg)

proc bindingState*(hex, account: string, enc: EncIdentity, now: uint64): string =
  ## "none" | "valid" | "expiring" | "expired" | "invalid".
  if hex.len == 0: return "none"
  var st: LinkStatement
  try:
    st = decodeLink(bytesOfHex(hex))
  except CatchableError: return "invalid"
  if st.enc != enc: return "invalid"
  if hexOf(ecrecover(linkDigest(st.enc, st.ctx), st.sig)) != account.toLowerAscii(): return "invalid"
  if now > st.ctx.expiry: return "expired"
  if st.ctx.expiry - now < uint64(RenewWithinS): return "expiring"
  "valid"
