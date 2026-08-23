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

method seal*(cc: ConversationCrypto, plaintext: seq[byte]): seq[byte] {.base.} =
  ## Encrypt a payload to the room's current member set at the current epoch. The
  ## result is what the Transport publishes.
  raise newException(CatchableError, "ConversationCrypto.seal is abstract")

method open*(cc: ConversationCrypto, envelope: seq[byte]): seq[byte] {.base.} =
  ## Decrypt an inbound envelope. Returns the plaintext if we hold a key for the
  ## envelope's epoch; raises if we do not (a member who joined later cannot open
  ## an earlier epoch — F-16). The caller treats a raise as "not for me / not yet".
  raise newException(CatchableError, "ConversationCrypto.open is abstract")

method addMember*(cc: ConversationCrypto, member: Member) {.base.} =
  ## Re-key forward: open a new epoch the added member receives. They get only the
  ## new epoch key, never the prior ones — so they cannot decrypt earlier messages
  ## (F-16 forward secrecy for joiners; the property the F-16 test asserts).
  raise newException(CatchableError, "ConversationCrypto.addMember is abstract")

method removeMember*(cc: ConversationCrypto, member: Member) {.base.} =
  ## Rotate: open a new epoch wrapped to the remaining members only, so the removed
  ## member cannot read anything sent after their removal (F-16 removal).
  raise newException(CatchableError, "ConversationCrypto.removeMember is abstract")

method members*(cc: ConversationCrypto): seq[Member] {.base.} =
  ## The current member set (the current epoch's recipients).
  raise newException(CatchableError, "ConversationCrypto.members is abstract")

method epoch*(cc: ConversationCrypto): int {.base.} =
  ## The current epoch index — monotonic, incremented on every membership change.
  raise newException(CatchableError, "ConversationCrypto.epoch is abstract")

# ── membership handshake (how a joiner actually gets a key) ─────────────────────
# addMember/removeMember change the local key state; these carry the change over
# the wire. They are deliberately mechanism-agnostic: the stopgap emits ECIES
# grants, native chat (MLS) would emit a commit + welcome. The session treats the
# frames as opaque control bytes, so swapping the backend is a binding change.
#
# Authorization is NOT here: a join-request carries no authority, and the core
# never auto-admits. An existing member decides to call admit(); which members may
# is a driver policy layered above (default: any current member).

method identity*(cc: ConversationCrypto): Member {.base.} =
  ## Our own member key — what a join-request announces so a member can admit us.
  raise newException(CatchableError, "ConversationCrypto.identity is abstract")

method admit*(cc: ConversationCrypto, joiner: Member): seq[seq[byte]] {.base.} =
  ## Admit a joiner: re-key forward to include them (F-16), and return the control
  ## frames to publish so every current member — the joiner included — receives the
  ## new epoch key. Opaque to the transport; each frame protects its own payload.
  raise newException(CatchableError, "ConversationCrypto.admit is abstract")

method ingestControl*(cc: ConversationCrypto, frame: seq[byte]): bool {.base.} =
  ## Consume a membership control frame addressed to us (a grant/welcome). Returns
  ## true if it advanced our membership (we now hold a key we did not before),
  ## false if it was not for us or we could not open it.
  raise newException(CatchableError, "ConversationCrypto.ingestControl is abstract")
