## EIP-191 personal-sign driver — a Tier-1 (module-native) driver beyond Safe
## (muster epic exo-fa4, P-D6: validating the driver-derivation skeleton path).
##
## Where the Safe driver signs EIP-712 typed data (a safeTxHash), this driver signs
## an EIP-191 `personal_sign` message: the room's signers each personal-sign an
## agreed effect, and a contribution counts only if its 65-byte secp256k1 signature
## recovers to a configured signer. It settles nothing on-chain — it is a signed
## group ATTESTATION (finImmediate), the "we, these keys, assert this" primitive a
## great many modules verify (any contract or service that checks `ecrecover` over a
## personal_sign digest).
##
## It is the worked completion of the Tier-1 skeleton `lidl-gen driver` emits: the
## two procs the generic dCBOR path can't provide — a module-native `canonicalize`
## (the EIP-191 digest, NOT a generic dCBOR array) and a module-native
## `verifyContribution` (secp `ecrecover` to a signer set, NOT an Ed25519 roster) —
## are the ones implemented here, against the Safe driver as the reference. It grades
## identically under `checkConformance` (a driver that doesn't conform doesn't ship).

import ../hashing/keccak256
import ../dcbor/dcbor
import ../drivers/driver
import ../intents/materialization
import ../crypto/secp256k1   # Address, Signature65, ecrecover, recoversToOwner
export secp256k1.Address, secp256k1.Signature65

const EIP191_DOMAIN* = "eip191.personal_sign.v1"

proc strBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc effectMessage*(e: Effect, domain: string): seq[byte] =
  ## The deterministic message the signers personal-sign: the effect's dCBOR under
  ## this driver's domain — byte-identical to the base serialization's shape
  ## (invariant 5), so re-derivation is exact. This is what a verifying module would
  ## reconstruct to check the signature.
  var pairs: seq[(CborValue, CborValue)]
  for (k, v) in e.fields: pairs.add (cbText(k), v)
  encode(cbArray(@[cbText(domain), cbText(e.schemaId), cbMap(pairs)]))

proc eip191Digest*(msg: seq[byte]): array[32, byte] =
  ## keccak256("\x19Ethereum Signed Message:\n" & len(msg) & msg) — the EIP-191
  ## personal_sign digest. The `\x19` prefix is what makes a personal_sign signature
  ## unusable as a raw-transaction signature, and vice versa (domain separation at
  ## the signing-scheme level, distinct from Safe's EIP-712 `0x19 0x01`).
  let prefix = strBytes("\x19Ethereum Signed Message:\n" & $msg.len)
  keccak256(prefix & msg)

# ── The driver: 1-round, named-membership, immediate-finality; canonicalize is the
# EIP-191 digest, verify is secp ecrecover to a configured signer set. ───────────
type PersonalSignDriver* = ref object of Driver
  signers*: seq[Address]             ## the keys whose personal_sign counts
  threshold*: int
  pendingDigest*: array[32, byte]    ## the EIP-191 digest currently being collected

method describe*(d: PersonalSignDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: EIP191_DOMAIN,
                   membership: mmNamed, finality: finImmediate, threshold: d.threshold)

method canonicalize*(d: PersonalSignDriver, e: Effect): Materialization =
  ## Override: the materialization is the EIP-191 personal_sign digest of the effect.
  ## Recording it as the pending digest lets verifyContribution check signatures
  ## against it. Dispatched through the Driver seam like Safe's safeTxHash.
  let digest = eip191Digest(effectMessage(e, EIP191_DOMAIN))
  d.pendingDigest = digest
  Materialization(bytes: @digest)

method verifyContribution*(d: PersonalSignDriver, c: Contribution, round: int): bool =
  ## A contribution is a 65-byte secp256k1 signature over the pending digest. The
  ## core never reads these bytes (invariant 6); only the driver does, here.
  if c.bytes.len != 65: return false
  var sig: Signature65
  for i in 0 ..< 65: sig[i] = c.bytes[i]
  recoversToOwner(d.pendingDigest, sig, d.signers)

proc mBytes32(m: Materialization): array[32, byte] =
  for i in 0 ..< min(32, m.bytes.len): result[i] = m.bytes[i]

method expectMaterialization*(d: PersonalSignDriver, m: Materialization) =
  ## The fold's per-intent hook: contributions now verify against this digest.
  d.pendingDigest = mBytes32(m)

method identifyContributor*(d: PersonalSignDriver, m: Materialization, c: Contribution): string =
  ## Recover the signer address that produced this signature, as hex — or "" if it
  ## does not recover to a configured signer. How the fold keys a contribution and
  ## rejects a non-signer without the core reading bytes.
  if c.bytes.len != 65: return ""
  let h = mBytes32(m)
  var sig: Signature65
  for i in 0 ..< 65: sig[i] = c.bytes[i]
  if not recoversToOwner(h, sig, d.signers): return ""
  const hexd = "0123456789abcdef"
  result = "0x"
  for b in ecrecover(h, sig): (result.add hexd[int(b shr 4)]; result.add hexd[int(b and 0x0F)])

proc newPersonalSignDriver*(signers: seq[Address] = @[], threshold = 2): PersonalSignDriver =
  PersonalSignDriver(signers: signers, threshold: threshold)
