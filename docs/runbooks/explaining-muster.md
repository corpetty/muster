# Runbook: explaining Muster — provenance, validation, and information leakage

**Purpose:** the concepts to write posts from and to narrate over the lifecycle demo.
What Muster is built to do; how it captures data provenance *thoroughly* and why that
provenance is *validatable*; how information leaks across a transaction's lifecycle; and
how all of that maps onto the PriFi credibility narrative.
**Reads with:** `docs/runbooks/transaction-lifecycle-demo.md` (the live demo),
`docs/00-vision.md` (mission), `docs/design/action-manifest.md` §2 (the credibility axis),
`docs/01-furps.md` (F-4, F-5, F-16, F-20, FS-9, FS-10 — the properties named below).

Every claim here is backed by a shipped surface. The **claim → surface** table at the end
is the fact-check; keep it honest when you write.

---

## 1. What Muster is built to do

**Muster is a local-first client for coordinating multi-party transactions inside a
conversation, on the Logos stack — where the conversation is the security boundary.**

Not a wallet, not a chat app: the thing you do together — a payment, a group decision, a
shielded transfer — is the frame, and the room exists *because* of it. Its first job is
education: walk a person through the entire lifecycle of a multi-party transaction and
make the invisible parts visible — who can see what, at every step, and why — naming
exactly where a conventional stack leaks the same information. The teaching client and the
real client are the same client; nothing is a demo mode. If a step can't be shown
truthfully, that's a product bug.

Three load-bearing ideas, in the order they matter:

1. **State is a fold over a signed log.** `state = reduce(log)`. Every event is authored,
   signed, hash-linked to its causal parents, and encrypted to the room's member set.
   Nothing exists that can't be rebuilt from log + keys. This is what makes everything
   below *checkable* rather than *asserted*.
2. **You authorize semantics, the client checks the bytes.** Participants review an
   **effect** (a payment of X to Y); the client independently **re-derives** the
   **materialization** (the exact signable bytes) and refuses to sign on mismatch (F-4,
   un-disableable, FS-6). Every signing payload commits to environment, account, slot, and
   expiry, so a signature is worthless anywhere else (F-5).
3. **The room is the boundary, and it's honest about its edges.** Content stays inside the
   conversation; the client names, on every card, the one observer it cannot hide — the
   store node that sees the conversation graph (FS-9). It never lets "untrusted
   infrastructure" stand in for "blind infrastructure."

---

## 2. Data provenance — captured thoroughly, and validatable

This is Muster's sharpest technical claim, and it has two halves people conflate: **can
you capture where everything came from**, and **can anyone independently check that
capture is honest**. Muster answers both, and the second is the hard one.

### 2a. Capture: provenance for *every* action, inside the signed bytes

Most systems, at best, log an audit trail *beside* the data. Muster does two stronger
things:

- **On the signing path, provenance is committed to *inside* the signed bytes (F-20).**
  Every signing payload carries a record naming, for each input that reached the signed
  bytes, its **class** — a plugin block, a driver-interpreted contribution, an external
  read, or a peer message — and its **log position**. And the client **refuses to sign
  when any input's origin can't be accounted for**. An unaccountable input is a refusal,
  not a blank field. Because the record is *in* the signed bytes, you can't keep the
  signature and swap the story: change where an input came from and the bytes change.
- **Off the signing path, provenance covers everything else too (`coordinate_provenance`).**
  Messages, proposals, policy changes, signatures, declines, submits, settlements, and
  membership admissions are each classed by the same vocabulary, each with a plain-English
  **guarantee** of what the code actually enforces for that entry. The honesty is in the
  distinctions: a room-sealed *message* names its author as *what the sender wrote inside
  the envelope* — not a verified signature; only a **driver-verified signature** proves
  who; a *submit/final* is an **external read**, the member's report or the chain's answer,
  never asserted. Provenance that says "this is strong" and "this is only as good as the
  sender" *in the same view* is the point.

Crucially, provenance is a **reduction over the log**, not a side-car store (FS-10). A
provenance file written beside the log would rebuild identically on replay while handing a
keyless reader the whole lineage. Instead it's derived, and **scoped to the membership
epoch** of the entries it describes: a member who joins at a later epoch cannot reconstruct
earlier lineage, and an actor holding the log without an epoch's keys reconstructs none of
that epoch's record (F-16 makes this real — admitting a member re-keys forward).

### 2b. Validation: why the provenance can be trusted, not just displayed

Capture is worthless if you have to trust the client that shows it. Muster's validation is
that **anyone with the epoch keys can recompute the whole thing and refuse on any tamper**:

- **The materialization is re-derived, not trusted (F-4).** The client rebuilds the exact
  signable bytes from the displayed effect and refuses on mismatch — so "what you approve"
  is checkable against "what you see," locally, every time, and it can't be turned off.
- **The log is a self-verifying object (`coordinate_proof` / `coordinate_verify_proof`).**
  Export a slice; the verifier **recomputes every event's content id**, requires the slice
  to be **parent-closed** (no event dropped from the middle of a chain) and in **canonical
  order**, and re-reaches the claimed **state digest**. Any discrepancy is a refusal that
  names the first offending event. It is pure — it reads nothing but the proof. Tamper with
  one byte and it rejects. (Demo this live; it lands harder than any diagram.)
- **What a proof does *not* claim, stated plainly.** It proves the *log*, not the *world*:
  submit/final stay external reads. And it proves a message's *placement*, not its
  *author* by signature — a message's author is what the sender wrote inside a room-sealed
  envelope; only a driver-verified signature proves control of a key. Naming these two
  limits *inside* the guarantee text is what makes the rest credible.

The through-line: **capture is thorough because it's in the signed bytes and folds over
every event; validation is real because a keyholder recomputes it and the check refuses on
mismatch — no trusted display, no side-car, no "just trust the client."**

---

## 3. Information leakage across the transaction lifecycle

"Privacy" is too coarse. The honest unit is **who can see which field, at which step** —
and Muster renders exactly that.

### 3a. The lifecycle as an observability problem

Walk `draft → proposed → collecting → executable → submitted → settling → final` and, at
each step, four things are answered on-screen (the vision doc's curriculum): what happened,
what Logos protects here, where others leak the same thing, and what's still open. The
comparison is specific — name the system, the step, and the observer, never a strawman:

| Stage | Muster | A conventional stack, at the same step |
|---|---|---|
| Compose & propose | proposal lives in an E2E-encrypted conversation; store nodes see ciphertext | proposals sit in a coordination service's DB, visible to its operator, often behind an unauthenticated read API |
| Review | participants review the effect; the client re-derives the materialization and refuses on mismatch | signers approve opaque calldata or a hash they can't reconstruct — blind signing is the norm |
| Collect | approvals render as presence inside the room | who-approved-what is often visible to the coordinating service |
| Submit | the card names what became public and what stayed inside; the RPC intermediary is named | the whole coordination history becomes linkable on-chain and in indexers; RPC providers see origin metadata |
| Settle | finality is driver-described; reorgs surface as honest state transitions | finality is assumed; reorgs silently rewrite the UI |

### 3b. The flow matrix — leakage made literal

`coordinate_flow` folds the log × each action's declared disclosure × the membership at
that point into a **field × observer matrix**. The observers Muster can name today: the
**room member** (inside the boundary), the **store node** (metadata — on *every* entry,
FS-9), the **RPC provider** (sees the signed tx before the mempool), the **chain observer**
(the public ledger), and the **target module** of an invoke. Inside-the-room rows list the
epoch-key holders at that position; the outside rows appear **at submit**, when the
information actually leaves. An undeclared driver yields an explicit `undeclared` row —
never silence.

### 3c. Same transaction, four honesties — the LEZ square

The clearest teaching artifact is the Logos Execution Zone's four rails: the *same*
transfer, public→public / public→private (shield) / private→public (deshield) /
private→private, each with a per-rail `Disclosure{amount, payer, payee}`. The amount is
public **unless both ends are shielded**; the payer is named by the source form, the payee
by the destination form. In Mode A the *receiver* decides how much to reveal by **which
address form they share** — a public id names them, a shielded key node does not. Put the
EVM version (amount, from, to all public) beside the LEZ private one (a commitment, a
nullifier, nothing else) and the leakage story tells itself.

### 3d. The gap you must name

Content is protected; the **conversation graph is not**. One content topic per
conversation means a store node sees your subscription set and your publish/fetch timing —
that *is* the graph, pseudonymously, and E2E encryption doesn't hide it. Closing it needs a
mixnet at the transport layer (the Logos stack is building one, `LOGOS-MIXNET`, status
`raw`), not an application change. Running your own store node is not a fix — it protects
the operator's metadata, not that of the people they talk to. **Name the gap at the step
where it applies; that honesty is the credibility.**

---

## 4. The PriFi narrative — credibility, not a privacy score

The PriFi framing distinguishes **imperative** credibility (the discretion to defect has
been removed structurally) from **motivational** credibility (the party *could* defect but
has a reason not to). Muster already grades on that axis in three places — and the whole
"who sees what" story is really a credibility story.

### 4a. Credibility is relative to an observer at a link — a matrix, not a badge

The same signed intent is **imperative** against the counterparty (they can't alter the
materialization — F-4, invariant 1 — or replay it elsewhere — F-5, invariant 2) and
**motivational** against the store node (which we *ask* not to analyse the graph, FS-9). So
the honest unit is *(lifecycle step) × (observer) → imperative | motivational | not
applicable*. Muster's registry adds two more values for gaps: **exposed** (no binding
exists — the information reaches an unbound observer, the outsider hazard) and
**not-applicable** (a limit, not a party to trust). Both name their party.

### 4b. Muster classifies; it never scores

The moment a commitment becomes a number, the residual trust disappears from view — which
is exactly the private-order-flow failure PriFi describes. So Muster's card says *"four of
five inputs are structurally bound; residual trust: the RPC provider, the store node."* It
**never** says "80% private." Every claim in the registry names its column (imperative /
motivational / exposed) and, where conduct or a view remains, *whose*.

### 4c. Which links Muster actually touches

Of PriFi's seven links — discovery, diligence, negotiation, contracting, ordering,
settlement, enforcement — Muster touches **negotiation** and **contracting** (the room's
agreement), a slice of **diligence** (F-14 identity binding), a slice of **ordering** (the
RPC sees the signed tx before the mempool), and **settlement** readback. Discovery and
enforcement are outside the room. Make claims over *those* links, not all seven.

### 4d. The Bybit frame — a link flipping columns

Bybit is the clean worked example: **settlement was imperative** (the multisig math held),
but **signing was motivational** (trust the interface). F-4 re-derivation moves signing
*into the imperative column* — you check the bytes, you don't trust the screen — and it can
prove it with a test. That single sentence — "re-derivation turns signing from motivational
to imperative" — is the strongest one-liner in the whole narrative. Lead with it.

---

## 5. How to structure a post from this

A reliable arc:

1. **Open on the boundary.** The conversation is the security boundary; a transaction has a
   lifecycle; each step leaks or doesn't. (§1)
2. **Show, don't assert.** Walk the lifecycle demo; at the payoff, open provenance, the
   self-verifying proof (tamper it live), and the flow matrix. (demo runbook + §2, §3)
3. **Name the leak.** The store-node metadata gap, and what closes it. (§3d) This is where
   trust is earned.
4. **Land on credibility.** The imperative/motivational axis; classify-not-score; the Bybit
   flip. (§4) This is the part that transfers beyond Muster.

Two rules that keep it honest: (a) every "others leak X" is specific — system, step,
observer; (b) where a comparison is *unfavourable* to Muster at a step, keep it in. The
teaching value of a stack is what it makes visible, including about itself.

---

## 6. Claim → surface (the fact-check)

| Claim in the post | Backed by |
|---|---|
| State rebuilds from log + keys | `reduce(log)`; `coordinate_activity` |
| Provenance is in the signed bytes | F-20 input record; `intents/provenance.nim` |
| Provenance for every action | `coordinate_provenance` (F-20 vocabulary over every event kind) |
| The log is self-verifying; tamper is refused | `coordinate_proof` / `coordinate_verify_proof` |
| Provenance is epoch-scoped, no side-car | FS-10; membership epochs (F-16) |
| You authorize bytes you can reconstruct | F-4 re-derivation (un-disableable, FS-6) |
| A signature is worthless elsewhere | F-5 replay binding (env + account + slot + expiry) |
| Who-sees-what, per observer, per step | `coordinate_flow` (field × observer matrix) |
| Store node named on every entry | FS-9 baseline disclosure rows |
| Same transfer, four disclosures | the LEZ `Disclosure{amount,payer,payee}` square |
| Credibility is imperative vs motivational vs exposed | the claims registry `credibility` field; `docs/design/action-manifest.md` §2 |
| We classify, never score | no numeric score anywhere in the card/registry — by rule |
| Re-derivation flips signing to imperative | F-4 vs the Bybit blind-signing failure |
| The residual leak is the conversation graph | FS-9; the mixnet (`LOGOS-MIXNET`, status `raw`) closes it |
