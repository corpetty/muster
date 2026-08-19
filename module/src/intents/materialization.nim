## Effect → materialization, and the unconditional re-derive-or-refuse check
## (spec: contracts/specs/derived-exo-8e7.spec.json, invariant 1, catastrophic).
##
## Participants review a semantic *effect*; what gets signed is its
## *materialization* — the concrete bytes a driver canonicalizes the effect into.
## A proposal carries a *claimed* materialization that may have been tampered in
## transit. Before signing, the core independently re-derives the materialization
## from the reviewed effect (local, deterministic code — never the transmitted
## copy) and refuses on any mismatch. This check is unconditional: no flag,
## plugin, or preference can turn it off (FS-6).

import ../dcbor/dcbor
import ../drivers/driver

type
  Effect* = object
    schemaId*: string                    ## e.g. "muster.effect.transfer.v1"
    fields*: seq[(string, CborValue)]

  Materialization* = object
    bytes*: seq[byte]

proc canonicalize*(driver: Driver, e: Effect): Materialization =
  ## Deterministic serialization of the effect under the driver's declared
  ## serialization domain (invariant 6: the domain is driver-described). The stub
  ## uses dCBOR; a real driver (Safe) computes its EIP-712 encoding here. Because
  ## it is pure local code, re-running it is the trustworthy derivation.
  let domain = driver.describe().serializationDomain
  var pairs: seq[(CborValue, CborValue)]
  for (k, v) in e.fields: pairs.add (cbText(k), v)
  Materialization(bytes: encode(cbArray(@[
    cbText(domain), cbText(e.schemaId), cbMap(pairs)])))

proc reviewAndCheck*(driver: Driver, e: Effect, claimed: Materialization): bool =
  ## Re-derive from the reviewed effect and compare to the claimed copy. True iff
  ## they are byte-identical. The one gate every signature passes through.
  canonicalize(driver, e).bytes == claimed.bytes

# ── The signing entry point, and a config surface that cannot bypass the check ─
type
  Config* = object
    ## A representative configuration surface. NONE of these gate the
    ## materialization check — they exist so a probe can prove no reachable config
    ## value bypasses it.
    skipReviewRequested*: bool
    plugins*: seq[string]
    userPreference*: string

  SignOutcome* = enum
    soRefused, soSigned

proc signProposal*(cfg: Config, driver: Driver, e: Effect,
                   claimed: Materialization): SignOutcome =
  ## The materialization check runs unconditionally before signing, regardless of
  ## any config field. There is deliberately no branch consulting `cfg` to skip
  ## it — the check lives in the core and cannot be disabled.
  if not reviewAndCheck(driver, e, claimed):
    return soRefused
  soSigned
