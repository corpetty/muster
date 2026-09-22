# Round 2 — Editorial notes (synthesizer)

Round 2 ran fresh critics on the recalibrated (round-1-revision) draft. Findings were
convergent: pacing + precision, no new argument holes. Disposition below. R2 = round-2.

## Acted on — structural / narrative

- **R2-adversary #1 (concession-to-mush) + R2-narrative (buried residual claim).** ACTED. Added
  a crisp residual-thesis sentence to the standfirst — the *actual* surviving claim (a
  per-input, class-and-position, strength-graded lineage folded from the encrypted log, at
  decision time) — and made it the spine, so the concessions qualify a stated claim rather than
  eroding an unstated one.
- **R2-narrative #2 (ship/not-ship concession stated 3+ times).** ACTED. Kept the full statement
  in "What of this actually ships"; trimmed the honest-status trailing summary to a pointer
  ("won't re-derive it") instead of a third restatement.
- **R2-narrative #1 (sN labels a memory tax — a regression I introduced).** ACTED. Dropped the
  "six clauses s1–s6" scaffolding and every bare `sN`; the clauses are now named in words.
- **R2-narrative #3 (why-Logos header over-promises).** ACTED. Header cut from "why Logos — and
  why not to overstate it" to "why Logos"; the section already leads with its claim.

## Acted on — factual / precision

- **R2-research (epoch crypto stale).** ACTED. "ECIES-secp256k1 epoch layer" → epoch keys wrapped
  as libsodium sealed boxes (ECIES over X25519) to each member's encryption identity, secp256k1
  as the bound authorization key (`epoch_crypto.nim:43–52`; ADR-010 amendment). My round-1 fix
  had echoed a stale code comment.
- **R2-research (SHOT 1 red-test asserted as settled).** ACTED. Softened: which side is wrong
  (code vs. drifted expectation) is an open call on `exo-eba`; get it green before shooting, and
  named the epistemic tension (credibility on "claims trace to a passing test" can't rest its
  one live proof on a red one).
- **R2-adversary #3 (s2 coverage proves internal consistency, not coverage of reality).** ACTED.
  Added the limit: the check is over inputs the code *registers*; an input that never enters the
  log is outside the guarantee.
- **R2-adversary #4 (missing nearest competitors).** ACTED. Added EIP-712 domain separation and
  transaction simulators (Blockaid, Tenderly) to the prior-art section; distinguished
  effect-prediction from input-provenance as complementary axes. Softened "no wallet does this"
  accordingly.
- **R2-adversary #6 ("structurally can't on Safe" = physics-as-overstatement).** ACTED. Reframed
  to "within the Safe signing standard" — a protocol constraint, not an impossibility; noted
  EIP-712 already binds environment and the call.
- **R2-adversary #8 / R2-research minor ("real code with real oracles" equivocates green oracle
  vs working guarantee).** ACTED. Honest-status core bullet now says a green oracle means the
  mechanism is correct, not that it's on a path a user reaches.
- **R2-research minor ("in-toto/SLSA ratified standard" overstates standards standing).** ACTED.
  → "a widely-adopted framework and specification."

## Acted on — argument (partial)

- **R2-adversary #2 (concession-theater: title claims what the product lacks).** PARTIAL. Did not
  retitle; instead made the standfirst state the narrower claim the body actually defends, so the
  title reads as the *problem* the post is about rather than a solved claim. Whether to retitle
  outright is left to the author (see summary) — it's the one thing a synthesizer shouldn't
  decide alone.

## Rejected / not acted

- **R2-adversary #7 ("why Logos" concedes into circular ergonomics).** NOT FURTHER ACTED. The
  circularity was already conceded in round 1 (the one-log requirement follows from Muster's
  chosen encoding, stated as such). The section now owns that explicitly; sharpening it further
  trades honesty for punch. Held.
- **R2-narrative #6 (citation density thickest where reasoning is subtlest).** LIGHT / HELD. Real,
  but the evidentiary density is the post's credibility move and the audience tolerates it;
  trimming risks under-supporting the subtle claims. Left for an author pass.

## Conflicts resolved

- **Length vs. added honesty.** R2-narrative flagged ~4,250 words and rising; the factual fixes
  (crypto, s2 limit, simulators, residual thesis) added net words. Resolved in favor of the
  substance for now — the piece is ~4,550 words and could lose 300–500 in an author trim, but no
  *substantive* content was cut to hit a length target. Flagged to the author.
