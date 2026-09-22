# Round 1 — Research Advocate (factual integrity)

Scope: factual claims, citations, and stated-strength (built vs. specified vs. tested-primitive) only.
Grep evidence for the key target is recorded inline so each finding is verifiable.

Two of the seven findings are critical (axis 4: stated strength). The rest are precision/citation
fixes. The draft's central honesty move — labeling `signedBytes`/s1 as a tested primitive not yet
wired — is **accurate**; the problem is that it does not extend the same caveat to the *refusal*,
and it over-specifies the shipping crypto as MLS.

---

## 1. [CRITICAL — stated strength] The refusal (s3 / `trySign`) is presented as live client enforcement, but it is the *same* un-wired primitive as `signedBytes`, which the draft correctly caveats.

- **Where.** The "Refuses" section (lines 110–119): *"When any input's origin can't be accounted
  for, there is no signature — the client will not produce one (`trySign` returns `sdRefused`)."*
  And the honest-seam paragraph (lines 100–103), which places *"refusal on anything unaccountable"*
  inside *"what the client actually enforces and shows."*
- **Problem.** The draft carefully labels the byte-commitment half (s1, `signedBytes`) as *"a tested
  core primitive, not yet wired onto a shipping signing path"* (line 106) — but then hands the
  refusal half the opposite strength ("what the client actually enforces"). `trySign`/`sdRefused`
  live in the **same file** and have the **same status** as `signedBytes`.
- **Ground truth.**
  - Grep (repo-wide, excluding `.git`/`.worktrees`): `trySign` and `sdRefused` appear **only** in
    `module/src/intents/provenance.nim` (definition) and `module/tests/probes/probe_provenance_refusal_stepper.nim`
    (the probe), plus the draft itself. They are **never called from the live path**
    (`module/nim-lib/muster_module.nim` reads `item.accountable` only to serialize it to JSON at
    lines 899 and 1016 — there is no refuse branch).
  - `.pebbles/events.jsonl` exo-891 (epic) states explicitly: *"Out of scope: wiring
    `provenance.trySign` refuse-on-unaccountable into the live pasted-signature path (separate
    protocol task)."* So the refusal is not merely un-wired incidentally — it is a named, not-yet-done
    task.
  - In the live fold (`module/src/coordination/intents.nim`, `intentProvenance`/`logProvenance`)
    every entry is hard-coded `accountable: true` ("always true in a live fold", line 586). Nothing
    is ever marked unaccountable, so no refusal can fire. What actually ships on the approve path is
    the *driver's* recover-to-owner contribution check (`identifyContributor`), not the F-20
    four-class refuse-on-unaccountable.
- **Fix.** Apply the identical "tested core primitive, not yet wired onto a shipping signing path"
  caveat to the refusal that the draft already applies to `signedBytes`. Distinguish it from what the
  client *does* enforce live (driver contribution verification + the log-folded lineage *display*).
  As written, the "Refuses. Not warns…" passage reads as shipped behavior and is the strongest
  over-claim in the post. The UI intro text quoted for SHOT 1 — *"an input the client couldn't trace
  would have been refused before signing"* — inherits the same problem (nothing in the live fold can
  produce an untraceable input, so the refusal is vacuous on the shipping path, not active).

## 2. [CRITICAL — stated strength] "a real MLS-encrypted room" contradicts the ADRs; the shipping core uses a bespoke ECIES epoch layer, and MLS is explicitly out of scope for v0.

- **Where.** Line 215–216: *"The conversation boundary the record inherits is a real MLS-encrypted
  room with real forward re-keying on membership change ([F-16])…"*
- **Problem.** The provenance record is built in `module/` over the `CoordinationSession` log, whose
  crypto is Muster's own ECIES-secp256k1 epoch layer — **not** MLS.
- **Ground truth** (`docs/02-implementation-plan.md`):
  - Line 157 / 230 (ADR-002): *"MLS is explicitly out of scope for v0; the epoch scheme is the
    ADR-002 default."*
  - Lines 238–240 (ADR-010): *"BUILD Muster's own epoch layer for F-16; consume only
    logos-delivery-module"*; the shipping build is *"ECIES-secp256k1 `EpochCrypto` with F-16
    verified."* Native `logos-chat-module` MLS is the **future target** *"once it ships persistence +
    removal,"* not what runs today.
  - `docs/01-furps.md` F-16 (the cited requirement) says nothing about MLS.
  - MLS is real only in the **earlier demo** (`demo/muster-ui` / `chat_module` / libchat — see
    `docs/posts/muster-connection-lifecycle.md:52,96`), which is precisely the build the post frames
    as the *weaker* predecessor. Attributing MLS to the core whose record the post is about inverts
    that.
- **Fix.** Drop "MLS-encrypted," or replace with the accurate mechanism (an ECIES-secp256k1 epoch
  layer behind the `ConversationCrypto` seam, F-16-verified; MLS is the post-v0 target). F-16 supports
  "forward re-keying on membership change"; it does not support "MLS."

## 3. [MEDIUM — imprecise citation] The card dive-in is fed by `intentProvenance` via `coordinate_intents`, not by `coordinate_provenance`.

- **Where.** Line 242–243: the UI *"calls the module (`propose`, `approve`, `submit`, and the lineage
  fold `coordinate_provenance`) and renders what comes back,"* describing the "How do I know this?"
  card box.
- **Problem / ground truth.** The card's provenance box reads `card.provenance`
  (`ui/src/qml/MusterCard.qml:708–788`), which is populated by `intentProvenance(...)` carried
  per-intent inside `coordinate_intents` (`module/nim-lib/muster_module.nim:892`).
  `coordinate_provenance` is a **separate** method — the whole-log `logProvenance` feed (M4,
  `muster.lidl:44`), which the card box does not consume. The *end-to-end wiring claim itself is
  true* (real log-fold → module → card); only the method named is wrong.
- **Fix.** Name `coordinate_intents` (or `intentProvenance`) for the card dive-in, and reserve
  `coordinate_provenance` for the room-wide lineage view if you mean that surface.

## 4. [LOW–MEDIUM — surface conflation] The plain-message grading is from the whole-log feed, not the card dive-in the paragraph is about.

- **Where.** Lines 250–252, inside the bullet describing the card's "How do I know this?" dive-in:
  *"A plain message's author is only ever what its sender wrote inside a room-sealed envelope…and the
  record *says so*."*
- **Problem / ground truth.** That guarantee string belongs to `logProvenance` (message entries,
  `intents.nim:690`), i.e. `coordinate_provenance`. `intentProvenance` — the fold behind the card box
  the paragraph is describing — only emits **propose** and **sig** entries (`intents.nim:619–635`);
  it never folds plain messages. So the example is real code, but it is on a *different* surface than
  the one the sentence is attached to.
- **Fix.** Either move the plain-message example to the whole-log lineage surface, or note that the
  message-authorship grade appears in the room-wide provenance view rather than the proposal card.

## 5. [LOW — citation locus] The F-4 quote is verbatim from F-20's text, not from F-4.

- **Where.** Lines 34–36: *"…so I'll quote it rather than soften it: F-4's re-derivation 'proves a
  materialization is consistent with its effect and says nothing about where the effect's own inputs
  came from, so correctly-derived data of unknown origin satisfies it.'"*
- **Ground truth.** That exact sentence is the **last sentence of F-20** (`docs/01-furps.md:32`),
  describing F-4. F-4 itself (line 16) does not contain it. The quote is accurate and its attribution
  ("F-4's re-derivation") is conceptually right, but a reader following an F-4 link won't find the
  words.
- **Fix.** Cite the sentence to F-20 (where it lives) while still crediting the point to F-4's
  re-derivation.

## 6. [LOW — citation] FS-8 does not support "store nodes and RPC endpoints untrusted and user-chosen."

- **Where.** Line 214: *"no server-side application state, store nodes and RPC endpoints untrusted and
  user-chosen ([FS-1], [FS-8])."*
- **Ground truth.** That clause is **FS-1** (`no server-side application state… Store nodes and RPC
  endpoints are untrusted and user-configurable`). **FS-8** is telemetry/phone-home/auto-update. FS-1
  is already cited, so this is harmless, but FS-8 is the wrong support for the untrusted-infra clause.
- **Fix.** Drop FS-8 here, or cite it only for the (implicit) no-telemetry point.

## 7. [LOW — note, not a draft error] The on-display lineage assertion SHOT 1 leans on is a currently-red test.

- **Context.** The implementation plan (`docs/02-implementation-plan.md:171`) says
  `coordination_surface_test` step 7 asserts the live lineage. `.pebbles/events.jsonl` exo-eba (open
  P2 bug, 2026-09-16) records that **step 7 fails on main**: the test expects the first item's `what`
  to be *"the proposed effect,"* but `intentProvenance` returns *"the proposal"* classed as a
  peer-message. The **code matches the draft** (the draft's grading strings are verbatim from
  `intents.nim:626,635`); the *test expectation* is stale. No claim in the draft is wrong here, but
  the "graded trail is on screen … folded from the same log" support (SHOT 1, lines 319–327) rests on
  a probe/test that is currently red for a cosmetic-expectation reason worth resolving before the shot
  is presented as proof.

---

### Verified accurate (so the synthesizer does not over-correct)

- **s1 honesty is correct.** `signedBytes`/`buildProvenance`/`encodeProvenance` appear only in
  `provenance.nim` + `module/tests/probes/`; the draft's "tested core primitive, not yet wired onto a
  shipping signing path" (line 106) is exactly right. This is the draft's strongest and most
  defensible passage.
- **Criticality "catastrophic"** — matches `derived-exo-3a1.spec.json` (`"criticality":
  "catastrophic"`).
- **Six clauses = 2 property tests + 4 model checks** (lines 236–240) — matches the spec's test types
  (s1, s5 property; s2, s3, s4, s6 model_check) and probe names.
- **Guarantee-grading strings** (lines 250–252) — verbatim from `intents.nim` (`intentProvenance`
  guarantees at 626/635; message guarantee at 690).
- **Mixnet status** (lines 196–200: `raw`, PoC send-only, not near-term) — matches `00-vision.md:85–89`
  and FS-9.
- **Demo "refuses to pay an address the room never named"** (lines 62–64, 255–257) — matches
  `muster-connection-lifecycle.md:232` (Phase 6).
- **FS-10 claims** (refusal cannot be disabled "on the same footing as FS-6"; epoch scoping;
  participant-can-always-disclose boundary) — matches `01-furps.md:45` FS-10.

---

## Summary (top findings)

1. **Critical:** the *refusal* (s3, `trySign`/`sdRefused`) is presented as live client enforcement,
   but grep proves it lives only in `provenance.nim` + its probe, is never called from `nim-lib`, and
   exo-891 lists wiring it into the live path as explicitly out-of-scope — it is the *same* un-wired
   primitive as `signedBytes`, which the draft correctly caveats and the refusal does not.
2. **Critical:** "a real MLS-encrypted room" (line 215) contradicts ADR-002 ("MLS explicitly out of
   scope for v0") and ADR-010 (Muster builds its own ECIES-secp256k1 epoch layer); MLS is the demo's
   crypto and the post-v0 target, not the shipping core's, and F-16 doesn't mention MLS.
3. **Medium:** the card "How do I know this?" dive-in is fed by `intentProvenance` via
   `coordinate_intents`, not `coordinate_provenance` (lines 243) — the wiring is real, the method name
   is wrong; and the plain-message grade cited there actually belongs to the whole-log `logProvenance`
   surface (lines 250–252).
4. **Low:** the F-4 quote is verbatim from F-20's text, not F-4 (fix the citation locus); FS-8 is
   miscited for FS-1's untrusted-infra clause (line 214).
5. **Net:** the draft's core honesty (s1 as tested-but-unwired) is accurate and well-supported; the
   two critical fixes are about *not* letting the refusal and the room-crypto claims drift to a
   stronger "shipped" strength than the code and ADRs support.
