## In-app signing through the keystore, as a driver hook (exo-a50.2.4).
##
## When a member approves IN-APP, the live path asks the intent's driver to produce the
## contribution with the member's keystore — a seam, not a branch on the concrete driver
## type. A driver that does not override it is signed the classic way by the live path
## (the Safe / EIP-191 secp digest, the room drivers' Ed25519). The keystore only ever
## performs operations; no key leaves it (FS-4).

import ../intents/materialization
import ../crypto/keystore
import ./driver

type InAppSig* = object
  handled*: bool          ## false = the driver leaves in-app signing to the live path
  contribution*: seq[byte] ## the contribution bytes, as the fold expects them
  attestation*: seq[byte]  ## a secp256k1 recoverable signature over the attestation digest
  keyRef*: string          ## the secp key it signed with (for the F-14 binding)

method signInApp*(d: Driver, e: Effect, ks: Keystore, attestDigest: array[32, byte]): InAppSig {.base.} =
  InAppSig(handled: false)
