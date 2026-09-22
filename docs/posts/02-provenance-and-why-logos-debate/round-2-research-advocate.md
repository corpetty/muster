# Round 2 — Research Advocate (factual integrity)

The draft is unusually well-sourced: every probe name, every quoted guarantee string, every
clause label (s1–s6), and the core "no shipping caller for `signedBytes`/`trySign`" claim
check out against ground truth. Below are the places where the draft still states something
at greater strength, or greater settledness, than ground truth supports. Two are substantive
(#1, #2); the rest are precision notes.

---

1. **SHOT 1 note (lines 371–372): "the code is right and the test expectation drifted" is
   presented as settled fact; ground truth leaves it undecided.**
   The draft's capture note says of the red `coordination_surface_test` step 7:
   *"the code is right and the test expectation drifted — but get it green."* The ground-truth
   ticket (`.pebbles/events.jsonl:752`, `exo-eba`, still open — no close/status event) frames
   this as an **open question, not a decision**: *"Either the fold's provenance projection
   regressed with a later change (activity/provenance work) or the test's expectation is stale
   — decide which, then fix."* The direction the draft asserts is plausible (intentProvenance
   sets `what: "the proposal"` while the test at `coordination_surface_test.nim(140)` expects
   `"the proposed effect"`), but ground truth records it as undecided. This is a hedge that
   conceals an unmade determination — either soften to "I read it as a stale expectation, not a
   regression; exo-eba is still open," or make the call in the code and cite that, not assert it
   as already true. Ground truth: `.pebbles/events.jsonl:752`.

2. **Lines 254 (and the Figures/status echoes): "Muster's own ECIES-secp256k1 epoch layer" is
   stale against the current implementation and ADR-010's final amendment.**
   The draft describes the shipping epoch layer as *"ECIES-secp256k1"*. Per the current code
   (`module/src/crypto/epoch_crypto.nim:43–52`), the epoch key is wrapped with **libsodium
   sealed boxes over X25519** to each member's **X25519 encryption identity** (`EpochCrypto.myEnc`
   is "our encryption identity (Ed25519 + X25519)"; `eciesWrap` calls `sealTo(recipient.x, …)`),
   with the **secp256k1 key demoted to the authorization identity** bound to the encryption key
   by a signed link statement (`module/src/crypto/binding.nim:3`). This is exactly the
   2026-08-23 ADR-010 amendment (`docs/02-implementation-plan.md:242`), which relaxed F-14 to
   **two bound keypairs** specifically to fix the key-reuse bug of feeding one secp256k1 secret
   to both ECDSA and ECDH. So "ECIES-secp256k1" describes a *superseded* design; the accurate
   phrasing is "an X25519 sealed-box epoch wrap bound to the secp256k1 authorization key." Note
   the draft is echoing the code's own stale header comments (`epoch_crypto.nim:4–5`,
   `conversation.nim:9` still say "secp256k1") — but the wrap itself is X25519. Ground truth:
   `module/src/crypto/epoch_crypto.nim:43–52`, `docs/02-implementation-plan.md:242`.

3. **Line 264: "in-toto / SLSA … a ratified standard" slightly overstates their standing.**
   in-toto is a CNCF specification/attestation framework and SLSA is an OpenSSF
   framework/specification (SLSA v1.0, 2023); neither is a "ratified standard" in the formal
   standards-body sense the word implies. In supply-chain circles they are loosely called
   standards, so this is mild, and it is outside repo ground truth (no supporting file in the
   codebase). Recommend "a widely-adopted specification" or "the closest ratified prior art in
   supply-chain security" softened. The parallel claims in the same paragraph — Sigstore/Rekor
   and Certificate Transparency as append-only logs with third-party-verifiable inclusion proofs,
   and C2PA signing media content provenance — are stated accurately.

4. **Lines 132–134 / 304–306: "the other four clauses ship" is right in substance but slightly
   over-crisp on enforcement.** What ships (`intentProvenance`/`logProvenance` folded into
   `coordinate_intents`/`coordinate_provenance`, rendered by `MusterCard.qml`) is a *lineage
   projection* that surfaces the substance of s2/s4/s5/s6 (class + log position + named/silent
   account + epoch tag + reduction-over-log). But the live fold hardcodes `accountable: true`
   and never calls `coverageTwoWay` or the epoch-reconstruction gate at runtime — those remain
   the probe-level oracles (`intents/provenance.nim`, `coordination/intents.nim:586`). The draft's
   honest-status section mostly covers this ("graded by what the code can actually prove"), so
   this is a precision note, not a contradiction: "the accountable, graded, epoch-scoped lineage
   ships" is defensible as a description of the *view*, whereas "the four clauses ship" could be
   misread as "s2/s4/s5/s6 are live-enforced gates." Ground truth: `module/src/coordination/intents.nim:605–635`.

---

## Verified correct (the load-bearing distinctions hold)

- **(a) `signedBytes`/`trySign` have no shipping caller.** grep confirms both appear only in
  `module/src/intents/provenance.nim` and `module/tests/probes/` (plus the `.worktrees/` mirror).
  The draft's central "tested primitive, no caller on any shipping signing path" (lines 113–117)
  is exactly right.
- **(b) the live fold marks `accountable: true` and does not refuse.** Both `intentProvenance`
  and `logProvenance` set `accountable: true` unconditionally; no refusal path exists in the UI
  fold. The draft never claims otherwise and flags the refusal as unwired throughout.
- **(c) guarantee strings are verbatim.** *"sealed to the room's epoch — only a member could have
  placed it"* and *"the driver verified this recovers to a configured member"* match
  `intents.nim:626,635` exactly; the room-wide message grading is an accurate paraphrase of the
  `logProvenance` message guarantee.
- **F-20 quote (lines 36–38)** is verbatim from `docs/01-furps.md:32`; the "refusal is core
  behavior on the footing of FS-6" attribution matches `FS-10` (`docs/01-furps.md:45`); the
  EIP-712 `safeTxHash` structural limit (lines 122–130) is consistent with F-4/F-5 and the Safe
  rail described in `muster_module.nim`.
- **Mixnet/FS-9 status (lines 228–232):** "status raw, PoC wired into send only" matches
  `docs/00-vision.md:87–88` precisely; the "conversation-graph off subscription shape" framing
  matches FS-9 (`docs/01-furps.md:44`).
- **All six probe names, the criticality ("catastrophic"), and the "2 property tests + 4 model
  checks" tally** match `contracts/specs/derived-exo-3a1.spec.json` exactly.
- **exo-891 (lines 116–117):** the epic explicitly scopes "wiring `provenance.trySign`
  refuse-on-unaccountable into the live path" as separate out-of-scope work
  (`.pebbles/events.jsonl:605`) — the draft's characterization is accurate.
- **Prior demo Phase 6 (line 302):** "refuses to pay an address the room never named … no
  signing payload" matches `docs/posts/muster-connection-lifecycle.md:231–236`.
