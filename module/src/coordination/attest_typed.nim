## The typed (EIP-712) form of the attestation and the identity binding, for keys the
## platform holds (ADR-017, exo-149.6, slice K6b). Pure.
##
## Under Basecamp a member's secp256k1 key is a keystore_module account, and a person
## approves every signature in the platform's signer, which renders an EIP-712 document
## field by field and a bare 32-byte digest only as an opaque hash. So the attestation over
## P (invariants 2 and 10) and the identity binding (F-14 / F-9) are signed as typed data
## under a Muster domain, which a person reads line by line.
##
## The dCBOR records stay the source of truth (invariant 5). A typed document carries
## their digest (`payload = keccak256(P)`, `statement = linkDigest`) and a rendering of the
## fields a person needs. A verifier never reads the rendering from a signature or a
## message: it rebuilds the document from what it recomputed from the log (the context, the
## materialization root, the count of accounted inputs, P itself) and recovers the signer
## over that document's hash. A signature over any other rendering recovers to someone else
## and is refused, so what the person read is what was attested.
##
## Two forms, never confused: `hash-input` (keccak256(P), or linkDigest, signed raw: keys
## muster holds) and `eip712` (this file). The EIP-712 hash is
## keccak256(0x19 0x01 ‖ domainSeparator ‖ hashStruct), which no hash-input digest can
## equal short of a keccak collision; the probes hold that both ways.

import std/[json, strutils]
import ../intents/signing_payload   # SigningContext
import ../crypto/[secp256k1, curve25519, binding]
import ../hashing/keccak256
import ../wallet/keystore_legs      # typedDataHash: EIP-712 over flat structs
from ./attest import isPlaceholder

type AttestForm* = enum
  afHashInput = "hash-input"   ## keccak256(P) / linkDigest, signed raw
  afEip712 = "eip712"          ## the Muster typed document

const
  MusterDomainName* = "Muster"
  MusterDomainVersion* = "1"

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)])

proc eip155ChainId*(environment: string): tuple[ok: bool, id: uint64] =
  ## The EIP-155 chain id an `eip155:<id>` environment names; ok = false for any other
  ## environment (a room, a Bitcoin network, a LEZ zone), whose domain carries no chainId.
  if not environment.startsWith("eip155:"): return (false, 0'u64)
  let digits = environment["eip155:".len .. ^1]
  if digits.len == 0 or digits.len > 19 or not digits.allCharsInSet(Digits): return (false, 0'u64)
  try:
    let id = parseBiggestUInt(digits)
    if id == 0: (false, 0'u64) else: (true, uint64(id))
  except ValueError: (false, 0'u64)

proc musterDomain(environment: string): tuple[fields, domain: JsonNode] =
  ## {name: "Muster", version: "1", chainId?}. chainId only for an eip155 environment; no
  ## verifyingContract, since nothing on chain verifies these.
  result.fields = %*[{"name": "name", "type": "string"}, {"name": "version", "type": "string"}]
  result.domain = %*{"name": MusterDomainName, "version": MusterDomainVersion}
  let c = eip155ChainId(environment)
  if c.ok:
    result.fields.add %*{"name": "chainId", "type": "uint256"}
    result.domain["chainId"] = %($c.id)

# ── the attestation ──────────────────────────────────────────────────────────────

proc attestationTypedData*(ctx: SigningContext, materialization: openArray[byte],
                           inputs: int, p: openArray[byte]): JsonNode =
  ## The EIP-712 document a platform-held key signs to attest P: the four context fields
  ## (invariant 2), the materialization root (the safeTxHash for a Safe), how many accounted
  ## inputs P's provenance record names (invariant 10), and payload = keccak256(P).
  ## uint values go as decimal strings (JSON numbers lose precision above 2^53).
  let (fields, domain) = musterDomain(ctx.environment)
  %*{
    "types": {
      "EIP712Domain": fields,
      "MusterAttestation": [
        {"name": "environment", "type": "string"},
        {"name": "account", "type": "string"},
        {"name": "slot", "type": "string"},
        {"name": "expiry", "type": "uint64"},
        {"name": "materialization", "type": "bytes"},
        {"name": "inputs", "type": "uint32"},
        {"name": "payload", "type": "bytes32"}]},
    "primaryType": "MusterAttestation",
    "domain": domain,
    "message": {
      "environment": ctx.environment, "account": ctx.account, "slot": ctx.slot,
      "expiry": $ctx.expiry, "materialization": hexOf(materialization),
      "inputs": $inputs, "payload": hexOf(keccak256(@p))}}

proc attestationTypedHash*(ctx: SigningContext, materialization: openArray[byte],
                           inputs: int, p: openArray[byte]): array[32, byte] =
  ## What a platform-held key signs for the attestation: the document's EIP-712 hash.
  typedDataHash(attestationTypedData(ctx, materialization, inputs, p))

proc recoversTo(who: string, hash: array[32, byte], sigHex: string): bool =
  ## Does `sigHex` (65 bytes, r‖s‖v) recover over `hash` to `who`: a "0x…" address, or a
  ## compressed secp256k1 key (a Bitcoin signer, as attest.verifyAttestation names one).
  var sig: Signature65
  try:
    let b = bytesOfHex(sigHex)
    if b.len != 65: return false
    for i in 0 ..< 65: sig[i] = b[i]
    if who.startsWith("0x"):
      let a = bytesOfHex(who)
      if a.len != 20: return false
      var owner: Address
      for i in 0 ..< 20: owner[i] = a[i]
      return ecrecover(hash, sig) == owner
    if who.len == 66 and who[0 .. 1] in ["02", "03"]:
      return ecrecover(hash, sig) == addressOfCompressed(bytesOfHex(who))
  except CatchableError: discard
  false

proc verifyTypedAttestation*(who: string, ctx: SigningContext, materialization: openArray[byte],
                             inputs: int, p: openArray[byte], sigHex: string): bool =
  ## Does `sigHex` attest P as `who` in the typed form? Every argument is what the verifier
  ## recomputed from the log, never what the attester claimed: the document is rebuilt from
  ## them, so a signature over a different rendering (any field, the payload, the domain)
  ## recovers to another address and is refused. An empty P (an intent that cannot be
  ## attested) never verifies.
  if p.len == 0 or ctx.isPlaceholder: return false
  let h = try: attestationTypedHash(ctx, materialization, inputs, p)
          except KeystoreLegError: return false
  recoversTo(who, h, sigHex)

# ── the identity binding ─────────────────────────────────────────────────────────

proc bindingTypedData*(enc: EncIdentity, ctx: LinkContext): JsonNode =
  ## The EIP-712 document a platform-held key signs to bind this encryption identity (F-14):
  ## both halves of it, the binding's context, and statement = linkDigest(enc, ctx). A
  ## binding names no environment, so its domain carries no chainId.
  let (fields, domain) = musterDomain("")
  %*{
    "types": {
      "EIP712Domain": fields,
      "MusterIdentityBinding": [
        {"name": "ed25519", "type": "bytes32"},
        {"name": "x25519", "type": "bytes32"},
        {"name": "account", "type": "string"},
        {"name": "slot", "type": "string"},
        {"name": "expiry", "type": "uint64"},
        {"name": "statement", "type": "bytes32"}]},
    "primaryType": "MusterIdentityBinding",
    "domain": domain,
    "message": {
      "ed25519": hexOf(enc.ed), "x25519": hexOf(enc.x),
      "account": ctx.account, "slot": ctx.slot, "expiry": $ctx.expiry,
      "statement": hexOf(linkDigest(enc, ctx))}}

proc bindingTypedHash*(enc: EncIdentity, ctx: LinkContext): array[32, byte] =
  typedDataHash(bindingTypedData(enc, ctx))

proc typedBindingSigner*(st: LinkStatement, now: uint64): Address =
  ## The secp256k1 address that vouched for st.enc in the typed form, or raise
  ## BindingError if the binding has expired: binding.bindingSigner's counterpart.
  if now > st.ctx.expiry: raise newException(BindingError, "binding expired")
  ecrecover(bindingTypedHash(st.enc, st.ctx), st.sig)

proc bindingSignerAs*(form: AttestForm, st: LinkStatement, now: uint64): Address =
  ## The binding's signer under the form its event names: each form recovers over its own
  ## hash only, so a statement signed in one form never recovers its signer in the other.
  case form
  of afHashInput: bindingSigner(st, now)
  of afEip712: typedBindingSigner(st, now)
