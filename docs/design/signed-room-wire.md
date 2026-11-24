# The signed room wire (0.5.0, epic exo-3b3)

FS-2 says every event is signed and events from non-members are refused at ingest. Until
0.5.0 that held for a handful of event kinds only (exo-f76), and not at all for the frames
that carry epoch keys. This note says what the room now checks, where, and what it still
does not.

## Grants (`crypto/epoch_crypto.nim`)

A grant is sealed whole to one member, as before. Inside, it is the admitter's Ed25519
signature over a hash-input record (`muster.epoch.grant.v1`): the room (content topic), the
epoch, the key id of the epoch it follows (`prev`), the roster, the new key's id and the
admitter. A member takes it when:

| Situation | Taken if |
|---|---|
| it holds the epoch it follows (`prev` matches) | the admitter is a member of that epoch and the grant is the next epoch |
| it missed a grant (away, or out of order) | the admitter is a member of its current epoch, and the grant is at most 16 epochs ahead |
| the grant is for an earlier epoch it lacks | it chains from an epoch it holds (kept to read with; the current epoch does not move) |
| it holds no epoch anyone else holds | it asked to join (`requestJoin`), or the grant is from the member whose invite it holds |
| the admitter is itself | always (its own grant back from the store after a restart) |

Never: an epoch past 2^31, a roster that does not name the recipient and the admitter, a
roster naming a member the room has removed (a removal the chain executed, read from the
log: `executedRemovals`, `msigExecutedRemovals`), or anything at an inbox.

Two valid grants for the same epoch from the same parent (two members re-keying at once):
the one whose signed record digests smaller is the epoch, on every member still at that
epoch; the other key is kept to open what was sealed under it. Every member's client
re-keys out a removed member its roster still holds a minute after it noticed, so a
removal does not rest on the proposer's client alone.

## Envelopes

Plaintext `v(1)=2 ‖ sender(64) ‖ sig(64) ‖ payload`, the signature over
`muster.envelope.v1` (room, epoch, sha256(payload)). Opened only when the sender is a member
of the epoch whose key opened it. A sender no longer in the current roster is accepted for
five minutes after this member learned of the removal (what was in flight), or from the
member's own journal; never otherwise. Re-sealing someone else's event under another epoch
fails their signature.

## Events

`roomEvents` drops an author-bearing event whose author was not a member of the epoch it
was sealed in. Newly author-bearing: `membership/*` (the member who re-keyed),
`intent/<id>/context` and `intent/<id>/read/*` (only a proposer's context and reads count),
and the FROST ceremony's open and step messages.

## Approvals (`coordination/attest.nim`, `gradeFor`)

| Driver | Verifying attestation | None, or none verifies |
|---|---|---|
| the chain binds the signature (profile binding explicit or implicit, or a vote locus: Safe, Bitcoin, LEZ multisig, lez-msig) | committed | unattested, counted |
| only the room binds it (threshold, FROST, invoke, charter, EIP-191, the private split) | committed | rejected, not counted |

A failing attestation is never an attestation and never voids an approval by itself.
Round 2 is signed automatically only after this member's own committed round-1 approval in
this room.

## The journal and the inbox

The journal keeps only frames that were accepted. An inbox session takes invites and
nothing else. Beacon-request nonces are exactly 16 bytes and their memory is capped, as are
held invites (256) and pending join requests (64).

## What it does not do

- **Joining by name trusts the first grant.** A member who asks to join a room by name takes
  the first valid grant addressed to it. An invite pins the inviter; a name does not.
- **A member away for more than 16 re-keys** cannot take the next grant and must leave and
  rejoin the room.
- **Any member may admit** (the documented policy), so one person can add a second identity
  of their own. It shows in the roster.
- **A LEZ vote's attestation** is not yet bound to the voter's disclosed account (audit P1-05);
  it affects the grade only, and the vote is counted from the chain.
- **Any module installed beside Muster can call it**: the platform does not tell a module who
  is calling. See the claims registry.
- 0.4.x rooms are not readable by 0.5.0: the wire changed.
