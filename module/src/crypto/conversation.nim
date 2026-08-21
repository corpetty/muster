## ConversationCrypto — the room's encryption + membership seam (F-16, ADR-010).
##
## The coordination layer seals every outbound envelope through this and opens
## inbound ones through it; it never touches keys directly. Two things live behind
## the seam together, because they are inseparable: **who is in the room** and
## **the key that encrypts to them**. Membership changes re-key (F-16).
##
## This is an interface on purpose. Per ADR-010 (as amended), our
## `EpochCrypto` — ECIES-secp256k1 wrap of a per-epoch key to each member,
## re-keyed on membership change — is an explicit **stopgap**. The identity model
## (FS-7, reframed) is persistent, room-scoped identity, which native
## `logos-chat-module` already provides via MLS; once it ships persistence +
## member removal, it binds *here* and our stopgap is deleted. Keeping the
## coordination layer on this interface makes that a binding change, not a rewrite.
##
## Payloads are opaque both above and below: the Transport carries sealed bytes it
## never reads, and this layer seals bytes it never interprets.

import ./secp256k1   # PubKey — a member's identity is their secp256k1 key (no second curve)

type
  Member* = PubKey

  ConversationCrypto* = ref object of RootObj
    ## The seam. Concrete impls (EpochCrypto stopgap now; a chat-module-backed one
    ## later) override every method.

method seal*(cc: ConversationCrypto, plaintext: seq[byte]): seq[byte] {.base, gcsafe.} =
  ## Encrypt a payload to the room's current member set at the current epoch. The
  ## result is what the Transport publishes.
  raise newException(CatchableError, "ConversationCrypto.seal is abstract")

method open*(cc: ConversationCrypto, envelope: seq[byte]): seq[byte] {.base, gcsafe.} =
  ## Decrypt an inbound envelope. Returns the plaintext if we hold a key for the
  ## envelope's epoch; raises if we do not (a member who joined later cannot open
  ## an earlier epoch — F-16). The caller treats a raise as "not for me / not yet".
  raise newException(CatchableError, "ConversationCrypto.open is abstract")

method addMember*(cc: ConversationCrypto, member: Member) {.base, gcsafe.} =
  ## Re-key forward: open a new epoch the added member receives. They get only the
  ## new epoch key, never the prior ones — so they cannot decrypt earlier messages
  ## (F-16 forward secrecy for joiners; the property the F-16 test asserts).
  raise newException(CatchableError, "ConversationCrypto.addMember is abstract")

method removeMember*(cc: ConversationCrypto, member: Member) {.base, gcsafe.} =
  ## Rotate: open a new epoch wrapped to the remaining members only, so the removed
  ## member cannot read anything sent after their removal (F-16 removal).
  raise newException(CatchableError, "ConversationCrypto.removeMember is abstract")

method members*(cc: ConversationCrypto): seq[Member] {.base, gcsafe.} =
  ## The current member set (the current epoch's recipients).
  raise newException(CatchableError, "ConversationCrypto.members is abstract")

method epoch*(cc: ConversationCrypto): int {.base, gcsafe.} =
  ## The current epoch index — monotonic, incremented on every membership change.
  raise newException(CatchableError, "ConversationCrypto.epoch is abstract")
