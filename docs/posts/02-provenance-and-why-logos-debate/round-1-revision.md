> **Working draft.** Second in the series. Claims about *Logos/Muster* trace to a
> requirement in [`01-furps.md`](../01-furps.md) and an acceptance test that fails if the
> property stops holding; claims about *others* name a system, a step and an observer. Three
> builds get named separately throughout — the Nim core, the current UI, and the earlier demo
> — because they are at different maturities and blurring them would be the dishonest move.
> Figures are marked, not drawn.

# A signature proves *what* you signed, not *where it came from*

*First post laid out the transaction pipeline and dug into discovery. This one steps away
from the stage-by-stage walk to argue an idea underneath all of it: that the thing you sign
should carry an account of where its inputs came from. I'll make the case for the property,
then give an honest ledger of how far Muster actually gets toward it today — which is further
than any wallet I've used and shorter than the title. Research post; argue with it.*

---

Here is the part of a signing flow everyone is proud of, and rightly.

You are about to authorize something. A good client does not show you a hash and a spinner.
It shows you the **effect** — pay this person this amount, add this member, raise this
threshold — in words you can read. Then, underneath, it does the careful thing: it takes that
effect and **re-derives the exact bytes** the effect turns into, independently, and it
**refuses to sign if the bytes it derived don't match the bytes it was handed**. No blind
signing. No approving calldata you can't reconstruct. This is [F-4](../01-furps.md) in Muster,
it lives in the core where no plugin and no preference can switch it off
([FS-6](../01-furps.md)), and it is genuinely one of the better things a wallet can do for
you. It does its job perfectly.

Its job is just narrower than people assume, and the gap right next to it is the whole post.

Re-derivation proves the materialization is **consistent with the effect**. It proves the
bytes are the honest encoding of the thing you were shown. It says *nothing whatsoever* about
where the effect's own inputs came from — and it was never meant to. The FURPS requirements
are blunt about the limit; the sentence lives in [F-20](../01-furps.md), describing exactly
this edge of F-4's check, and I'll quote it rather than soften it: re-derivation "proves a
materialization is consistent with its effect and says nothing about where the effect's own
inputs came from, so correctly-derived data of unknown origin satisfies it."

Read that last clause twice. **Correctly-derived data of unknown origin satisfies it.** The
check you were proud of passes clean on data that arrived from nowhere you can name. That is
not a flaw in F-4. It is a second question F-4 doesn't ask, and almost nothing else asks it
either.

## The hole, worked

Take the simplest pipeline instance — one person pays another, the same example the discovery
post used. Somewhere in the conversation, an address showed up: *here's where to pay me.* You
go to pay it. The client re-derives the transfer, the bytes match the effect perfectly, F-4
is satisfied, the strip goes green.

Now ask the question the green strip doesn't answer: **which message put that address in the
room?** Was it a peer — the actual person you're paying, speaking in the encrypted
conversation? Was it a plugin, emitting a typed block? Was it a value a driver interpreted out
of someone's contribution? Or was it an **external read** — an address your client pulled from
an RPC endpoint you don't control and can't see, folded into the effect on the way past?

Every one of those produces byte-identical, perfectly-re-derivable input. The signature comes
out the same. In all four cases you'd have signed a correctly-formed authorization over data
whose origin you cannot name. And this isn't exotic: on almost every interactive signing
surface — every wallet, every dapp approval I've used — the provenance of what you sign is
simply not part of what you sign.

One thing to be exact about now, because it's the trap the rest of the post has to avoid:
**naming where an input came from is not the same as trusting it.** If that address was an
external read from a hostile RPC, classing it "external read" does not make the RPC honest. It
makes the danger *legible* — it turns "an address, from somewhere" into "an address your
client pulled from an endpoint no one in the room vouched for," at the moment you decide.
Provenance closes *"I can't tell where this came from."* It does not close *"this source is
trustworthy."* Those are different holes, and I'll only claim the first.

## The property: provenance as an input to the signature

The claim Muster makes is [invariant 10](../../CLAUDE.md), spec
[`derived-exo-3a1`](../../contracts/specs/derived-exo-3a1.spec.json), requirement
[F-20](../01-furps.md) — six clauses I'll label s1–s6 as I hit them. Stated plainly:

**Every signing payload commits to a record naming, for each input whose bytes reached the
signed payload, its class — plugin block, driver-interpreted contribution, external read, or
peer message — and its log position. The client refuses to sign when any input's origin
cannot be accounted for.**

Two phrases carry it, and they're the two a weaker version quietly drops.

**"Commits to" (s1).** The record is not metadata stapled to the signature. It is folded
*inside the bytes that get signed*, so that changing where one input came from — holding every
input's actual value byte-for-byte identical — changes the signature. In the core's signing
mechanism this is one function: the signed bytes are a domain-separated hash over the
materialization **and** the encoded provenance together
([`provenance.nim`](../../module/src/intents/provenance.nim), `signedBytes`) — provenance is a
*term in the hash*, not a field beside it. A signature valid for an address the *peer* stated
is not valid, byte-wise, for the same address pulled from an RPC read. The oracle holds every
input value fixed, perturbs only provenance, and asserts the signed bytes always move
(`probe_provenance_binds`); an implementation that files provenance in a side field excluded
from the payload fails it, which is the point.

**"Refuses" (s3).** By design, not a warning and not a yellow badge: when any input's origin
can't be accounted for, there is no signature (`trySign` → `sdRefused`), and per
[FS-10](../01-furps.md) that refusal is meant to be core behavior no configuration, plugin or
preference can switch off, on the same footing as FS-6. The model check enumerates every
subset of inputs marked unaccountable and asserts refusal when the subset is non-empty,
completion when it's empty (`probe_provenance_refusal_stepper`) — both directions, because a
client that refused *everything* would satisfy the refusal half while being useless.

And the record has to be **two-way complete** (s2): every input that reached the bytes has an
entry, *and* every entry corresponds to an input that actually contributed (`coverageTwoWay`,
`probe_provenance_coverage_stepper`). One-way is easy and worthless — emit a generic "input"
entry per slot and never resolve it. Two-way makes both silent omission and "unknown"-padding
into test failures.

### What of this actually ships, said flatly

Here is the honest seam, and I'd rather put it right under the mechanism than bury it. **s1
and s3 — the byte-commitment and the refuse-on-unaccountable gate — are tested core primitives
with no caller on any shipping signing path.** They pass their oracles; nothing a user
triggers reaches them yet, and the plan (`exo-891`) names wiring the refusal as separate,
not-yet-done work.

Two reasons, one avoidable and one not. The avoidable one is just sequencing: the wiring is
scheduled, not written. The unavoidable one is more interesting and belongs in the open: on
the shipping **Safe** rail, what an owner physically signs is the **EIP-712 `safeTxHash`** — a
fixed Safe structure with no room for a Muster provenance field. So on that rail s1 *cannot*
live in the owner's signature at all; the commitment can only ride alongside, in the log. The
byte-level version becomes real only for a driver where Muster owns the payload end to end —
which is design, not deployment, today. That has a consequence worth stating against my own
thesis: until the commitment is *in* the signature, the refusal is a property of an honest
client checking itself, not something a counterparty or a chain can verify happened. Run a
stock Safe client and the guardrail is simply absent; the resulting signature is
indistinguishable. For self-protection that's still worth a lot. As a third-party-verifiable
guarantee, it isn't there, and on Safe it structurally can't be.

What *does* ship is the other four clauses — the accountable, graded, epoch-scoped lineage,
folded from the log — and that's the part the rest of the post is really about. It's less than
the title. It's also more than anything else on offer, and I'll show why.

## Why the obvious way to do this is the wrong shape

If I asked you to "keep track of where the signed data came from," your first instinct — my
first instinct — is an **audit log**. Append a line every time you sign: what, which inputs,
where each came from. Write it to a file. Done.

It's the wrong shape, for two reasons that turn out to be one reason.

First, **a side-car store can disagree with the truth.** The log of what actually happened is
one thing; your separate audit file is another; nothing forces them to agree. A bug, a crash
mid-write, a tampered file, and your record now attests to a history the conversation didn't
have. So Muster's record is not a store beside the log — it's a **reduction over the log
itself** (s5): rebuildable from log plus keys, nothing on the side to drift (invariant 4;
tested by a cold-start replay that rebuilds the records and asserts they match the incremental
ones, `probe_provenance_cold_start_matches`). If it isn't in the log, it isn't in the
provenance.

Second — and here it stops being an engineering nicety — **an audit file in the clear hands a
keyless reader the whole lineage.** It would survive the cold-start replay perfectly and still
be a catastrophe: anyone who gets the file learns who contributed what to what, forever,
whether or not they were ever in the room. Muster's record instead inherits the conversation's
boundary — readable only inside it, scoped to the **membership epoch** of the entries it
describes, so a later joiner reconstructs no earlier lineage and a keyless holder of the log
reconstructs none of an epoch's record (s6, `probe_provenance_epoch_scope_stepper`;
`canReconstruct` → `canDerive`, the same derivation gate the encryption already enforces).

I should be honest that neither of those properties is *invented* here. Event-sourced and CQRS
systems routinely derive an audit projection deterministically from one event store (no drift)
and encrypt it (no cleartext leak). The two load-bearing ideas — *derived, not separately
stored* and *encrypted and scoped to a boundary* — are older than this project and not unique
to Logos. What's particular here is *which* boundary the encryption is keyed to, and that's the
next two sections.

### Where that boundary actually holds, and where it doesn't

It's easy to overclaim "the conversation is the boundary," so let me draw it precisely.

Epoch scoping defeats two adversaries cleanly: a **later joiner**, who never had the earlier
epoch's keys, and a **pure outsider** — a store node, a subpoena served on infrastructure,
anyone holding ciphertext without keys. Neither reconstructs a record they lack the epoch key
for. That is a real and useful boundary, and it's the one a keyless audit file blows.

It does **not** defeat a member of the epoch. A participant can always disclose lineage they
legitimately hold — Muster doesn't try to stop you telling someone what you saw in a room you
were in, and couldn't. Worse for the strong reading: since removal rotates *forward*, a
since-removed member keeps the keys for every epoch they were in, and can exfiltrate that
epoch's lineage in bulk, mechanically. So the true boundary isn't "current members" — it's
"everyone who was ever in each epoch," a set that only grows. Against an insider or ex-insider,
epoch scoping buys you nothing. It was never meant to; the conversation is the security
boundary, which means it protects against reading from *outside*, and I'd be selling you
something false if I implied it disciplines the people inside.

## Provenance that respects anonymity — and what that's worth

Here's the clause I like most and trust least, and it's the one a hand-rolled audit log gets
exactly backwards.

An audit log names names; that's what it's *for*. But Muster's membership model is
**driver-described** ([F-6](../01-furps.md)) — a driver declares whether the room is named or
anonymous — and the record has to follow it. Named model: the record names the account that
contributed each input. Anonymous model: no signer identity for any input class at all — not
hidden in the UI, not merely unshown, *absent from the record* (s4; the model check asserts a
*different* thing in each branch, so the named branch can't pass vacuously,
`probe_provenance_identity_disclosure_stepper`). The trail keeps its answering power in a named
room, where anyone could disclose who signed anyway, and it doesn't become the thing that
de-anonymizes an anonymous one.

Now the honest pincer, because there is one. In the *named* model, provenance's headline
value — telling you *who* contributed — is real but least scarce: in a named room a
participant could always just tell you. In the *anonymous* model, where that value would be
most scarce, provenance withholds identity by design, so what it adds shrinks to class +
position (+ the refusal, once wired) — and every input already has a log position (invariant
4). Stripped of *who*, "every input accounted for" leans toward "every input is in the log,"
which reduce-plus-log already gives you. My honest answer: the class vocabulary and the refusal
are the part that still earns its keep in an anonymous room — *"this value entered as an
external read, at this position"* is more than *"this value is in the log"* — but it's thinner
than the named case, and a skeptic is right to press on it. And there's a runtime caveat I
can't wave away: the record withholding an identity says nothing about whether *timing,
ordering, or slot rendering* leak it anyway. I've closed it in the persisted artifact; I have
not shown it closed in the running client.

## So: why Logos — and why not to overstate it

The load-bearing claim of this section is one sentence, so I'll lead with it before the
caveats bury it: **a provenance record that's a reduction over one encrypted log needs there to
be one encrypted log — and Logos is the one place I can assemble the whole pipeline over a
single such log instead of stitching it across other people's databases.** Now the caveats,
because the easy version of this section is a lie.

Logos is not the right stack because it's leak-free. It isn't leak-free. While the record
protects the *content* of the trail, a store node still watches the *shape* of the conversation
— which topics a client subscribes to, when it publishes and fetches — and reads the contact
graph off that, pseudonymously, encryption or no ([FS-9](../01-furps.md)). The fix is a mixnet
at the transport layer; `LOGOS-MIXNET` is a specification at status **raw**, with a proof of
concept wired into *send only*, not on the near-term roadmap. That's the honest status, and
Logos *aims* to be the stack where no pipeline stage needs an operator without being there
yet.

What it removes today is narrower than "the operator," and I over-reached in an earlier draft
by saying otherwise. Logos removes the *coordination* operator — the transaction service, the
relayer, the indexer — the party whose database would otherwise hold your trail in the clear
and be compellable for it. It does **not** remove the RPC endpoint from the picture; that's the
untrusted, user-chosen infrastructure ([FS-1](../01-furps.md)) that fed the external-read
address in the opening hole, and it's still there, still able to lie. Nor is the coordination
operator impossible to remove elsewhere: an end-to-end-encrypted messaging backend could host
an encrypted event log its operator can't read, which is "reduction over an encrypted log" on a
server stack. So the honest claim is *differently located*, not *only possible here* — Logos
gives you one fewer trusted party by construction, and a coherent place to put the whole log,
not a unique capability.

The place-to-put-it is the part I underestimated, and it's genuinely why it wants to be one
stack — with a caveat of its own. Muster *defines* provenance as a fold over one log, so of
course it needs one log; that's a property of the chosen encoding, not of provenance as such
(in-toto, below, does provenance with no single log at all). Given that encoding, though, the
assembly matters: stitch a chat app to a wallet to an indexer and every seam reintroduces a
party I was trying to remove, and there's no single log to reduce over — the trail fragments
across three databases owned by three parties. Logos lets discovery, negotiation, contracting
and settlement live in one client over one conversation log — the shipping core is Muster's own
ECIES-secp256k1 epoch layer ([F-16](../01-furps.md); ADR-010; native MLS is the post-v0 target,
not what runs today), and the driver seam that lets provenance respect anonymity is the same
seam that lets the room's capabilities grow by proposal. That assembly is what "it lets me put
it all together" means, and it's why a stack still missing its mixnet is nonetheless where I'd
build this.

## What this is, and isn't, new against

I called this idea hard-won; a reviewer from supply-chain security would rightly call it
well-trodden, so let me place it honestly. Signed provenance is a mature field. **in-toto /
SLSA** sign statements about where each input to a build came from — the closest prior art, and
a ratified standard. **Sigstore / Rekor** and Certificate Transparency are append-only signed
logs with *third-party-verifiable* inclusion proofs — stronger, on the verifiability axis, than
Muster-on-Safe, precisely because they're publicly checkable. **C2PA** signs content
provenance for media. Content-addressed DAGs (Git, IPFS) make lineage structural.

So what's actually different here isn't "signing provenance." It's the *setting*: a human
approving a **multi-party** action, at the moment of decision, inside an **encrypted
conversation** rather than a public log — so the record is **epoch-scoped and
anonymity-respecting** rather than world-readable, and it's a **reduction over that
conversation's log** rather than a separate attestation store. Those constraints are the
contribution, and they cut the other way on verifiability: a public transparency log is
checkable by anyone and leaks everything; Muster's record is legible only inside the room and
checkable only by its members. Different trade, not a strict improvement, and worth saying so.

## The honest status, in one place

Three things exist, at different maturities, and naming them separately is the point.

- **The core** (`module/`, the Nim client) implements all six clauses of `derived-exo-3a1`,
  each with an acceptance oracle wired as its test: two property tests (provenance binds into
  the signed bytes; cold-start replay matches) and four model checks (two-way coverage;
  refuse-on-unaccountable; anonymous-silent / named-names; no cross-epoch reconstruction). The
  criticality on the spec is *catastrophic*. The idea is real code with real oracles here.
- **The client's face** (`ui/`, the QML front-end) is wired to that core through the logos API
  — it reimplements nothing, it *calls* the module (`propose`, `approve`, `submit`, and
  `coordinate_intents`, which carries each proposal's own lineage fold) and renders what comes
  back. Every proposal is a card, and the card's **"How do I know this?"** dive-in shows the
  decision's lineage entry by entry, classed by the F-20 vocabulary and **graded by what the
  code can actually prove**: a proposal reads *"sealed to the room's epoch — only a member
  could have placed it,"* a signature reads *"the driver verified this recovers to a configured
  member."* (The room-wide view, `coordinate_provenance`, folds plain messages too and grades
  them lower — a message's author is only what its sender wrote inside a room-sealed envelope,
  any epoch-holder could have written it, and the record *says so*.) That grading is the honesty
  rule made literal: the trail never claims a stronger guarantee than the code enforces.
- **The early demo** (`demo/muster-ui`, the composed-upstream-modules speed build the first
  post's screenshots came from) does the **weaker** thing: it refuses to pay an address the room
  never named — real, room-scoped, and no further (single-key, no signing payload, no graded
  lineage). It's the predecessor, not the client.

So, the state of the claim in one breath: **the accountable, graded, epoch-scoped lineage ships
— folded from the real log, surfaced on every proposal card — while the two properties in the
headline, the byte-level commitment (s1) and the refuse-on-unaccountable gate (s3), are tested
primitives that are not yet wired onto a shipping signing path, and on the Safe rail s1
structurally can't reach the owner's signature at all.** What ships is materially stronger than
the demo and materially short of the title; both are true, and the gap is the roadmap, not a
secret. The transport-metadata leak (FS-9) sits underneath all three builds, untouched, because
it isn't theirs to touch.

## Where I'd like argument

1. **Is naming-without-trusting worth it?** Provenance makes a hostile external read *visible*,
   not harmless. Is "you can see it came from an unvouched RPC, at decision time" a real
   improvement, or does it just relocate the judgment onto a user who'll click through anyway?
2. **Does the anonymous model earn its keep?** Stripped of identity, is class + position + refusal
   meaningfully more than "it's in the log" — or is the feature strongest exactly where it's
   least needed (the named room) and thin where it would matter?
3. **Is the byte-commitment worth wiring** given that on Safe it can never reach the owner's
   signature — i.e. is a signature-carried, third-party-verifiable provenance only reachable by
   abandoning Safe for a Muster-owned payload, and is that trade worth it?
4. **Is "the conversation is the boundary" honest** once you grant it does nothing against an
   insider or a removed member holding old epoch keys? I think it's the right boundary to claim
   and I've tried to claim exactly it and no more — tell me if it still overreaches.
5. **Where is this weaker than what you already use?** Same standing question as last time, and I
   mean it — the transparency-log people have a real verifiability argument I don't fully answer.

## Next

Contracting — stage four, and the one this post was secretly about. Now that provenance and
re-derivation are on the table as two halves of the same question, contracting is where they
meet the thing you actually sign: what a verifiable signing context looks like, exactly where
the byte-commitment could reach the signature and what it costs to get there, and how much of
this survives contact with a real multi-party approval instead of a single-key transfer.

---

## Figures

The post's visual load is carried by the diagram programme — four existing,
manifest-provenanced figures map onto its beats, so nothing new needs drawing and the
[figure manifest](../diagrams/manifest.json) doesn't move. Top to bottom:

- **The F-4 gap** → [`mech-effect-materialization.svg`](../diagrams/mech-effect-materialization.svg)
  — *"Effect and materialization: the check that cannot be disabled."* With the opening.
- **The hole, and the property** →
  [`mech-provenance-trail.svg`](../diagrams/mech-provenance-trail.svg) — *"Where the data came
  from, and why re-derivation does not answer it."* The figure the post is built around (F-20 +
  FS-10, the four input classes, the room-not-participant boundary). Belongs by "The hole,
  worked."
- **"Commits to"** → [`mech-signing-payload.svg`](../diagrams/mech-signing-payload.svg) —
  *"What a signing payload commits to, and what each field defeats"* (F-5/FS-3/F-20). By the s1
  discussion — caption should note it draws the *specified* payload; the shipping seam stays in
  prose.
- **Wrong shape vs. right one** → [`mech-reduce-log.svg`](../diagrams/mech-reduce-log.svg) —
  *"State is a fold over a signed, hash-linked log."* With *the wrong shape.*

The one genuinely new visual is a screenshot, not a diagram, because the strongest proof this
post has didn't exist when the diagram set was drawn:

> **📷 SHOT 1 — the "How do I know this?" dive-in, in the current UI.** A proposal card in
> `ui/` with the provenance box open: the lineage entry by entry — the proposal *("sealed to
> the room's epoch")*, each approval *("driver verified this recovers to a configured
> member")* — on the mineral ground the card uses for lineage, not the verify box's green. This
> is the shot that proves the post isn't only about `module/`: the graded trail is on screen,
> folded from the same log the approvals live in. Capture it after a multi-party proposal has
> collected at least two approvals, so the lineage has real depth.
> *Note before shooting: the live-lineage assertion this leans on (`coordination_surface_test`
> step 7) is currently red on `main` (`exo-eba`) — the code is right and the test expectation
> drifted, but get it green so the shot is presented as proof, not promise.*

*Manifest note: no figure is added or changed by this post; `check-manifest.py` stays green
(its warnings are pre-existing rot on unrelated figures). A diagram that later shows the
shipping-vs-core seam explicitly would be a new figure with its own provenance entry — flagged,
not smuggled into an existing one.*
