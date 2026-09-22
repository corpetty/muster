# Round 2 — Narrative Advocate

Scope: narrative clarity and reader engagement only. Not facts, not argument validity.
The draft is strong: the lede earns trust, the register is consistent with post 01, and
the honesty is a feature this audience will reward. The issues below are refinements to
pacing and threading, not structural collapse. Numbered by where they bite hardest.

---

1. **The `s1–s6` scaffolding creates more tracking load than it relieves (whole middle of
   the post, "The property" through "Provenance that respects anonymity").** The reader is
   told "six clauses I'll label s1–s6 as I hit them" (line 76), then meets them badly out of
   order and scattered across five sections: s1, s3, s2 in "The property"; s5, s6 in the
   audit-log section; s4 in the anonymity section. By the time s4 and s6 arrive, most readers
   have lost which number is which and can't cash the label back to a meaning without scrolling
   up. The labels buy precision for you and cost orientation for the reader. Either introduce
   all six in a tight numbered list up front (so the label always resolves), or drop the
   numbering and let each clause stand on its prose ("the byte-commitment," "the refusal,"
   "the two-way coverage") — which you already do well enough that the s-numbers may be
   redundant. Right now they're a running footnote the reader has to maintain.

2. **The ship/not-ship seam is stated at full length three-plus times — this is where honesty
   tips into repetition.** "What of this actually ships, said flatly" (lines 111–134) gives
   the complete s1/s3-not-wired-plus-Safe-can't-carry-it treatment. "The honest status, in one
   place" (lines 280–311) gives it again, including the near-verbatim "materially stronger than
   the demo and materially short of the title" (308–309), which itself echoes the intro's
   "further than any wallet I've used and shorter than the title" (13–14). Then open question 3
   (321–323) restates it as a question. The concession is right and belongs in the post, but
   made four times it stops reading as candor and starts reading as a loop. Recommendation: let
   the mid-post ledger (111–134) carry the *reasoning* (the Safe/EIP-712 structural limit), and
   cut "The honest status, in one place" down to the three-build table plus a single one-breath
   line — don't re-derive the seam a third time. The bookend intro/outro phrasing can stay; it's
   the middle full-restatement that's redundant.

3. **The climax — "So: why Logos" — is the most heavily hedged section in the post, and the
   header over-promises against the body.** The whole piece builds toward this answer, and the
   section correctly leads with its one-sentence claim (lines 219–222). But then three dense
   caveat paragraphs (mixnet/FS-9; "removes the coordination operator, not *the* operator"; the
   circularity defusal) deflate it into a deliberately modest result: "one fewer trusted party
   by construction... not a unique capability." That honesty is the right call, but narratively
   the payoff the reader climbed 3,000 words for lands flatter than the setup promised, and the
   header "why Logos — and why not to overstate it" spends more words on the second clause than
   the first. Fix is small: sharpen the affirmative claim so it survives the caveats with some
   energy left ("one client, one log, four stages, one fewer party — assembled, not stitched"),
   and consider trimming one of the three caveat paragraphs (the "differently located" /
   e2e-backend point in 240–244 is the most abstract and could compress).

4. **"What of this actually ships, said flatly" interrupts the property before the property is
   finished being explained (lines 111–134).** You introduce s1, s2, s3, then break to a full
   what-ships ledger, then resume with s4/s5/s6 in later sections. The reader learns half the
   property, gets told half of it doesn't ship, then goes back to learning the property. It's a
   jarring stop-start. Consider stating the whole property first (all six clauses, briefly),
   *then* the ships/doesn't-ship seam once — which also helps issue 2.

5. **The single most important conceptual distinction is placed as an aside (lines 64–70,
   "naming where an input came from is not the same as trusting it").** This is the hinge the
   whole post turns on — "provenance closes *I can't tell where this came from*, not *this
   source is trustworthy*." It's bolded, so it isn't lost, but it's framed as a mid-section
   caveat ("One thing to be exact about now...") tacked onto "The hole, worked." It's load-
   bearing enough to deserve its own beat or a subheading, so a skimming reader can't miss the
   one distinction that keeps the rest of the post from overclaiming.

6. **Inline code-identifier citations are densest exactly where the argument is hardest (the
   property section, lines 84–109).** `signedBytes`, `probe_provenance_binds`, `trySign →
   sdRefused`, `probe_provenance_refusal_stepper`, `coverageTwoWay`,
   `probe_provenance_coverage_stepper` all land within 25 lines, interleaved with the subtlest
   reasoning in the post. For this audience the citations earn credibility, but stacked this
   thick they slow the sentence you most need read cleanly. Consider pushing a few to end-of-
   sentence parentheticals or a footnote so the argument's prose stays unbroken; the "the oracle
   holds every input fixed, perturbs only provenance, and asserts the signed bytes always move"
   sentence (93–95) is doing real work and shouldn't have to share the line with a function name.

Minor / non-blocking:
- The anonymity section's "honest pincer" (lines 203–215) is dense but lands, largely because
  you give it a concrete anchor (*"entered as an external read, at this position"* vs *"is in
  the log"*, 210–212). Keep that example; it's what rescues the abstraction.
- "materialization" (line 32) is used before it's named as the noun for "the exact bytes";
  minor, the sophisticated reader infers it, but one bridging clause would smooth it.

---

**Summary.** The draft earns trust in its first two paragraphs and never breaks the thread
badly — this is a well-built, honestly-argued post whose problems are all pacing. The two that
matter most: the `s1–s6` labels (issue 1) impose a running memory tax that fights the density,
and the ship/not-ship concession is made at full length three-plus times (issue 2), so candor
starts to read as a loop. The climax section ("why Logos," issue 3) is where the piece is most
over-qualified relative to what its header promises — the payoff deflates just when it should
land. Tighten those three and the piece keeps all its honesty while reading a good deal faster.
