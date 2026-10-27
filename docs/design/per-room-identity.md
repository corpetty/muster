# One identity per room: a proposal, and what it does to contacts (exo-833 C)

Status: **proposal, for discussion with the Logos Messaging team (2026-10-27).** Nothing
here is built. It is part of exo-833 (the room identity held by the platform), whose other
pieces are the identity in the person's Basecamp wallet (built, opt-in) and approval
signatures through the wallet (B, not started). We want Muster's identity model to agree
with how Logos Messaging thinks about identity before we build it, so §8 is a list of
questions for that team.

## 1. The question

Should a Muster member use **one identity in every room**, as today, or **a different
identity in each room**, so that the members of two rooms cannot tell, from the keys
alone, that they share a member?

Rule 8 of the wallet/signer spec (`docs/design/wallet-signer-spec.md`) already says "fresh
keys per context by default", and the platform's keystore already derives identity keys
per context (`m/7432'/0'/c0'…c7'`, the `c`s from a hash of purpose and context; see the
keystore fork's `docs/specs.md` § Identity keys). So the mechanism exists. What does not
exist is a design for what the rest of Muster does once a person is no longer one key:
contacts, invites, names in a roster.

## 2. Today

A member has two bound identities (F-14, ADR-010 amended 2026-08-23):

- a **secp256k1 authorization key**: the Ethereum address a Safe names as an owner, the
  Bitcoin key a multisig names. It is only disclosed in a room when the member uses it there
  (a join request names no secp key since exo-a87);
- an **Ed25519 identity** and its X25519 form: the *room identity*.

The room identity does everything that names the person:

| Use | Where |
|---|---|
| your **contact link**, `muster:contact/<chat id>` (exo-899) | the 64-byte chat id is ed25519 ++ x25519 |
| your **inbox**: invites are sealed to it and dropped on a topic derived from it | `coordinate_start_inbox`, `coordinate_invite` |
| your **member key** in every room: authors your events, the epoch keys are sealed to it, the roster lists you by it | `joinRequestFor` (`crypto/keystore.nim`), `admit` (`coordination/session.nim`), `coordination/authorship.nim` |
| what **your address book** stores for someone else | `contacts`, `contact_add` |
| an **invite also admits** the invitee, because the inviter already knows the key they will join with | `coordinate_invite`, exo-dcc.29 |

Since exo-833 the identity can live in the person's Basecamp wallet instead of Muster's own
keyfile, derived for `muster_module/default`, one key for every room.

## 3. What one identity links, and for whom

Who can tell that you are the same person in room A and room B, from the keys alone:

| Observer | Today | Why |
|---|---|---|
| The store node, the relay, the network | **no** | nothing on a room's topic names a member: join requests are sealed to a join key, grants sealed whole to each member, no epoch numbers on envelopes (exo-661.7, `store_node_view_test`) |
| A chain | **no**, unless you act from the same account in both rooms | the room identity never touches a chain |
| A member of A and a member of B, comparing notes | **yes** | the same key is in both rosters and signs both logs |
| Anyone you gave your contact link to, in any room you share with them | **yes** | the contact link *is* the member key |
| An audit file or a room-map export from A, shown to someone in B | **yes** | it names the authors by key |

So the exposure is social, not infrastructural: it is to the people in your rooms, and to
anyone they pass a room's history to. Invariant 9 already says what Muster tells a room
about a member is only what that member disclosed *in that room*; one identity across rooms
quietly discloses "I am also in these other rooms" to anyone who can compare.

## 4. The proposal: a contact key, and a key per room

Two kinds of Ed25519 identity, both derived from the recovery phrase, so a restore brings
all of them back:

| Key | Lifetime | Who sees it | Used for |
|---|---|---|---|
| **Contact key** | one per person | only the people you give your contact link to; **never appears in any room** | your inbox; receiving invites; proving to a contact, privately, "this room key is me" |
| **Room key** | one per room you join, derived for that room | that room's members | authoring, being admitted, the epoch keys sealed to you, the roster |

In the platform wallet these would be `muster_module/contact` and `muster_module/room/<room>`.
In Muster's own keyfile the same derivation applies, so both backends give the same keys.

### 4.1 What the person sees

1. **Your contact link stays,** and you give it out as today. It now names your contact key,
   which no roster ever shows.
2. **Being invited takes one more step, done for you.** Today the inviter admits you with the
   invite itself, because they know the key you will join with. Under this proposal they
   cannot: your room key does not exist until you accept. So:
   - you accept the invite;
   - your client derives the room key and sends the inviter a sealed note, signed with your
     contact key: "this room key is me";
   - the inviter's client admits that key automatically, because it invited you.

   If the inviter is offline, you wait until they come back; the store keeps the note.
3. **Joining with a room code is unchanged.** You join with a fresh room key, and a member
   admits you as today. Nobody learns your contact key.
4. **Names in a roster are earned per room.** Today the name you gave Alice follows her into
   every room. Here you see "Alice" in a room only if you invited her there, she invited
   you, or she introduced herself to you in it. Anyone else is a new member, shown by the
   name they chose in that room.
5. **Introducing yourself is explicit, and private.** In a room, you can tell a contact "this
   is me": the same signed note, sealed to them alone. The other members learn nothing.
6. **Contacts become your own record of who is where.** "Alice: known in rooms A and B" is
   kept on your machine and never published.
7. **Leaving and rejoining a room** gives you the same room key: it is derived from the room.

### 4.2 What it does not hide

- **Accounts you use in more than one room.** Your Ethereum address, your Bitcoin key and any
  account you disclose are the same everywhere. A Safe you own a share of in two rooms links
  you there, on chain, whatever your room key is. The identity binding (F-14) ties the
  authorization key to the room identity in the rooms where you use it, so it links your room
  keys there too. Per-room *authorization* keys (rule 8 says "per room membership and per
  multisig") are a separate change, and accounts that already exist cannot be made per room.
- **What you write.** A name, a writing style, a payment of a known amount.
- **The people who know your contact key** can link the rooms they invite you to, or where you
  introduce yourself. That is the point of a contact.

## 5. The options

1. **A contact key and a key per room (§4).** Recommended. Rooms cannot be linked through
   you, and contacts still work, with one extra step on an invite.
2. **A key per room and no contact key.** Contact links and invites need another mechanism, a
   fresh one-time link for each invite for example. Stronger, but there is no reusable
   address to give out.
3. **One identity, as today.** Simplest; best for groups where everyone knows everyone.
   Anyone in two of your rooms can tell it is you.

## 6. Trade-offs

**Gained (options 1 and 2):**

- Two rooms cannot be linked by comparing keys. A family split, a work multisig and a Monero
  deal no longer share an author.
- A key exposed in one room (leaked, or named in an honest member's audit file passed around)
  says nothing about the others.
- It matches rule 8 and the keystore's per-context derivation.

**Paid:**

- **Invites take a round-trip,** and an offline inviter holds the invitee up (§4.1, item 2).
- **Names do not follow people.** More "new member" entries, more introducing. Rooms of people
  who all know each other feel a little clumsier.
- **With the platform wallet, an approval in the keys app for every room joined.** Each room
  key is a new `request_identity`, which the person approves. Two ways out:
  - the wallet grants once that Muster may make keys under `muster_module/room/*`, which is
    a question for the signer interface (logos-co/logos-signer-interface, the issue drafted
    in corpetty/logos-signer-module `docs/upstream/issue.md`);
  - Muster derives room keys itself from one secret the wallet hands it. That puts private
    keys in Muster's process, which is what moving them to the wallet was for, so we rule it
    out.
- **Migration.** A room's log and sealed keys are bound to the key its members joined with.
  Rooms that exist keep today's key; only new rooms get fresh ones. The rooms already shared
  stay linked.
- **Size.** Every keystore call becomes room-scoped (`encIdentity(room)`,
  `edSignRecord(room, …)`, `sealOpen(room, …)`), and so do every call site in
  `module/src/coordination/`, the invite and inbox flow, and the address book. It is the
  largest of exo-833's pieces.

## 7. How it would be built (if option 1)

- The `Keystore` seam takes a room on every identity operation; `contactIdentity()` is a new
  operation. The local keyfile derives room keys from its identity seed and the room, the
  platform backend asks the wallet for `muster_module/room/<room>`.
- An **introduction** is a new sealed record `muster.introduce.v1 {room, roomKey}`, signed by
  the contact key, sealed to one recipient's contact key or to the inviter. An inviter's client
  admits a key whose introduction answers an invite it sent.
- The address book stores, per contact, the contact key and the room keys it has been
  introduced under; rosters resolve names through it.
- New rooms get room keys; a setting can keep one key for every room, for people who choose
  option 3.

## 8. Questions for the Logos Messaging team

When ADR-010 read `logos-messaging/libchat` (at `74265e6e`, 2026-08-23), its identity was an
Ed25519/X25519 **account** with a **directory** (`core/account/src/account.rs`,
`directory.rs`), and group messages were DeMLS, whose leaf credentials bind a stable identity
to every message and commit (`core/conversations/src/inbox_v2/identity.rs`). That may have
moved since. Muster's room layer is a stopgap with native chat as its target (ADR-010), so we
would rather follow your model than invent a second one:

1. **Is a person one identity across conversations in your model,** or do you intend a key
   per conversation (or per installation) with the account behind it? Is unlinkability between
   conversations a goal, a non-goal, or open?
2. **Contacts and inboxes:** is the account key what someone hands out to be reached, as our
   contact link is? Does anything like a private introduction ("this conversation key is me")
   exist or is it planned?
3. **The directory:** what does it publish, and to whom? A public directory of account keys
   would make per-room keys in Muster pointless for anyone in that directory, unless the
   conversation keys are not listed.
4. **Group membership:** would a DeMLS leaf credential be able to carry a per-group key
   rather than the account identity, and is that something you would accept upstream?
5. **Derivation:** should these keys come from the person's wallet (`keystore_module`, the
   phrase it keeps) through `logos.signer/1`, as Muster's identity now can, or does libchat
   intend to hold its own? A shared answer would let a person's Muster rooms and chat
   conversations agree on who they are.
6. **Key per conversation and approvals:** if every new conversation needs a new key, how do
   you expect the person to approve that? Once, as a standing grant, or per conversation?

## 9. Decisions this needs

1. Option 1, 2 or 3 (§5).
2. Under option 1 with the platform wallet: accept an approval per room for now, and ask the
   signer interface for a standing grant?
3. Existing rooms keep their key; new rooms get fresh ones. Or, later, a "re-key this room"
   action that re-admits the member under a new key?
