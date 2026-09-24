## Signers outside muster, as a driver seam (exo-a50.2.6; seam S8 of
## docs/design/multisig-landscape.md — interop codecs).
##
## Decision 2026-09-23: outside signers where it makes sense, always surfaced. A driver
## whose family has a format other signers speak (a Bitcoin multisig: PSBT) EXPORTS a
## proposal's effect in it and IMPORTS what comes back — every signature it finds
## becomes a contribution the SAME driver verifies like a native one. The seam never
## signs and never holds a key (invariant 3); the live path publishes an import as a
## pasted approval, so the room grades it "signed outside muster" (unattested), never
## committed. A driver that does not override the seam has no outside format — said,
## never guessed.

import ../intents/materialization
import ./driver

type
  InteropError* = object of CatchableError        ## not a response at all (unparseable)
  InteropMismatch* = object of InteropError       ## a response to a DIFFERENT request

  ImportedContribution* = tuple[signer: string, contribution: Contribution]
    ## one outside signer's contribution, as the fold expects it, and who the driver says made it

  OutsideRequest* = object
    handled*: bool     ## false = this driver has no outside-signer format
    format*: string    ## "psbt"
    encoded*: string   ## the request an outside signer takes (a base64 PSBT)

method exportOutside*(d: Driver, e: Effect): OutsideRequest {.base.} =
  OutsideRequest(handled: false)

method importOutside*(d: Driver, e: Effect, encoded: string): seq[ImportedContribution] {.base.} =
  ## Every contribution the driver can read from an outside signer's response to THIS
  ## effect's request. Raises InteropError when the response is not one (unparseable,
  ## or a request for a different effect) — never a partial import.
  raise newException(InteropError, "this driver has no outside-signer format")
