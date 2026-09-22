# Debate summary — 02-provenance-and-why-logos

- **Rounds run:** 2 full critic rounds (of a default max 3), each 3 parallel critics, plus a
  synthesis revision after each. Stopped before a 3rd critic round: round 2 converged on pacing
  + precision with no new argument holes, so a 3rd pass is diminishing returns and the residue is
  authorial taste. The skill's guidance is to surface remaining weaknesses rather than grind.
- **Convergence status:** substantively converged. Round 1's two factual overclaims (refusal
  presented as live; "MLS") and round 2's precision issues (epoch crypto, s2 coverage limit,
  missing competitors, "structurally can't," oracle-vs-guarantee) are all fixed in the draft.
  What remains is author-taste (length, title) and two code tasks that gate publication.

## Round 1 → recalibration

Round 1 found the shipping path doesn't do the headline (s1 byte-commitment AND s3 refusal are
tested-but-unwired primitives; live fold hardcodes `accountable: true`). Author chose "recalibrate
& ship honest." Round-1 revision repositioned to the honest-ledger thesis and added the
accountable≠safe beat, the prior-art section, the insider-boundary concession, and the
"Logos removes only the coordination operator" correction.

## Round 2 → tightening

Round 2 found the recalibration over-corrected: the surviving novel claim was never stated
crisply while concessions piled up (adversary), the ship/not-ship concession was made 3+ times
and the `sN` labels were a memory tax (narrative), plus precision fixes (research: stale epoch
crypto; unsettled red-test asserted as settled). Round-2 revision added a crisp residual-thesis
spine, cut the repetition, dropped the clause labels, and applied every precision fix.

## The critiques that drove the biggest changes

1. **The shipping path does not do the headline thing (R1, A1, A2).** Grep-verified: both the
   byte-commitment (`signedBytes`, s1) and the refusal (`trySign`, s3) are tested primitives
   with no caller on any shipping signing path; `exo-891` names wiring the refusal as
   out-of-scope. The draft had caveated s1 but presented s3 as live enforcement. Fixed: both
   now carry the caveat, and the honest-status summary states it plainly.
2. **"MLS-encrypted room" is factually wrong (R2).** v0 uses Muster's own ECIES-secp256k1
   epoch layer (ADR-010); MLS is the demo's crypto and a post-v0 target. Fixed.
3. **Accountable ≠ safe (A3).** Provenance *documents* the opening malicious-RPC hole; it does
   not *close* it. FIXED — now an explicit beat in "The hole, worked."
4. **Missing prior art + over-generalization (A6, A7).** FIXED — prior-art section (in-toto/SLSA,
   Sigstore/Rekor, C2PA) plus, in round 2, EIP-712 and simulators (Blockaid/Tenderly); "almost
   every stack" scoped.
5. **"Why one stack" circular (A8, A9); boundary dodges the insider (A10, A11).** FIXED —
   Logos removes only the coordination operator (RPC survives); one-log-requirement conceded as
   an encoding choice; boundary conceded useless against an insider or removed member.

## Known weaknesses that remain (surface, don't bury) — and the two gating tasks

- **Verifiability ceiling.** Even once wired, a local refusal isn't third-party-verifiable
  unless the commitment reaches the signature — which on the Safe rail it can't *without leaving
  the Safe signing standard*. This is a real ceiling of the shipping design, conceded in "What of
  this actually ships." Not a not-yet; a structural limit of the Safe rail.
- **Anonymous-model thinness.** Conceded in the anonymity section: stripped of identity, the
  value shrinks toward class+position, and the runtime (timing/ordering/slot) is not shown to
  keep the record's silence. Named as an open question, not resolved.

### Gating tasks before publication (code, not copy)

1. **`exo-eba` — get `coordination_surface_test` step 7 green.** The one live-proof screenshot
   (SHOT 1) leans on it; the ticket hasn't decided whether the code or the test expectation is
   wrong. The post's whole epistemology is "claims trace to a passing test," so this must be
   resolved green, not hand-waved, before the shot is presented as proof.
2. **`exo-891` (optional, changes the thesis) — wire `signedBytes`/`trySign` onto a signing
   path.** Only needed if the author later wants the strong "committed into what you sign"
   claim to be literally true on a shipping rail (and even then, not on Safe).

## Author decisions left open (synthesizer shouldn't make these)

- **Title.** Kept "A signature proves *what* you signed, not *where it came from*" as a
  problem-statement, with the standfirst now stating the narrower claim the body defends. An
  author may prefer a title that foregrounds the shipping claim rather than the industry gap.
- **Length.** ~4,550 words; could lose 300–500 in an author trim without cutting substance
  (candidates: the "wrong shape" event-sourcing aside, some inline citation density).

## Verified accurate (do not over-correct)

s1-as-tested-primitive honesty; "catastrophic" criticality; 2 property + 4 model-check
mapping; the guarantee-grading strings (verbatim from code); mixnet status; the demo's Phase-6
"refuse an address the room never named"; the FS-10 claims.
