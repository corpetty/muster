> **Superseded — kept for its prose, not as the working document.**
> The facts, measurements, statuses, shot list and open questions from this draft now live in
> [`01-discovery-supporting-material.md`](01-discovery-supporting-material.md), rewritten as reference
> material to write against, and brought up to date with everything found since (the authorization stage,
> and the settlement finding — which we reported as a bug in the zone and then retracted). The phrasings
> worth keeping are collected in its §11.
>
> Parts are out of date — most importantly §"Next", which describes the recipient-credit issue as an open
> mystery. It is neither a mystery nor a bug: what a recipient publishes is a key pair, not an address, and
> every payment mints a fresh account under it that only the recipient's viewing key can find. Our report
> to the zone's team was withdrawn on 2026-08-13. See §7 of the supporting material for what replaced it —
> a better story than the one it corrects.

# The blockchain is one stage of four, and it's the one we talk about least usefully

*First in a series. I'm building a thing called Muster and writing up what I find. This post lays out the transaction pipeline as a whole, then digs into the first stage — discovery — with a working prototype on the Logos stack. It's a research post: I want argument, not applause.*

---

I have always wanted a decentralised app that is about **what you are doing and who you are doing it with**. Not a wallet with a chat feature bolted on. Not a chat app with a wallet bolted on. Something organised around getting things done with other people, where the transaction is a thing that happens *in* the conversation rather than somewhere you go afterwards.

And I've wanted that app to tell you the truth about the context you're acting in. Where did this information come from and is it verified. Is this local-first or am I renting someone's server. Who can see what, right now. How has that changed over the life of this transaction, and who learned what at each step.

I want all of that, and I want it to be easy.

It turns out that building it does something more interesting than produce an app: it *teaches the pipeline*. And the pipeline is the thing almost nobody looks at whole.

## The pipeline

Every transaction between people — buying something, paying a contractor, splitting a bill, swapping assets, hiring, granting — moves through four stages. Not always cleanly, and rarely once.

**1. Discovery.** How do you find the person or the opportunity? A marketplace listing. A directory lookup. An order book. A friend's introduction. A search query. Someone's handle on a platform.

**2. Diligence.** How do you establish that they are who they say and have what they claim? A profile. A reputation score. A KYC provider. A balance check. An explorer lookup on their address. A reference.

**3. Negotiation.** How do you agree the terms? A chat thread. An email. A comment section. A form. A back-and-forth that ends in "yes, that one, that price, by Friday".

**4. Settlement.** How does value actually move, and when is it final? This is the part with the chain in it.

Here's the thing I keep coming back to: **the blockchain touches stage four.** That's it. And overwhelmingly, when we argue about privacy in this space, we are arguing about stage four — shielded amounts, mixers, stealth addresses, which is all genuinely important and also roughly a quarter of the problem.

Stages one through three leak *more*, to *more parties*, and are almost entirely unexamined.

Consider what an observer learns from each. From settlement they learn that an amount moved between two addresses at a time. From discovery, diligence and negotiation they learn **who you were considering dealing with, what you checked about them, what you asked for, what you settled on, what you rejected, and when you hesitated**. The intent, in other words. Which is frequently more revealing than the transfer.

And each of those stages, today, runs through infrastructure that keeps records. You find someone on a platform that logs the search. You check them on an explorer that logs the lookup against your IP. You negotiate in a chat whose operator retains the whole thread and can be compelled to produce it. Then you settle on a public ledger and congratulate yourself on using a privacy tool for the last step.

The other thing worth saying early: **the pipeline is not linear and it is not universal.** It loops — diligence sends you back to discovery, negotiation surfaces a fact that needs checking. And its shape depends entirely on what you're doing. Discovery for "send my friend twenty quid" is a completely different problem from discovery on a DEX, which is different again from discovery for an NFT purchase or a hire. The pipeline has to be retold per use case, which is exactly what I intend to do in this series.

## So I built one

It's called **Muster**. It runs on the Logos stack — chat, delivery, and the execution zone — because that stack lets me show the whole pipeline in one app rather than gesturing at the parts that don't exist yet.

The point of building it is not to ship a product. It's to have something concrete enough that we can ask, at every step: *who just learned something, what did they learn, was that our choice or the stack's, and what would it take to change it?*

> **📷 SHOT 1 — the establishing shot.** Two app windows side by side, both with a conversation open and at least one exchange visible. You already have a version of this. Best taken *after* the whole journey has run, so the thread shows the ask, the shared address and the receipt in order — the reader should be able to see "this is one conversation that contains a payment" without reading a word of the caption.
> *Caption idea: "Two peers, one conversation. The ask, the address and the receipt are messages in the thread, not a detour into a wallet."*

That last distinction matters more than I expected. There's a real difference between:

- a leak **you chose** (you posted a public listing)
- a leak **the stack chose for you** (your client subscribes to a topic in a way that reveals your contact graph)
- a leak **nobody chose** and everyone inherited (the anonymity set is small because the network is young)

Most privacy writing collapses these. The app is my attempt not to.

## This post: discovery

The simplest possible pipeline instance: **one person pays another.** No marketplace, no escrow, no multisig. If we can't be honest about this one, the complicated ones are hopeless.

Here's discovery in Muster as it works today.

The app mints an address locally, seconds after launch. Nobody was asked. There is no account, no registration, no name reserved, no confirmation. I send that address to you out of band — Signal, a QR code, across a table. You paste it in. A conversation opens.

> **📷 SHOT 2 — the account card, close.** Just the identity card at the bottom of the sidebar: avatar, short label, the full address in mono, and the copy button. Ideally catch it mid-flash showing *"Copied to clipboard"*.
> *Why it earns its place: this is the entire signup flow. There is nothing before it. A reader who has onboarded to any other wallet or messenger will feel the absence.*

> **📷 SHOT 3 — the New chat dialog with an address pasted in.** The paste field with a real address in it, before pressing Create.
> *Why: shot 2 and shot 3 together are the whole discovery mechanism. Two screenshots, no server.*

**What that buys:** there is no directory, so there is no lookup, so there is no service that now knows we're talking. Compare the normal version, where "add contact" is a request to a server whose entire business is knowing the edges of that graph.

**What it doesn't buy, and this is the part I want argued with:**

*The bootstrap is unauthenticated.* Whatever channel carried my address is the weak link. If it was compromised, the attacker is now the conversation. Muster cannot see that and doesn't claim to. The fix is a fingerprint comparison over a second channel — standard, well understood, and **not built here**.

*A relay still sees the shape.* Conversations ride content topics. A store node sees which topics a client subscribes to and when it publishes and fetches. That's the contact graph, pseudonymously, and end-to-end encryption does nothing about it. The fix is a mixnet at the transport layer — not an app change, and not Tor, which hides who-by-IP rather than what-links-to-what. `LOGOS-MIXNET` exists as a specification at status **raw**, with a proof of concept integrated into *send only*. It is not on the near-term roadmap. That's the honest status and I'd rather print it than imply it's around the corner.

*Running your own node does not fix this.* It protects the operator's metadata, not the metadata of the people they talk to — and it lets a node operator invert the threat by learning when a target fetches.

> **📷 SHOT 4 — the "still open" claims in the panel.** Scroll the right-hand panel to the two discovery gaps and capture both together: *The introduction is unauthenticated* and *A relay still learns who talks to whom*, each with its "What would close it" line and its status line beneath.
> *Why: this is the post's credibility. An app that ships its own unsolved problems in the interface, with the fix named and the roadmap status attached, is making a different kind of claim than a marketing page. Make sure the* `status: specified, not built` *line is legible — that's the sentence people will quote.*

> **📷 SHOT 5 — the disclosure table, close.** The dark block at the end of the discovery section: **WHAT A RELAY SEES**, with the four rows — who you are, who you talk to, when, what you said.
> *Why: it's the concrete version of the argument, and the ground changes colour precisely because you've crossed the boundary. If you only have room for one panel screenshot in the post, use this one.*

There's also a fork in the road worth surfacing, because the stack offers both. The execution zone ships an **on-chain label system**: register a human-readable name, anyone resolves it. It's genuinely nicer to use. It's also a permanent public mapping where the lookup is itself a public act. Same stack, two discovery models, real costs on both sides. Which is right depends entirely on whether you'd rather be *findable* or *unlinkable* — and I don't think there's a universal answer, which is why the app shows you both rather than picking for you.

## What the app does with this

Every step has a panel that answers, for that step: what's protected and by which mechanism, how the same step looks on a conventional stack, and what still leaks — with the fix named and its **real status** attached (shipped / specified / partly there / nothing). Plus a running account of how this conversation got to where it is, read off the conversation itself.

The claims are structured data, not prose, specifically so a claim without evidence is visible as a hole rather than reading fine and being wrong.

> **📷 SHOT 6 — the whole right-hand panel, full height.** Taken *after* a payment has run, so it shows **HOW YOU GOT HERE** at the top with the real trail — you asked where to pay, they shared a private address, you sent — and beneath it the current step's claims with the earlier steps still readable under an "earlier" rule.
> *Why: this is the "how has the context changed over the life of the transaction" idea made literal, and it is the bit of the app I'd most like argued with. It is also the shot that shows the panel is derived from the conversation rather than being a static help page.*

## Where I'd like argument

1. **Is the four-stage framing right?** I've seen discovery/diligence/negotiation/settlement hold up across quite a few transaction types, but I'd like it broken.
2. **Is the unauthenticated bootstrap acceptable** for a peer-to-peer app, or is a fingerprint step table stakes and I'm rationalising?
3. **Findable vs unlinkable** — is showing users both models honest, or is it abdication? Should an app with a privacy thesis refuse to ship the public directory?
4. **What's the actual threat model for the contact graph?** I can state that a store node sees subscription shape. I'm less sure how much that matters in practice versus how much it *sounds* like it matters.
5. **Where is this worse than what you already use?** Genuinely. I'd rather hear it here than after publishing something triumphant.

## Next

Diligence — how you establish that someone is who they claim and has what they say, and how much of that can happen without a third party learning you asked. Then negotiation, then settlement, where I'll get into what a private payment actually costs (measured: about seven minutes of saturated CPU, which changes what the feature *is*).

> **📷 SHOT 7 — the running job, as a teaser for the settlement post.** The job strip mid-payment: *"Paying 100 LEZ · sending · 4m 12s"*. Catch it well past the four-minute mark so the number is uncomfortable.
> *Why: it sets up the next posts and it is the single most surprising fact in the whole build. Optional here, mandatory later.*

---

### A note on the screenshots

Seven marked shots above; the post survives on **2, 3, 4 and 5** if you want it tighter. Two things worth doing before capturing any of them:

- Run the whole journey once first, so the trail and thread have real content. Empty states photograph badly and undersell it.
- Use two `--user-dir` peers so the addresses differ. One instance talking to itself is visible to anyone who looks closely, and this is a post about honesty.

Everything above exists in the app today except the on-chain label directory, which is in the execution zone's contract but not wired into Muster — so the findable-vs-unlinkable fork is currently an argument in prose, not a screenshot. Worth saying so in the post rather than implying a UI that isn't there.

The prototype is open. It is a week old, it is held together in places, and I'll be specific about which places.
