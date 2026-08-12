# Post 1 — supporting material

**Reference, not prose.** Everything here is source material for the first post (the pipeline as a whole, then discovery). It is organised to be looked things up in while writing, not read start to finish.

The earlier prose draft is preserved in git history at `491fb1c:docs/posts/01-the-pipeline-and-discovery.md`; the phrasings worth keeping are collected in §11 rather than lost.

**Confidence marking is load-bearing.** Every factual row carries one:

- **[measured]** — observed on this machine, with the date and conditions
- **[from source]** — read off the code or contract of something we consume, not separately exercised
- **[inferred]** — reasoned from design; check before printing as fact

Rule inherited from `docs/00-vision.md`: never publish an `inferred` row as fact, and every gap names the fix *and that fix's real status* from a closed set — `shipped` / `specified` / `partial` / `none`. "Coming soon" is not a status.

---

## 1. The pipeline — use the seven-stage version

**This supersedes the four-stage framing (discovery / diligence / negotiation / settlement) in the earlier draft.** The seven-stage version is already published in the PriFi competitor matrix cross-check, so the post should be consistent with it rather than inventing a second taxonomy.

Stage names and leak descriptions, verbatim from that document:

| Stage | Leak being rated |
|---|---|
| **Discovery** | counterparties, intent: is there private counterparty/liquidity discovery, or Telegram/public frontends? |
| **Diligence** | address history, identity graph: can surveillance firms graph the chain? |
| **Negotiation** | size, terms, reservation price: pre-trade leakage to RPCs, quote infra, operators |
| **Contracting** | frontend and signing context: verifiable/local-first frontends, signing leaks |
| **Ordering** | pending order flow: mempool visibility, MEV, network-origin (IP) protection |
| **Settlement** | balances, approvals, positions: on-chain privacy, default vs opt-in |
| **Enforcement** | identifiable operators: can block producers be identified and coerced? |

Definitions worth restating in the post, because three of these are unfamiliar:

- **Contracting** — whether signing and execution context stays local and verifiable, or a web frontend introduces ambient leakage.
- **Ordering** — whether mempool contents, timing and MEV surface to validators, miners or network observers *before* confirmation.
- **Enforcement** — whether block producers are anonymous (censorship-resistant) or identifiable (coercible). Anonymous randomised selection is the standard; a permissioned sequencer set is not.

**Source:** <https://logos-co.github.io/assembly/resources/prifi-deck-competitor-matrix-crosscheck>

### What the extra stages do to the thesis

The four-stage version said *"the blockchain touches stage four, that's it."* Under seven stages that is wrong, and the corrected version is **stronger**:

- The chain is involved in **three** stages — Ordering, Settlement, Enforcement.
- Privacy discourse concentrates on **one** of them: Settlement. Shielded amounts, mixers, stealth addresses.
- **Ordering** gets partial attention (MEV, private mempools) and is mostly framed as an economic problem rather than a privacy one.
- **Enforcement** gets almost none, despite deciding whether anyone *can* be compelled.
- **Discovery, Diligence, Negotiation and Contracting** — four of seven, everything before a transaction exists — leak intent and are barely examined at all.

So: not "one of four" but **"privacy argument covers roughly one stage in seven, and it isn't the one that leaks the most about you."**

### Claims, so each can be attacked separately

| # | Claim | Support |
|---|---|---|
| T1 | An inter-personal transaction moves through these seven stages | Framing, published. §10 Q1 invites it being broken |
| T2 | The chain is present in only three of them, and privacy discourse in about one | Definitional plus observation |
| T3 | Stages 1–4 leak *intent*, to more parties than stage 6 leaks *value* | Argument, illustrated by the discovery case below |
| T4 | The operators in the middle — RPCs, quote infra, frontends, sequencers — are the least examined and often the most sighted | The matrix's own central finding |
| T5 | Leaks divide into: chosen by you, chosen by the stack for you, inherited by everyone | Framing, and the most reusable idea in the post |

The sharpest form of T3: from settlement an observer learns *an amount moved between two addresses at a time*. From the earlier stages they learn **who you considered dealing with, what you checked, what you asked for, what you settled on, what you rejected, and when you hesitated.**

**Two caveats to state early, both true and both easy to omit:**

- The pipeline **loops**. Diligence sends you back to discovery; negotiation surfaces a fact needing checking.
- The pipeline is **not universal in shape**. Discovery for "send a friend £20" is a different problem from discovery on a DEX, an NFT purchase, or a hire. This is why the series retells it per use case.

---

## 2. The scoring scheme, and Muster scored by it

The matrix rates each stage on three levels. Reusing it here rather than inventing a scale keeps the post consistent with the published work — and, more usefully, lets Muster be held to the standard its author is applying to everyone else.

| Mark | Meaning |
|---|---|
| ● **Closed** | leak closed by default architecture |
| ◑ **Partial** | partially mitigated or opt-in |
| ○ **Leaks** | essentially unaddressed |

The criterion the matrix applies, and the reason it is worth applying to ourselves: **default vs opt-in, and shipped vs roadmap, strictly — "because an adversarial investor will."**

### Muster as it stands today — draft self-assessment

**This is the most exposed thing in the post and needs your judgement before it goes anywhere.** It is scored strictly against the *demo as it runs*, not against the specification. Two cells are deliberately left unscored rather than guessed.

| Stage | Mark | Why, strictly |
|---|---|---|
| Discovery | ◑ | No directory, no lookup, no server that learns the edge — that part is closed by architecture. But the introduction is unauthenticated, and a relay still sees subscription shape. **[measured]** |
| Diligence | ○ | Not addressed at all. There is no diligence surface in the build; the next post is about what one could look like. Scoring this ● because "we don't do lookups" would be exactly the overclaim the matrix criticises |
| Negotiation | ● | The strongest cell. Terms are agreed inside an end-to-end encrypted room with **no coordination service anywhere in it** — no RPC, no quote infra, no operator sees the proposal, the approvals or the timing. Closed by default, not opt-in **[measured]** |
| Contracting | ◑ | Local-first by construction: a native client, no web frontend, no ambient leakage. But **the signing context is not verifiable** — the client does not re-derive what it signs (F-4/FS-6 are specified and unbuilt), so a user reviews an amount rather than a payload |
| Ordering | *not assessed* | Needs the zone's own answer on mempool visibility and sequencer behaviour. What is known: no network-origin protection (no mixnet), and the zone learns that a transfer happened and when. Do not score this without checking |
| Settlement | ◑ | Shielded on both ends by default, which is the ● case — but the **recipient is not credited at the address they published**, and the build carries a workaround. A stage that needs a workaround to complete is not closed |
| Enforcement | *not assessed* | The testnet runs against a single named sequencer, which by the matrix's own standard ("anonymous randomised selection is the standard, not permissioned sequencer sets") points at ○ — but confirm the production model before printing it |

**Why publish this.** The matrix's stated failure mode is "the same standard applied to one project and not its neighbour". A post that scores everyone else and exempts its own prototype would be the thing it is complaining about. Two ○/unscored cells and a ◑ on settlement is a more credible document than a row of ●.

**The honest headline:** on its own matrix, this build closes **one** stage of seven by default. That is a defensible result for a two-week prototype whose thesis is that the middle of the pipeline is neglected — it closes the neglected middle and leaves the well-trodden end open.

---

## 3. Discovery in Muster — what actually happens

**Mechanism.** The app mints a chat address locally, seconds after launch. No account, no registration, no name reserved, no confirmation. The address travels out of band (Signal, QR, across a table). The recipient pastes it into New chat. A conversation opens on both sides. **[measured — the app reaches `delivery is online` and mints an address with no account, signup or server call]**

### Protected

| What | By which mechanism | Confidence |
|---|---|---|
| Nobody is asked who you want to talk to | There is no directory, so there is no lookup to observe | [measured] |
| Nobody learns the edge | No service is involved in the introduction at all | [measured] |
| The conversation contents | `chat_module` end-to-end encryption (MLS for groups) | [from source] |

The comparison that makes it land: on a conventional stack "add contact" is *a request to a server whose business is knowing the edges of that graph*.

### Still open

**(a) The bootstrap is unauthenticated.**
Whatever channel carried the address is the weak link; if it was compromised, the attacker *is* the conversation. Muster cannot detect this and does not claim to.
*Fix:* fingerprint comparison over a second channel — standard, well understood.
*Status:* **`none`** — not built here. **[inferred from design — no in-band verification exists in this build]**

**(b) A relay still learns who talks to whom.**
One content topic per conversation; a store node sees which topics a client subscribes to and when it publishes or fetches. That is the contact graph, pseudonymously. End-to-end encryption does not touch it.
*Fix:* a mixnet at the transport layer. **Not** an app change, and **not** Tor — Tor hides *who by IP*, not *what links to what*.
*Status:* **`specified`, early.** `LOGOS-MIXNET` is a LIP at status **`raw`** — the earliest lifecycle stage, its own rationale section reading "To be defined" — with real supporting work (LIBP2P-MIX, cover traffic, LIONESS, RLN). The implementation is a testnet proof of concept **integrated into send only**; receive over mix is not there. Not on the published near-term Messaging roadmap (that's RLN, QUIC, Reliable Channel API, Status integration). **[from source, dated 2026-08 — re-check before publishing]**

**(c) Running your own store node is not a fix.**
It protects the operator's own metadata, not that of the people they talk to — and it *inverts* the threat: an operator serving content from their own node learns when a target fetches it. **[inferred — standard for this class of system]**

---

## 4. The findable / unlinkable fork

The cleanest teaching moment in the build, because the same stack ships both models.

| | Shielded receiving keys | On-chain label |
|---|---|---|
| How you're found | Address handed over in-band, inside the encrypted room | Human-readable name registered on-chain |
| Who learns you were looked up | Nobody — nothing is resolved | Anyone; the lookup is itself a public act |
| Permanence | None | The mapping is permanent |
| Convenience | Lower | Genuinely nicer |

`lez_core` exposes `add_label` / `resolve_label`. **[from source — present in the generated contract; not exercised in this build]**

**Important honesty point for the post:** the label system is *not wired into Muster*, so this fork is currently an argument in prose, not a screenshot. Say so rather than implying a UI that isn't there.

---

## 5. Numbers, with provenance

Every one of these is measured on the same machine (13-core desktop, LEZ testnet, 2026-08-11/12) unless noted.

| Quantity | Value | Notes |
|---|---|---|
| Shielded transfer, proving | **6 min 41 s** | single note, ~1300% CPU throughout. Timed from start of proving to the wallet's next write |
| Shielded transfer, second measurement | **7.4 min** | app-level, two peers |
| Shielded transfer, third measurement | **447 s (7 min 27 s)** | standalone PoC, direct against `wallet-ffi` |
| Private account registration | minutes (proves) | exact figure not isolated; exceeds the sync client's 20 s budget by orders of magnitude |
| Faucet prize | 150 units | proof-of-work claim |
| Sync to tip | ~0.2–1.3 s | 50-block range |

**The line worth making load-bearing:** a private payment is **not an interaction you wait on, it is a job you start**. That is a product fact, not a tuning constant — it changes what the feature *is*, and it bounds what a demo can show (you cannot screen-record it in real time).

**Do not state as typical.** Whether ~7 minutes is expected, hardware-bound, or a symptom of misconfiguration is *not established*. Ask whoever owns the zone before the post implies it is normal. What is established is that it happened, repeatedly, on this machine.

---

## 6. What changed since the draft was written

The draft predates the last two days of work. Four things are now true that were not:

1. **The payment journey has an authorization stage.** Payments can be proposed to a room, collect approvals against a chosen threshold, and only then be paid. Relevant to the *negotiation* post more than this one, but it changes what a screenshot of the app contains.
2. **The recipient-credit bug is understood.** It was open and unexplained in the draft. See §7 — it is strong material for the settlement post and a good illustration of T5 (a leak/limitation *nobody chose*).
3. **A workaround is shipped and labelled.** The app sums private accounts found by scanning. Disclosed on screen.
4. **The demo README now leads with "demonstrative only, do not put value you care about through this."** If the post links the repo, that framing is what a reader lands on — which is the correct outcome, but worth knowing.

---

## 7. The settlement finding (material for a later post, and for credibility here)

Kept in this document because it is the strongest evidence that the project's honesty rules do real work.

**What happened:** a shielded payment debits the sender and the recipient's balance never moves.

**Why:** a private account id is derived from *(viewing key, identifier)*. The keys a recipient hands out carry **no identifier**, so the zone's client picks one **at random** for each payment. The money arrives at an account derived from a number the recipient has never seen, while the account they created, registered and published stays at zero. **[measured, twice — two peers over the testnet, and a single-process standalone reproducer]**

```
private 021fbfac…4634 balance=0    <-- advertised, registered, polled
private b719ff50…259a balance=10   <-- the payment
```

**Not lost:** the note *is* discoverable by scanning with the recipient's viewing key, and the account appears in `list_accounts`. What fails is the obvious client behaviour of polling the address you published.

**Three wrong turns on the way**, each of which is a good story about why measurement is hard:

1. `register_private_account` *proves*, so through the sync client it hit a hardcoded 20 s timeout and had **never once succeeded** — a call that had been in the tree for a day.
2. It also requires an *uninitialized* account, so it works at creation or never.
3. `lez_core` has a **third failure convention**: 17 methods return a JSON envelope carrying `success: false` rather than the empty string the rest use, so the ordinary check reads a hard failure as success.

Plus a measurement trap worth its own sentence: **the balance read immediately after a transfer is stale.** The sender showed 150 → 150 right after the proof, and 150 → 140 on the next refresh.

Reported upstream with a single-file reproducer linking `wallet-ffi` directly: `demo/poc/`.

---

## 8. Figures available

Built and in **`docs/diagrams/`**. Each is SVG, in the prototype's palette, sized for a forum post's content width. *(Moved there from `docs/posts/figures/` and renamed to stable slugs on 2026-08-12 — the `figN-` numbering was relative to this post and would have collided with post 2's own fig1. The catalogue of what else is planned, and the conventions these follow, is `docs/diagrams/README.md`.)*

| File | Shows | Best used for |
|---|---|---|
| `pipeline-seven-stages.svg` | All seven stages with their leak descriptions, the four that precede a transaction, the three the chain is in, and the one the argument concentrates on | The thesis. The post's opening figure |
| `pipeline-self-assessment.svg` | Muster scored ●/◑/○ on its own seven-stage matrix, two cells left unassessed | The credibility move — see §2. Pair it with the seven-stages figure |
| `pipeline-discovery-comparison.svg` | Introduction with a directory vs without — who learns the edge | The discovery argument, side by side |
| `pipeline-relay-sees.svg` | Content vs metadata across the journey: what is hidden, what is not | The FS-9 honesty point made concrete |
| `pipeline-cost-of-privacy.svg` | Proving time against human-interaction thresholds | "Not an interaction, a job" — for the settlement post, optional teaser here |

SVG is the source; a 2× PNG sits beside each one, because most forum software handles PNG more reliably than SVG. Re-render after any edit:

```bash
docs/diagrams/tools/render-png.sh
```

Palette matches `ui/prototype/coordination-prototype-v2.html`, so figures and app screenshots sit together without looking like they came from different projects. Text is plain `<text>` — no font embedding — so anything that renders them substitutes a local sans; that is deliberate, and why nothing depends on a particular face.

**Two things the figures deliberately do not claim.** Fig 1's "to a directory / to an explorer / to a chat host" are illustrative of the conventional case, not measurements. Fig 4's band marked *"a person will wait this long"* is a rule of thumb about attention, not something measured here — the bars are measured, the band is not.

---

## 9. Screenshot shot list

Carried from the draft, with its reasoning intact. **The post survives on 2, 3, 4 and 5** if it needs to be tighter.

| # | Shot | Why it earns its place |
|---|---|---|
| 1 | Two app windows side by side, conversation open, exchange visible | Establishing: "one conversation that contains a payment", legible without the caption. Take it *after* the whole journey has run |
| 2 | The account card, close — avatar, short label, full address in mono, ideally mid-flash on *"Copied to clipboard"* | **This is the entire signup flow.** A reader who has onboarded to any wallet or messenger will feel the absence |
| 3 | New chat dialog with a real address pasted in, before Create | 2 + 3 together are the whole discovery mechanism. Two screenshots, no server |
| 4 | The two discovery gaps in the panel, with their fix and status lines | The post's credibility. Make sure a `status` line is legible — that's the sentence people quote |
| 5 | The disclosure table, close — **WHAT A RELAY SEES** and its four rows | The concrete version of the argument, and the ground changes colour because you crossed the boundary. **If there is room for one panel shot, use this** |
| 6 | The whole right-hand panel, full height, after a payment | "How the context changed over the life of the transaction", made literal and derived from the thread rather than a static help page |
| 7 | The job strip mid-payment, well past four minutes | Sets up the settlement post. Optional here, mandatory later |

**Before capturing anything:**

- Run the whole journey once first. Empty states photograph badly and undersell it.
- Use two `--user-dir` peers so the addresses genuinely differ. One instance talking to itself is visible to anyone who looks closely, and this is a post about honesty.
- A payment now shows the workaround note on the wallet card once money has been received. That is correct and worth *not* cropping out.

---

## 10. Where argument is wanted

1. **Is the four-stage framing right?** It has held across several transaction types; it wants breaking.
2. **Is an unauthenticated bootstrap acceptable** for a peer-to-peer app, or is a fingerprint step table stakes?
3. **Findable vs unlinkable** — is showing both models honest, or an abdication? Should an app with a privacy thesis refuse to ship the public directory?
4. **What is the actual threat model for the contact graph?** We can state that a store node sees subscription shape. How much that matters *in practice*, versus how much it sounds like it matters, is genuinely unsettled.
5. **Where is this worse than what you already use?** Better heard before publishing something triumphant than after.

---

## 11. Phrasings from the draft worth keeping

Lifted verbatim so they are not lost in the rewrite. Use, cut or rework freely.

- "I have always wanted a decentralised app that is about **what you are doing and who you are doing it with**. Not a wallet with a chat feature bolted on. Not a chat app with a wallet bolted on."
- "It turns out that building it does something more interesting than produce an app: it *teaches the pipeline*. And the pipeline is the thing almost nobody looks at whole."
- "The blockchain touches stage four. That's it." … "roughly a quarter of the problem."
- "Then you settle on a public ledger and congratulate yourself on using a privacy tool for the last step."
- On the three kinds of leak: "a leak **you chose** / a leak **the stack chose for you** / a leak **nobody chose** and everyone inherited. Most privacy writing collapses these."
- "The simplest possible pipeline instance: one person pays another. If we can't be honest about this one, the complicated ones are hopeless."
- "Which is right depends entirely on whether you'd rather be *findable* or *unlinkable* — and I don't think there's a universal answer."
- "The claims are structured data, not prose, specifically so a claim without evidence is visible as a hole rather than reading fine and being wrong."
- "It's a research post: I want argument, not applause."
- "The prototype is open. It is a week old, it is held together in places, and I'll be specific about which places."

---

## 12. Sources

| For | Where |
|---|---|
| Honesty rules, the worked mixnet example | `docs/00-vision.md` |
| Requirement IDs — FS-9 (metadata honesty), F-14/ADR-010 (identity binding), F-4/FS-6 (re-derivation), F-5 (replay binding) | `docs/01-furps.md` |
| What the demo protects and does not, row by row | `demo/GAPS.md` |
| The journey as run, in order | `demo/WALKTHROUGH.md` |
| The settlement bug: mechanism, measurements, reproducer | `demo/poc/BUG-private-transfer-recipient-identifier.md` |
| Zone call conventions and the traps | `docs/labbook/lez-core-error-conventions.md` |
| Why a green build proves nothing about the UI | `docs/labbook/qml-errors-are-invisible-to-nix-build.md` |
| Messaging contract | `logos-co/logos-chat-module` `rust-lib/chat_module.lidl` |
| Wallet contract, incl. the label system | `logos-blockchain/logos-execution-zone-module` `src/lez_core_module.h` |
| Platform gaps with upstream issue numbers | `logos-co/eth-lez-atomic-swaps` `delivery-dogfooding.md` |
| **The seven-stage pipeline, its leak descriptions and the ●/◑/○ scale** | [PriFi deck competitor matrix cross-check](https://logos-co.github.io/assembly/resources/prifi-deck-competitor-matrix-crosscheck) — already published, so the post should match it rather than introduce a second taxonomy |
