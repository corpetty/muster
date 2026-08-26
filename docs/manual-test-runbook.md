# Manual test runbook — the spec-first client (`module/` + `ui/`)

What this validates: everything built for the room/coordination experience that a
headless test and `nix build` **cannot** confirm — the on-screen render, the
delivery-backed room loop, the verify/provenance dive-ins, the policy/effect pickers,
intent-driven **priming**, **multi-room**, **per-intent policy**, and the **Settings**
shell. The module logic underneath each step is already covered by Nim tests; this
checks that it reaches the screen and behaves.

Work top to bottom. Each **✓ Expect** is what "pass" looks like; note anything that
differs and report it (a short "what to report" list is at the end).

> Every signature you need is pre-computed in **Appendix A** — copy-paste, no
> tooling. They are valid only for the exact effect values named in each step.

> **This pass (2026-08-26):** `make build` again first — it carries the fixes from
> your last run (accent tiles, Enter-to-send, the honest "M of N" header, the larger
> verify text, the honest ready-note) **and** the new model: **policy is per-intent,
> not per-room** (an intent is a policy boundary; a room can hold several under
> different drivers). Parts 2–3 are **reset to unchecked** so you re-confirm the fixed
> behavior; each fix is flagged **✓ Fixed — confirm**. Part 4 is rewritten for the
> per-intent model (two policies in one room).

---

## Prerequisites

- The machine you've been building on (the local `logos-module-builder` checkout
  + `cache.nix.logos.co` substituter that `make` passes for you).
- The local `muster_module` flake lock is current (it is, as of this writing).
- **Optional**, only for Part 7's on-chain submit: `foundry` (anvil + cast).

---

## Part 0 — build & launch

```bash
cd <repo>
make build      # slow the first time (pre-builds the runner); once
make run        # opens the standalone app window
```

- ✓ **Expect:** a window opens on the **Home** surface. A nav bar sits across the
  **top** in its own strip: `Home | Room | Account | Walkthrough | Settings`, with a
  hairline divider under it.
- ✓ **The nav bar has its own strip** — it must **not** overlap the content below it
  on any surface (the fix). Content starts *under* the divider, everywhere.

---

## Part 1 — nav & surfaces (the render checks)

- [x] The current surface's nav button is **filled** (accent); the others are neutral.
- [x] Click **Room**, **Account**, **Walkthrough**, **Settings**, **Home** in turn.
      Each surface renders **below** the nav bar (no overlap), and the filled button
      follows you (Home stays filled while composing, its sub-flow).

---

## Part 2 — home & composing a room

- [x] On a fresh launch Home reads **"Nothing waiting on you"** and
      **"Nothing on yet. Start something with someone."** with a **Start something**
      button.
  - ✓ **Fixed — confirm:** the top **nav buttons now wrap to a second row** when the
    window is too narrow to hold them, instead of running off the left edge. (Was:
    "buttons get cut off if you make the window smaller.")
- [x] Click **Start something** → the **composer** opens: four verb tiles
      (*Pay someone*, *Ask to be paid*, *Split a cost*, *Just talk*).
- [x] Pick a verb → the **"Who's doing it with you?"** and **"How does the room
      approve?"** steps reveal below it (progressive disclosure). The confirm button
      names the next step ("Open the room — just you" if no peer).
  - ✓ **Fixed — confirm:** the **selected** tile reads in **accent** (raised + accent
    border), easy to tell from the unselected ones (was grayscale-only before).
- [x] **How does the room approve?** shows two tiles — **Safe · 2 of 3** and
      **Threshold · 2 of 3** — the policy for the **first** thing you'll propose here.
      Pick one; the selected tile is raised. (You can leave it on Safe; you can also
      change it per-proposal in the room.)
- [x] Click **Open the room** → the **Room** surface opens with a topic like
`muster.pay.…` in the header, its first proposal defaulting to the policy you picked.
- [x] **Priming (a money verb):** the room opens with an **address-request** card in
      the thread — headed *"For: Pay someone"* — because the intention needs somewhere
      to send funds. (A *Just talk* room primes nothing.)
  - ✓ **Fixed — confirm:** the priming card (and in fact **every** card — proposals,
    address-share, receipts) now renders. (Was: "nothing happens after the room is
    opened." Cause: a delegate declared `required property int index` for the
    duplicate-card fix but not `modelData`, and in Qt 6 that stops `modelData` being
    injected — so every message body failed to parse and rendered blank. Fixed by
    declaring `modelData` required too.)

> This is also the **delivery-node test.** Opening the room calls `coordinate_join`,
> which boots the embedded delivery node. If the room opens and the roster shows at
> least **you** (Part 3 / scope panel), delivery booted. If Join hangs or the room
> never populates, that's the most important thing to report.

---

## Part 3 — the room: chat, propose, and the dive-ins (Safe policy)

**Chat**
- [ ] Type in **"Say something"** and press **Send** → your line appears in the
      thread with a short author id + a timestamp.
  - ✓ **Fixed — confirm:** pressing **Enter** in "Say something" also sends the message.

**Answer the priming request**
- [ ] On the address-request card, click **Share an address** → an **address-share**
      card appears naming a **public account** and an address. ✓ **That address is
      YOUR own** (the account from Settings § identity), not a placeholder.

**Propose a payment**
- [x] Click the **`+`** in the message row → the compose panel opens with a **Kind**
      toggle (*Payment* / *Statement*), a **Next proposal** policy toggle (*Safe* /
      *Threshold*), and fields. ✓ The policy toggle reflects your composer pick and
      sets the driver for **this proposal** (each card keeps its own — see Part 4).
- [x] Kind = **Payment**, policy = **Safe**. Recipient:
      `0x1111111111111111111111111111111111111111`, amount `1000`. Click **Propose**.
- Note: right-click paste isn't available (design-system limitation); **Ctrl+V** works.
- [x] ✓ **Expect:** a proposal card appears **inline in the thread** (not a side
      panel), headed **"Pay… · 2 of 3"**, showing `1000 → 0x1111…1111`, a status rail
      (proposed → collecting → ready → paid), and approval slots (**0 of 2**).
  - ✓ **Fixed — confirm:** the header reads **"… · 2 of 3"** (M-needed of N-owners),
    not "2 of 2".

**Dive in #1 — "what am I signing?" (the verify box)**
- [ ] Click the green **"✓ your client re-derived this — the exact bytes you'd sign"**
      line → it expands to:
      - `shown` — `1000  →  0x1111…1111`
      - `re-derived` — a 32-byte `0x…` hash (the safeTxHash)
      - `domain` — `anvil-31337 · chain 31337 · Safe 0x5FbDB2…aa3`
  - ✓ **Fixed — confirm:** the verify-box text is now larger/legible.

**Dive in #2 — "how do I know this?" (provenance)**
- [ ] Click **"How do I know this? — N in the lineage"** → it expands to at least the
      **propose** entry: `[peer-message] the proposed effect` · `sealed to the room · log #…`.

**Approve → executable**
- [x] Click **Approve** on the card → a signature field appears. Paste **Safe owner
      sig 1** (Appendix A) → **Add** (or press **Enter**). Then **Approve** again →
      paste **Safe owner sig 2** → **Add**.
- [x] ✓ **Expect:** approval slots fill to **2 of 2**, the status rail lights to
      **ready**, and the provenance box now also lists **two** entries
      `[driver-contribution] an owner signature · 0x…(an owner) · verified owner · log #…`.
- [x] Before the second sig, paste the **same** sig again, or any random hex → ✓ it is
      **refused** (the count does not move; a non-owner signature never counts).
  - ✓ **Fixed — confirm:** once **ready**, the card shows the honest note
    **"✓ Ready — settle it on-chain from the Account view"** (no dead *Pay it* /
    *Drop it* button). Room-side submit is deferred; you settle on-chain in **Part 7**.

---

## Part 4 — policy is a property of each **intent**, the action is pluggable

**The model:** a room is a security/privacy boundary; an *intent* is a **policy**
boundary. A group can do several things at once, each under its own driver — so the
policy picker (relabelled **"Next proposal"**) sets the driver for the *next* thing
you propose, and each card keeps the policy it was born with. Because the intent id
now commits to its policy, the **same** effect under two policies is **two distinct
intents** — so you can do this **in the same room**, and the earlier tangle (a
re-proposed effect collapsing into one card) is gone.

**Threshold policy (a payment, no Safe / no chain).** In the **Safe room from Part 3**
(no fresh room needed): set **Next proposal → Threshold**, then **`+`** → Kind =
**Payment**, recipient `0x1111111111111111111111111111111111111111`, amount `1000` →
**Propose**.
- [x] ✓ **Expect:** a **new, separate** card appears (the Part-3 Safe card is
      untouched — its own intent, its own policy). The new card's rail reads
      **threshold** (not `safe`); open its verify box — `domain` is
      **`muster.threshold.v1`** (no chain, no Safe address), and `re-derived` is a
      longer hash (the base serialization, not a 32-byte safeTxHash).
- [x] ✓ Two cards now coexist under **different policies** in one room: the Safe
      payment (rail `safe`) and the threshold payment (rail `threshold`).
- [x] Approve with **Threshold payment sig 1** then **sig 2** (Appendix A) →
      ✓ reaches **2 of 2 / ready**, showing the honest **"✓ Ready — settle it on-chain
      from the Account view"** note. Provenance names two **`ed:…`** endorsers.

**A statement the room ratifies (a second effect type)**
- [x] New proposal: **`+`** → **Next proposal = Threshold**, Kind = **Statement**. Type
      **exactly**: `We ratify the treasury plan.` → **Propose**.
- [x] ✓ **Expect:** the card shows the **quoted statement** ("We ratify the treasury
      plan.") instead of an amount → destination; the verify box's `shown` is the
      quoted text.
- [x] Approve with **Threshold statement sig 1** then **sig 2** (Appendix A) →
      ✓ reaches **2 of 2 / ready** — a signed group endorsement of text, no payment.

---

## Part 5 — the scope panel (who can read this)

On the right side of the Room:
- [x] **In the room** shows a count and at least one member row (**you**, marked `· you`).
- [x] Tap a member row → its **full 64-byte identity** reveals (tap again to collapse).
- [x] **Add someone** is **disabled**, with a line explaining the join handshake
      isn't wired to a surface yet. (Honest dead-control fix, not a bug.)
- [x] The **Scope** line reads `end-to-end · N can read`, with the F-16 note about
      re-keying forward.

---

## Part 6 — multi-room

- [x] With one room open, go **Home** (nav). ✓ The room is listed as a row with its
      latest-intent headline (e.g. "Collecting approvals" / "Ready to submit").
- [x] **Start something** → create a **second** room, this time picking
      **Threshold** at "How does the room approve?" → it opens under Threshold.
```
  - ✓ **Fixed — confirm:** it now opens a **new, empty** room, not the existing one.
    (Was: "it opens the already existing room." Cause: two rooms of the same shape —
    e.g. two solo "pay" rooms — derived the *identical* topic, so `coordinate_join`
    re-activated the first. Each "Start something" now gives the topic a unique tail,
    so it's always a fresh conversation. Re-opening an existing room still goes through
    **Home**, which passes that room's stored topic.)
- [x] Go **Home** again → ✓ **both** rooms are listed. Click the first → ✓ it
      re-opens with its own thread and proposals intact — each card still showing the
      **policy its intent was proposed under** (Safe cards read `safe`, threshold
      cards read `threshold`), regardless of which room you're in or the current
      "Next proposal" default.
```

---

## Part 7 — the Account dashboard + the on-chain lifecycle

The **Account** surface is the single-instance Safe path (inspect + act directly +
settle on-chain).

- [x] Click **Account**. ✓ It reads "the Safe you coordinate against…", shows a
      **SAFE ACCOUNT** card (`Safe 0x5FbDB2…`, `2 of 3 owners · chain 31337 · anvil`),
      and an **"Owners — tap to see all 3"** line that expands to the three owner
      addresses.
- ✓ **Fixed — confirm:** the card now shows the real Safe, not "account not loaded".
    (Cause: `describe()` ran at startup before the lp/delivery library was initialized,
    and its `lp_protocol_version()` read blanked the whole account. `describe()` is now
    resilient to that read, and the Account nav re-loads on entry.)
- [x] **Wallet** card lists balances across chains, each with a **verified**/**attested**
      badge; **Refresh balances** re-reads. (Reads fail gracefully as "unavailable",
      never a false zero.)

**On-chain submit (needs anvil).** In a separate terminal, bring up the fixture:

```bash
# from the repo — see ui/tests/README.md § anvil for the exact MiniSafe deploy
anvil --silent &
cd infra/anvil && ./devnet.sh    # deploys MiniSafe at 0x5FbDB…aa3 and funds it
```

Then, on the **Account** surface:
- [x] **Propose a transfer — directly**: to `0x1111111111111111111111111111111111111111`,
      value `1000`, nonce `0` → **Propose**. The re-materialization strip shows the
      re-derived safeTxHash (green, "matches").
- [x] Paste **Safe owner sig 1**, then **sig 2** (Appendix A) via **Add signature** →
      the rail reaches **executable** and an **executable** notice appears.
- [x] **Submit on-chain** → ✓ it reaches **final** ("executed on-chain… finality read
      from the chain"). If anvil isn't up, ✓ it says so honestly ("is the RPC
      reachable?") rather than pretending it landed.

---

## Part 8 — Settings & config (the shell start, invariant 8)

The user-configurable infrastructure — "untrusted, user-chosen" is empty if you
can't configure it.

- [x] Click **Settings**. ✓ An **IDENTITY** card shows your `address`, `ed25519`, and
      `x25519` (the keystore's — read-only; keys never leave it). This is the same
      address a Part-3 address-share shared.
- [x] An **INFRASTRUCTURE** card shows the current **RPC endpoint** and **delivery
      node config**, each with an editable field + **Save**.
- [x] Type a different URL in the RPC field (e.g. `http://127.0.0.1:9999`) → **Save**.
      ✓ The "now:" line updates to the new value.
- [x] **Persistence:** close the window, `make run` again, open **Settings** → ✓ the
      RPC still reads your edited value (it persisted to `settings.json` beside the
      keystore). **Set it back to `http://127.0.0.1:8545`** and Save when done, so any
      later on-chain run (Part 7) points at anvil.

## Part 9 — the walkthrough

- [x] Click **Walkthrough**. ✓ It renders "The transaction lifecycle" with the six
      steps, each carrying claim cards badged **PROTECTS** / **OTHERS LEAK** / **GAP**,
      and an evidence line (a requirement id + test, or a fix + status).
  - ✓ **Fixed — confirm:** the claim **body** and **evidence** text are larger now
    (bumped from the smallest badge size to the body size), so the cards read easily.

---

## Appendix A — copy-paste signatures

Valid **only** for the exact effect values named. The client holds no keys; these are
signatures a signer's device would produce over the bytes the verify box shows.

**Safe owners** — for a payment `to 0x1111…1111, value 1000, nonce 0` (anvil owners 0 & 1):

```
Safe owner sig 1:
0x00278ad6c27d00993883a10909200661d6559d4eea8ca3c9ee3367e8761ba7056fe11cb9a6e87ede5aef673a0f075b220a3c6d37842743c91d9868d834edffcd1b

Safe owner sig 2:
0x7089eabcc8f8d1ff49a4b420d59f9b51f78ce7b498a5d4d17f1e07c0915231ca6443249c38693bbe3f1c12fc87e3a909c7c1e6ad8401d3d03c0b1fb751aa9d241b
```

**Threshold roster** — for the **same payment** (roster seeds 1 & 2, k-of-n=2):

```
Threshold payment sig 1:
0xdebaa9e2de62354edb9e17c5e1f395be795b4f02f44de1da3388d9c981124b6d9960941a7b701e402ad1ef3b52f70ea6d2ce6727ee0007876c3912c00a82310b

Threshold payment sig 2:
0x5cdfcfedd178ef7ee46586fd40352f3718d0a45743268babf41513874a28256d9822d7becda790ce6d67b590a86a5c00a6f074ecda352f012ba223eba2b3700a
```

**Threshold roster** — for the **statement** `We ratify the treasury plan.` (seeds 1 & 2):

```
Threshold statement sig 1:
0xfe4f356dc6077eb2a73950e5bde4a91196089594ef6634c2874e783ba3d20012a014de27cd9cd9c238865df1085a7e05ced9b9f3a9af3d4418979940de513800

Threshold statement sig 2:
0xd37cef30ca2994f70e4f9363f09767ad406e2040ae1f9c1603494a77504b17bb61b2bb85b181ebc5c1ebe113d7138a4ebe673b25a26115afb9f941af08253405
```

**To sign your own values** (any recipient/amount/text you type):

- **Safe** — the verify box's `re-derived` line is the safeTxHash. Sign it with an
  anvil owner key (0/1/2):
  ```bash
  cast wallet sign --no-hash \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    0x<the re-derived hash>
  ```
  (that key is anvil account 0 / owner 0; account 1's key is
  `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d`.)
- **Threshold** — the roster keys are demo seeds (1, 2, 3) and there's no stock CLI
  for raw Ed25519 over bytes; regenerate sigs for a new effect with the tiny snippet
  used to produce Appendix A (ask, or reuse `module/tests/threshold_fold_test.nim`'s
  `endorse` over the effect you want). The pre-computed ones above cover the runbook.

---

## What to report

For each part, "pass" or the specific difference. The ones that matter most:

1. **Part 0/1** — does it launch, and does the nav sit in its own strip with **no
   overlap** on any surface?
2. **Part 2/3** — **does the room open and function** (delivery node boots, chat +
   proposals fold)? This is the biggest unknown. And does a money room **prime** with
   an address-request, answered by an address-share carrying **your own** address?
3. **Part 3/4** — do the **verify** and **provenance** dive-ins expand and show real
   values? Do the **policy** and **kind** toggles change the card (rail/domain,
   payment↔statement)?
4. **Part 4** — can a **Safe** intent and a **Threshold** intent coexist in one room
   (each card its own rail/domain — `muster.threshold.v1` for the threshold one), and
   do the threshold sigs reach ready? Does proposing the same effect under a different
   policy make a **separate** card (not collapse into the Safe one)?
5. **Part 6** — does multi-room list and switch correctly, and does **each card keep
   the policy its intent was proposed under**, regardless of the current default?
6. **Part 7** — does the on-chain submit reach **final** against anvil?
7. **Part 8** — do edited RPC/delivery settings **persist across a restart**?
8. Anything that renders wrong, overlaps, or reads dishonestly (a claim the code
   isn't actually backing).

---

## Known issues (from your test pass)

**Fixed** (rebuild with `make build` to get them):

- **Selected tiles now read in accent**, not grayscale (composer verb + policy tiles).
- **The proposal header now reads "M of N" honestly** — e.g. `2 of 3` (threshold of
  owners), not `2 of 2`.
- **Enter sends** a chat message, and **Enter adds** a pasted signature.
- **A ready proposal now says so honestly** — "✓ Ready — settle it on-chain from the
  Account view" — instead of a dead *Pay it* / *Drop it* button. (Room-side submit is
  the next feature; on-chain settlement lives in **Account** for now.)
- **Duplicate proposal cards collapse** — re-proposing the same effect posts a second
  ref to the one intent; it now renders once.
- **The verify box text is larger.**
- **Policy is now per-intent, not per-room** — the room is a security/privacy
  boundary; an *intent* is a policy boundary. Each proposal remembers the driver it
  was proposed under, so changing the "Next proposal" default never re-folds a
  decision already collecting signatures, and **two policies can coexist in one room**
  (the same effect under two policies is now two distinct intents — the earlier
  collision is gone). The policy picker is relabelled **"Next proposal"**.
- **The room thread renders again (priming + all cards)** — the duplicate-card fix
  had declared `required property int index` on the message delegate without also
  declaring `modelData`; in Qt 6 that suppresses `modelData` injection, so every card
  body failed to parse and rendered blank ("nothing happens after the room is
  opened"). Declaring `modelData` required restores priming, proposal, address-share,
  and receipt cards.
- **The top nav wraps instead of clipping** — the nav buttons were right-anchored with
  no wrapping, so a narrow window ran the leftmost ones off-screen. They now wrap to a
  second row (a `Flow`), and the surfaces below start under the real nav bottom.
- **"Start something" always opens a new room** — two rooms of the same shape (e.g. two
  solo "pay" rooms) derived the identical topic, so the second re-joined the first. The
  composed topic now carries a unique tail; re-opening an existing room still goes
  through Home (its stored topic).
- **The Account card loads** — `describe()` ran at startup before the lp/delivery
  library was ready, and its `lp_protocol_version()` read blanked the SAFE ACCOUNT card
  as "account not loaded". `describe()` no longer depends on that read to succeed, and
  the Account nav re-loads the account + balances on entry.
- **Walkthrough claim text is legible** — the claim body + evidence lines were rendered
  at the smallest badge size; bumped to the body size so the cards read easily.

**Not yet fixed (design work, not a quick patch):**

- **Room-side submit** — a room reaches *ready* but settles on-chain only via the
  **Account** dashboard. Bringing submit into the room is a real feature (assembling
  the Safe `execTransaction` from the folded signatures).
- **Right-click paste** — the design-system text field has no context menu; **Ctrl+V
  works**, right-click doesn't. A design-system limitation, not ours to fix here.
