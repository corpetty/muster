> **Working draft.** Third in the series. Claims about *Logos/Muster* trace to a requirement in
> [`01-furps.md`](../01-furps.md) or a design slice in
> [`action-manifest.md`](../design/action-manifest.md), and to an acceptance test where one
> exists; what's *built* and what's *proposed* are named separately, because the gap is the
> point. Figures are marked, not drawn.

# Every agreement is a commitment; contracting should tell you which kind

*Post one laid out the transaction pipeline and dug into discovery; post two argued that a
signature should carry where its inputs came from. This one is about **contracting** — the
stage where an agreement gets formalized. The mechanical part (assemble the bytes, collect the
signatures) is what every stack builds. The part almost nobody surfaces is what a formalized
agreement actually binds you to: what each party is committing to, and — the argument of this
post — **what kind of commitment it is**, and for the soft kind, how they could walk and what it
would cost them. Research register; argue with it.*

---

Here is the whole of "contracting" as most software presents it: a button that says **Confirm**.

You negotiated the terms somewhere — a chat, a form, a back-and-forth. Now you formalize them.
For anything with a chain in it, formalizing means **building the transaction that will be
signed, and then signing it**. Off-chain it's whatever the formality of agreement is — a
countersignature, a click-through, a purchase order, a handshake someone writes down. Either
way the software collapses it to one control, and the control's whole message is: *press this
and it's done.*

But formalizing an agreement is not producing an artifact. The transaction is the receipt. The
agreement is what each party is now on the hook for — and that has a shape the Confirm button
throws away. It pulls in **infrastructure and dependencies** (this agreement needs an RPC, a
signer you hold, a module installed). And it fixes **commitments** — and commitments are not all
the same kind, which is the thing I want the rest of this post to be about.

## An agreement has five questions, not one

Before you can sensibly agree to something you should be able to see what agreeing entails.
Muster puts a proposed action on a card that answers five questions, and the last one is the
one this post turns on:

- **What will it do?** — the effect, in words, plus its schema id.
- **What is needed?** — the requirements, crossed with *your* readiness: for each dependency
  (a module, an environment/RPC, an authority you must hold, infrastructure, a capability),
  `met | missing | unknown`, with a remedy. `unknown` is a first-class answer, never a silent
  `met`.
- **What will it touch?** — what it reads and what it alters.
- **What will happen?** — everything that leaves the room, grouped by who sees it, with the
  store node always listed because it always sees the timing.
- **How do we agree?** — the rounds, the threshold, the membership model, the finality.

This is the un-sexy substance of contracting, and it is [built](../design/action-manifest.md):
the manifest is a function of the driver plus the effect, generated from the module's contract
plus a few declared facts the contract can't carry (invariant 6, the core never invents it),
and rendered per participant. Before anyone signs, every participant can see what the agreement
requires *of them*, install what's missing, or **deny** — a signed decline folded into the
room's view, naming nobody under an anonymous driver.

That fifth question — *how do we agree* — is where the interesting part hides, because "we
agree by collecting two of three signatures" tells you the *mechanism* and not the *credibility*.
And credibility is the whole game.

## Imperative and motivational: two kinds of commitment

The distinction I'm leaning on comes from the PriFi framing, and it's the most useful lens I've
found for this stage. A commitment is **imperative** when the discretion to defect has been
removed *structurally* — the party *cannot* do the other thing. It is **motivational** when the
party *could* defect but has a reason not to.

Muster already grades on this axis, and much of it is built. Signing is imperative against your
counterparty: they cannot alter the materialization you approved (invariant 1), and they cannot
replay your signature in another conversation, account, or slot (invariant 2, the replay
binding). Post two's opening was the same point from another angle — F-4 re-derivation means the
client rebuilds the bytes from the effect and refuses to sign on a mismatch, which moves signing
out of "trust the interface" and into the imperative column, and proves it with a test. The
Bybit theft is the clean counterexample: settlement was imperative, but *signing* was
motivational — the signers trusted the interface — and that's the link that broke.

Two facts make this honest rather than a marketing axis, and both are in Muster's design today.

**Credibility is relative to an observer at a link — not a property of the commitment.** The
very same signed intent is *imperative* against the counterparty and *motivational* against the
store node, which we merely *ask* not to analyse the conversation graph (the FS-9 metadata leak
post two ended on). So the honest unit isn't a badge on the agreement; it's a matrix —
*(lifecycle step) × (observer) → imperative | motivational | not-applicable* — over the
observers Muster can actually name: the room member, the store node, the RPC provider, the chain
observer, the target module of an invoke. Muster's data forced two values past the article's
two: **exposed**, where no binding exists at all because information reaches an unbound observer,
and **not-applicable**, for a limit that isn't a party to trust. Each names its party.

**Classify, never score.** The moment a commitment becomes a number, the residual trust vanishes
from view — which is exactly the failure the article's private-order-flow example describes. The
card says *"four of five inputs structurally bound; residual trust: RPC provider, store node."*
It never says *"80%."* This classification, with the party named, is [built](../design/action-manifest.md)
(slice M8): every protects/gap claim in the walkthrough carries its credibility and, where a
party's conduct or view remains, *whose*.

## Motivational is not one thing — and this is the part that isn't built yet

Here's where I think contracting, everywhere, stops too early, Muster included until now.

Classifying a commitment `motivational` and naming the party is honest but *coarse*. Two
motivational commitments can differ by orders of magnitude in strength, and the difference is
**what defection costs the party who holds the discretion.** A signer bonded to forfeit a stake
if they equivocate is making a far stronger motivational commitment than a store node we merely
ask nicely — and today both render as the same word.

So a contracting surface that's serious about the fifth question should, for a motivational
commitment, also carry two things:

- **the defection path** — how the party would actually exercise the discretion. The store
  node: correlate your subscription timing. The RPC: hand back a state root that isn't the
  chain's. A bonded signer: sign a conflicting materialization.
- **the cost of defection** — what exercising it costs *them*, when the rail makes it
  calculable: a slashed stake, a forfeited deposit, a burned bond — a concrete `{value, unit,
  who loses it, who it accrues to}`. When the cost is reputational, legal, or social, the answer
  is **`not-calculable`**, shown as exactly that and never guessed. And a defection with **no**
  cost is its own strong disclosure: the commitment rests on nothing but a promise, and the card
  should say so in those words.

I want to be careful this doesn't quietly break the "classify, never score" rule, because it
looks like it might. It doesn't, and the reason is the whole point: **a cost of defection is a
concrete stake — a fact about the arrangement — not a probability that the party holds.** "Cost
of defection: a 2 ETH bond, forfeited to the counterparty" tells you the commitment's teeth.
"80% reliable" hides the residual trust behind a number. We surface the stake; we never surface
a likelihood; where the stake is zero or unknowable, that is the answer, printed.

The honest status: **this facet is proposed, not built** ([`exo-3ae`](../design/action-manifest.md)).
The classification and the named party ship; the defection path and its cost are a further
declared field on a motivational classification — driver-described like the rest of the
manifest, subject to the same conformance rule that fails a lying manifest, so a driver can
never render teeth it can't enforce. Designed, specified against that rule, not yet written.
I'm putting it in a post before it's in the code because the argument is the part I most want
broken, and because saying it out loud is how the code gets held to it.

## The same simple case, formalized honestly

Take post one's example again — one party pays another, now as a two-of-three Safe rather than a
single key, because contracting is where multi-party actually bites.

Someone proposes the payment. The card shows the five questions: the effect (pay this address
this amount), the requirements (a funded Safe, an RPC that can read finality, your owner key —
each `met/missing/unknown` for you specifically), what it touches, what leaves the room, and how
you agree (two of three, immediate in-room, settlement external). Each owner reviews the effect;
the client re-derives the `safeTxHash` and refuses on mismatch — **imperative against a
malicious proposer**, and post two showed exactly how far that reaches and where it stops.

Now read the commitments honestly, observer by observer. Against the other owners: imperative —
they can't alter what you approved or replay it. Against the **RPC** that will read whether the
transaction settled: motivational — its defection path is *serve a false state root*, and its
cost of defection today is `not-calculable`, until a beacon light-client (ADR-014) lets the
client verify the root against the chain instead of trusting it, which would move that link into
the imperative column and dissolve the question. Against the **store node**: motivational — its
defection path is *graph analysis*, and its cost of defection is **none you can point to**; it's
a bare ask, and post two was blunt that closing it needs a mixnet that isn't shipped.

So the honest one-line reading of this contract is: *imperative against your co-signers and a
malicious proposer; motivational against the RPC and the store node — resting, for now, on a
false-root that nothing yet penalises and an ask the network isn't structurally held to.* That
sentence is contracting done honestly. It is also precisely what a **Confirm** button is built
to keep you from having to read.

## Why this is contracting's job, and what Logos does and doesn't buy

Surfacing the *kind* of commitment belongs to contracting specifically: negotiation settled the
terms, ordering and settlement will make them binding, and contracting is the hinge where the
agreement is fixed and each party's discretion is set. It's the last place you can look before
the discretion stops being yours.

Muster can put this on the card for the same structural reason post two gave: the manifest is
driver-described (invariant 6) and folded from the conversation log, not assembled by a
coordination service that would itself become one of the parties you're trusting. The credibility
of a link, the requirements, the disclosure — all of it is a reduction over the room's own log.
That's the Logos shape doing real work here.

And, keeping the same honesty as last time: it doesn't buy everything. Whether the host actually
*refuses* an action that lacks a matching, agreed, executable intent — "what am I allowing before
it is allowed to happen" — is slice **M7**, and its enforcing half is upstream in the platform
broker, specified and raised but not landed. So today the card *describes* the agreement
faithfully; the platform doesn't yet *gate* on it. That's the difference between a contracting
surface that explains and one that enforces, and I'd rather name which one ships.

## The honest status, in one place

- **Built.** The action manifest and its five questions; per-participant readiness with a
  first-class `unknown`; deny; the credibility classification (imperative / motivational /
  exposed / not-applicable) with the discretion-holding party named; the information-flow view
  and the per-action provenance from post two — all folded from the log, all rendered on the
  card (slices M1–M6, M8; the conformance suite fails a lying manifest).
- **Proposed, not built.** The defection facet — path and cost-if-calculable — on a motivational
  commitment (`exo-3ae`). The whole of this post's new argument is here, and it's a design with a
  conformance rule attached, not shipped code.
- **Specified, upstream, open.** Host enforcement of the agreement before dispatch (M7). The card
  explains; the platform does not yet gate.
- **Residual.** On-chain, some defection costs genuinely *are* calculable — a slashing amount, a
  forfeited deposit — and Muster doesn't compute them yet even where it could. Off-chain, most
  are `not-calculable`, and the honest surface says exactly that rather than inventing a figure.

## Where I'd like argument

1. **Does surfacing a defection cost stay honest, or does any number get read as a score?** My
   claim is that a *stake* is a fact and a *likelihood* is a score, and only the first belongs on
   the card. Tell me if that line holds under a real user's eyes, or if "2 ETH bond" just becomes
   a vibe of safety.
2. **Is "cost of defection: none" useful or just alarming** for the store node and the RPC? I
   think naming the bare-promise commitments is the most honest thing the card does. It's also
   the thing most likely to make people bounce.
3. **Is the observer matrix too much for a human at decision time?** *(step × observer →
   credibility, plus a defection facet)* is honest and possibly unreadable. Where's the line
   between honest and usable?
4. **Is classify-not-score a discipline or a dodge?** Refusing to score means never telling
   someone "this is safe enough." Is that principled, or am I offloading the hardest judgment
   onto the user and calling it honesty?
5. **Where is this weaker than what you already use?** Standing question, meant.

## Next

Ordering and settlement — where the commitments this stage fixed finally become binding and the
chain actually appears, and where I'll get into what a private settlement costs (post one's
measured ~seven minutes of saturated CPU, and what that does to the feature).

---

## Figures

- **The stage locator** → [`series-locator-contracting.svg`](../diagrams/series-locator-contracting.svg)
  — the seven-stage pipeline with contracting lit. At the top.
- **The credibility matrix, interactive** → [`action-manifest-explainer.html`](../design/action-manifest-explainer.html)
  — *(lifecycle step) × (observer) → imperative / motivational / exposed / not-applicable*, click
  any cell. The best existing artifact for the imperative/motivational section; link it there.
- **What a signing payload commits to** → [`mech-signing-payload.svg`](../diagrams/mech-signing-payload.svg)
  and **the re-derivation check** → [`mech-effect-materialization.svg`](../diagrams/mech-effect-materialization.svg)
  — for the imperative-against-the-proposer beat.

> **📷 SHOT 1 — the card's "How do we agree?" answer, with the credibility line.** A proposal
> card in `ui/` showing the agreement (two-of-three, immediate / external finality) and the
> credibility line naming the residual-trust parties — the built classification. This is the
> honest version of a Confirm button.

> **FIGURE A — the defection facet (to draw, proposed).** A single motivational commitment
> expanded: *party → defection path → cost {value · bearer · beneficiary} | not-calculable*, with
> two worked rows (a bonded signer with a calculable forfeit; a store node with "cost: none, a
> bare ask"). Marks the `exo-3ae` design, so caption it *proposed, not built* — no manifest
> figure should imply shipped code.
