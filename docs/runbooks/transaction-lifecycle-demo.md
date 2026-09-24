# Runbook: demo the whole transaction lifecycle

**Purpose:** a repeatable script for showing — live — the entire lifecycle of a
multi-party transaction inside Muster, and, at each step, *who can see what and why*.
For a talk, a screen recording, or a written walkthrough.
**Audience:** someone who knows crypto but has not seen Muster.
**Reads with:** `docs/00-vision.md` (the six-step legend + the four-questions curriculum),
`docs/two-party-demo-runbook.md` (Safe vs FROST setup), `docs/runbooks/explaining-muster.md`
(the concepts to narrate over this).

The one sentence to open with: **the conversation is the security boundary, and every
step of a transaction is a teaching surface — the client shows what stays inside the room
and names exactly where a conventional stack leaks the same thing.**

---

## 0. What this demo proves

The lifecycle is `draft → proposed → collecting → executable → submitted → settling →
final` (F-3). The demo walks it once, and at each stage answers the four questions from
the vision doc **on screen, from real data**:

1. What just happened? (the mechanical step)
2. What does Logos protect here? (what stays in the room, and the property that guarantees it)
3. Where do others leak? (the same step in a conventional stack)
4. What's still open, and what would close it? (the residual gap, named honestly)

Nothing is a mock. The log is really signed, the payload is really domain-bound, the
proof really recomputes. If a step can't be shown truthfully, that is a product bug, not
a slide.

---

## 1. Setup (pick one track)

Two tracks, same coordination, different disclosure — **that contrast is the demo.**

| Track | Shows | Needs |
|---|---|---|
| **Safe (on-chain 2-of-3)** | every owner's signature disclosed on the public ledger; a real `execTransaction` | anvil + the real Safe v1.4.1 fixture, disclosed into the room by a member; peers seeded as real owners |
| **FROST / threshold (k-of-n Ed25519)** | the same agreement reaching finality with one aggregated endorsement — nothing per-signer on the wire | nothing beyond the app |
| **LEZ (shielded)** | the four rails and what each puts on the public record | the LEZ testnet + a funded account (see the LEZ delegation) |

**Safe track, local chain (the strongest single-machine story):**

```bash
cd infra/anvil && ./devnet.sh            # anvil + the real Safe v1.4.1 (2-of-3), prints SAFE_ADDR + RPC
```

Point the app's RPC at `http://127.0.0.1:8545` (Settings, or `MUSTER_RPC`) and seed each
peer with a real owner key (`scripts/demo-peer.sh`, or `MUSTER_DEV_SECP_KEY`) so their
in-app signature recovers to a configured owner. The headless proof that the on-chain leg
works, if you want it on a slide:

```bash
# with SAFE_ADDR from devnet.sh and the secp+stint closure (module/tests/README.md):
nim r -d:release --threads:on $SECP $STINT tests/safe_anvil_e2e.nim "$SAFE_ADDR"
nim r -d:release --threads:on $SECP $STINT tests/coordinate_submit_anvil.nim "$SAFE_ADDR"
```

Both settle a real transfer on chain (2-of-3 collected off-chain → `execTransaction` →
recipient funded). Run them to know the chain leg is honest before you demo the UI over it.

**To narrate the module round-trips headlessly** (no GUI, useful for a recording's
voiceover or to prove a payload), the LP-debug lines print each surface's JSON:

```bash
MUSTER_LP_DEBUG=1 …    # readiness / provenance / flow / decline payloads to stderr
bash scripts/card-self-test.sh     # offscreen: propose → readiness → decline → flow, all real
```

---

## 2. The beats

Run these in order. Each beat has **what's on screen**, **say this**, and **the dive-in**
— the surface that lets you *show*, not assert, the claim.

### Beat 1 — Start something (compose): intention first

- **On screen:** the composer. Pick the verb ("Send a payment"), the people, then the
  account/amount/destination (F-18's third step). The room opens *scoped to the action*.
- **Say:** "A chat app asks *who* first. Muster asks *what you're doing*, and derives the
  rest — it pulls in the wallet the action needs and primes the room to ask each person
  for exactly what the action requires: a payee's address, a share. The conversation
  exists *because* of the intention."
- **Dive-in:** the composer only offers actions **your account can actually do**, and the
  amount is bounded by your real balance — you cannot compose a payment you can't make.

### Beat 2 — The proposal is a card that carries its own accountability

- **On screen:** the proposal appears inline in the thread as a **card** with a live
  status rail (proposed → collecting → ready → paid). Open it.
- **Say:** "Every proposal is a card in the conversation, not a side panel. It carries
  its live state, folded from a signed, hash-linked log — `state = reduce(log)`. Nothing
  here exists that can't be rebuilt from the log and the keys."
- **Dive-in — this is the money shot:** the card's *"What this needs"* box answers the
  five questions from real data:
  - **What will it do** — the effect (to / value), human-readable.
  - **What is needed** — each requirement graded ✓/✗/? *for you* (`coordinate_readiness`):
    an RPC, a Safe-owner key (read from the chain, not assumed), a funded LEZ account.
    Unknown is shown as unknown; nothing is guessed.
  - **From you** — which of *your own* holdings fill the slots (`coordinate_offers`), and
    what each choice discloses. You never see anyone else's holdings.
  - **What will it touch** — the accounts/chains it writes.
  - **Who will see what** — the disclosure, grouped by observer, **store node included**.
  - **How do we agree** — the driver's policy (2-of-3 named owners, or k-of-n roster).

### Beat 3 — Review: you authorize bytes you can reconstruct

- **On screen:** the card shows the exact materialization (for Safe, the EIP-712
  `safeTxHash`) and the domain it binds to (chain id + Safe address + nonce + expiry).
- **Say:** "You approve a **semantic effect**; the client independently **re-derives** the
  materialization from that effect and *refuses to sign on mismatch* (F-4, and it cannot
  be turned off, FS-6). A signature here is worthless in any other conversation, account,
  or slot — every signing payload commits to environment, account, slot, and expiry (F-5)."
- **Where others leak (say it):** "The Bybit loss is the clean example — settlement was
  sound, but signers approved an interface they couldn't reconstruct. Blind signing is the
  norm. Re-derivation is exactly the move that turns 'trust the screen' into 'check the
  bytes.'"

### Beat 4 — Contribute (approve): presence, not a paste

- **On screen:** tap Approve. The slot fills. A second participant approves; the second
  slot fills; the card flips to **executable**.
- **Say:** "Approvals render as *presence* — slots fill as contributions arrive. You sign
  in-app with your own key; there is no pasted signature. One instance holding two owner
  keys can even fill two slots (keyed contribute). The driver verifies each signature
  recovers to a configured owner before it counts — a non-owner is refused, exactly as the
  chain would refuse it."
- **Contrast beat (do this if you set up both tracks):** run the *same* payment under
  **FROST**. Under Safe, each owner's signature is a distinct thing headed for the public
  ledger. Under FROST, the room reaches the same finality with **one aggregated
  endorsement** — nothing per-signer leaves. *Same agreement, different disclosure.* This
  is the single most memorable frame in the whole demo.

### Beat 5 — Submit: the boundary crossing is the only visual change

- **On screen:** tap Submit. The card settles on chain (`coordinate_submit` → a real
  `execTransaction` at the Safe's live nonce). Finality is **observed from the receipt**,
  never asserted.
- **Say:** "This is the one place the ground changes — in-room private, public dark. The
  submitted card names *what became public* (to / value / the whole transaction, every
  owner signature) and *what stayed inside* (who proposed, who deliberated, the room's
  discussion). The RPC provider sees the signed transaction before the mempool — we name
  that intermediary rather than hide it."

### Beat 6 — Final, and then prove the whole thing

- **On screen:** the card reaches **final**; the transfer landed.
- **Now open the three receipts that make this different from any other client:**
  - **Provenance** (`coordinate_provenance`): every action in the room — messages,
    proposals, signatures, submits, membership changes — classed by *how you know it*
    (a room-sealed message names its author but not by a verified signature; a
    driver-verified signature proves who; a submit is an external read). Provenance for
    *everything*, not just the signing path.
  - **A self-verifying proof** (`coordinate_proof` → `coordinate_verify_proof`): export a
    slice of the log; the verifier recomputes every content id, requires the chain to be
    parent-closed and in canonical order, and re-reaches the state digest. **Tamper with
    one byte and it refuses**, naming the first discrepancy. Do this live: export, edit,
    watch it reject.
  - **The information-flow view** (`coordinate_flow`): a matrix of *field × observer* over
    the whole transaction — who inside the room, the store node on every entry (FS-9), and
    the chain/RPC observers at submit. This is the "who can see what, at every step" made
    literal.

---

## 3. The honest close (do not skip this)

End on the residual leak, because naming it is the point:

> "Everything you saw about *content* is real — the effect, the signatures, the amounts on
> the room-native rail stay inside the conversation. What Muster does **not** hide is the
> conversation *graph*: a store node sees which topics you subscribe to and when you
> publish and fetch. End-to-end encryption doesn't cover that. Closing it needs a mixnet
> at the transport layer — the Logos stack is building one — not an app change. Muster
> names that observer on every card (the store-node rows) rather than quietly omitting the
> observer who sees the most. A curriculum that teaches 'who can see what' and then drops
> the observer who sees the most is marketing, not teaching."

That line is the whole ethos. It is also the bridge to the concepts runbook.

---

## 4. Cheat-sheet: claim → surface

| The claim you're making | The surface that shows it (not asserts it) |
|---|---|
| State is rebuildable from the log | the card folds from `reduce(log)`; `coordinate_activity` |
| You authorize bytes you can reconstruct | the re-derived `safeTxHash` on the card (F-4) |
| A signature is worthless elsewhere | the domain on the card: chain + account + slot + expiry (F-5) |
| Graded for *you*, not about others | `coordinate_readiness` ✓/✗/? + `coordinate_offers` (your holdings only) |
| Provenance for every action | `coordinate_provenance` |
| The log can't be tampered undetected | `coordinate_proof` / `coordinate_verify_proof` (recompute + refuse) |
| Who can see what, at every step | `coordinate_flow` (field × observer matrix, store node always present) |
| Same agreement, different leak | run Safe then FROST; compare what left the room |
| The store-node metadata gap | the store-node rows on every card; say the mixnet closes it |
