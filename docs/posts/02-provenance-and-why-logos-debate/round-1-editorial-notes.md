# Round 1 — Editorial notes (synthesizer)

Disposition of every substantive critique. R = research advocate, N = narrative, A = adversary.

## Fixed immediately in the main draft (factual — compelled, direction-independent)

- **R1 / A1 / A2 — refusal (s3) presented as live enforcement.** FIXED. `trySign`/`sdRefused`
  have no shipping caller (grep-verified; `exo-891` names wiring it as out-of-scope); the live
  fold hard-codes `accountable: true`. The "Refuses" section now carries the same
  tested-primitive-not-yet-wired caveat as `signedBytes`, and states what actually keeps
  unaccountable inputs out on the shipping path (driver recover-to-member + sealed-room), i.e.
  by-construction, not the explicit gate.
- **R2 — "MLS-encrypted room."** FIXED. Replaced with Muster's ECIES-secp256k1 epoch layer
  (ADR-010; MLS = post-v0 target). MLS was the *demo's* crypto; attributing it to the core
  inverted the post's own demo-vs-core framing.
- **A1/A2 — honest-status section hid the concession.** FIXED. The "state of the claim"
  summary now states plainly that s1 AND s3 are unwired primitives and what ships is the
  graded lineage; "materially stronger than the demo, materially short of the title."
- **R3 — card fed by `coordinate_intents` not `coordinate_provenance`.** FIXED (method named
  correctly; wiring claim was already true).
- **R4 — plain-message grade belongs to the whole-log surface.** FIXED (moved to a
  parenthetical about `coordinate_provenance`; the card fold only emits propose+sig).
- **R5 — F-20 quote miscited to F-4.** FIXED (quote credited to F-20, point still about F-4).
- **R6 — FS-8 miscited for untrusted-infra.** FIXED (dropped; FS-1 carries it).

## To fix in the recalibrated revision (pending the thesis-direction decision)

- **A3 — accountable ≠ safe (documents the hole vs closes it).** ACT. Add an explicit beat:
  classing the RPC address "external read" makes it *visible/accountable*, not *trustworthy*;
  provenance does not close the opening malicious-RPC hole, it makes the danger legible at the
  point of decision. State plainly whether a classed external read is refused or accepted
  today. This is the single most important argument fix.
- **A6 — missing prior art.** ACT. Acknowledge in-toto/SLSA, Sigstore/Rekor, C2PA,
  content-addressed DAGs; distinguish Muster's aim (a human approving a multi-party action
  *inside an encrypted conversation*, epoch-scoped, anonymity-respecting) from public
  transparency logs / build attestations. Removes the "unfamiliarity or omission" read.
- **A7 — "almost every stack" over-generalizes (and Muster's own Safe rail refutes it).**
  ACT. Scope to interactive multi-party signing UIs / wallets, where it holds.
- **A8 — "removes the operator by construction" overstates.** ACT. Logos removes the
  *coordination* operator (relayer/indexer/tx-service), not the RPC (which survives and is in
  the provenance); concede an E2EE server backend could host an encrypted log too. The honest
  claim is "differently located / one fewer operator," not "impossible off Logos."
- **A9 — "must be one stack" circularity.** ACT. Reframe: our *encoding* (fold over one
  encrypted log) needs one log; that's a design choice; here's why we made it. in-toto shows
  provenance without a single log, so don't claim provenance-as-such requires one stack.
- **A10 — boundary dodges the compromised/removed member.** ACT. Sharpen the concession:
  epoch scoping stops later joiners and pure outsiders; it does NOT stop a member/ex-member
  holding epoch keys from exfiltrating that epoch's lineage in bulk. True boundary = "everyone
  ever in each epoch." Say so.
- **A11 — anonymous-model accountability may collapse to 'it's in the log.'** ACT. Concede the
  pincer honestly: in the anonymous model provenance adds class + position + (once wired)
  refusal, not identity; the naming value lives in the named model, where disclosure was
  always possible. State what it does and doesn't buy.
- **A12 — anonymity section header vs runtime-leak concession.** ACT. Reconcile: soften the
  header or fold the runtime-leak caveat (timing/ordering/slot) into the section instead of
  leaving it only in "where I'd like argument."
- **A13 — refuse-on-unaccountable usability horn.** ACT (light). Note honestly; partly mooted
  because the gate is unwired today, but the conceptual tension (common refusal → users flee;
  rare refusal → is classing doing work?) deserves a sentence.
- **A5 — audit-log-vs-reduction false dichotomy.** ACT (light) + keep. N praised the concrete
  strawman; A called it lopsided. Resolve: keep the concrete "append a line to a file" image,
  add one concession that event-sourcing/CQRS also derive+encrypt, so the load-bearing
  properties (derived-not-stored, encrypted-and-scoped) aren't unique to us.
- **A14 — loaded framing.** ACT (light). Trim "subpoena target"; drop two of the three
  "catastrophic" repetitions; qualify "by construction."
- **A15 — "hole in F-4" is a strawman of re-derivation.** PARTIAL. Keep the reversal but
  reframe: not "a defect in F-4" (F-4 does its scoped job perfectly) but "a gap people mistake
  F-4 for covering." Small wording change.
- **A16 — humility as inoculation.** ACT (light). Keep the series register but trim one or two
  of the repeated "I want argument / I'd like that challenged" beats so landed critique isn't
  pre-absorbed.
- **N1 — seam paragraph placement/density.** ACT. Move the shipping-seam after both "Commits
  to" and "Refuses" land; break the sentence chain. (Interacts with the R1 refusal fix.)
- **N2 — "why Logos" buries its payload.** ACT. Surface the one-log/one-operator argument
  early with a signpost before the mixnet caveat runs.
- **N3 — abrupt transition into "why Logos."** ACT (light). One bridging clause.
- **N4 — bare undefined `s1`.** ACT. Define the six-clause map once, or drop the bare `sN`.
- **N5 — citation clotting.** ACT (light). Demote one nested parenthetical per clotted
  sentence.

## Rejected / no action

- None outright rejected. A15 and A16 are partially actioned rather than fully, with reasons
  above (F-4's "hole" is a fair reader-model point; the humility register is the series voice
  and only its *repetition* is trimmed).

## Conflicts resolved

- **N ("protect the audit-log section") vs A5 ("audit-log is a false dichotomy").** Kept the
  concrete strawman image (N) but added the event-sourcing concession (A5): the image stays,
  the novelty claim is scoped.
- **N ("protect the anonymity section, best-written") vs A11/A12 ("anonymity claim is a pincer
  / header outruns body").** Kept the crisp prose (N) but added the honest concession and
  reconciled the header (A). Prose preserved, claim calibrated.

## The one decision that isn't the synthesizer's to make

The fixes above, taken together, move the post's center of gravity from *"Muster commits
provenance into what you sign, uniquely enabled by Logos"* to *"here is a property interactive
signing should have; here is exactly how far Muster has gotten (shipping graded lineage +
tested-but-unwired commit/refuse primitives); here is the prior art; here is what the Logos
shape does and doesn't uniquely buy."* That is a stronger, more honest, and on-register piece
— but it is a reposition of the commissioned thesis, so it goes to the author before the
revision is copied over the draft. See `debate-summary.md`.
