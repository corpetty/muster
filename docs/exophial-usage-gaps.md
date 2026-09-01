# Exophial usage in muster: intended model vs. actual practice

Audit date: 2026-09-01. Evidence: this repo's git history, `.pebbles/events.jsonl`,
`.pebbles/reducer_ledger.jsonl`, `.exophial/config.yaml`, `.claude/settings.json`,
`.pre-commit-config.yaml`, `.claude/doctrine/`, `.claude/skills/discuss-issue/SKILL.md`,
`contracts/specs/`, and the labbook. The exophial install itself was **not** available
to this audit — items it alone can settle are marked **[verify on the exophial machine]**
and collected in [`exophial-gaps-handoff.md`](exophial-gaps-handoff.md).

## The intended model (as exophial's own vendored artifacts state it)

1. **Intake.** An issue or utterance becomes a pebble (`pb`), then a discuss-issue
   dialogue produces a typed spec that passes `validate_spec` (vacuity, provenance,
   restatement coverage, criticality floor) and is linked to the pebble.
2. **Dispatch.** `exophiald` provisions one worker per pebble in an isolated worktree,
   routes the model from `.exophial/config.yaml`, and the worker follows doctrine:
   red-before-green, real fixtures, a handoff with a verification transcript.
3. **Integration.** `exophiald` is the sole integrator. At the commit boundary it
   re-grades: the spec oracle for a spec-linked pebble, or the configured `gate:`
   command for a spec-less one. It merges only on pass. The reroute hook keeps
   everyone else off main.
4. **Enforcement.** Pre-commit / commit-msg / pre-push hooks plus the Claude
   settings hooks make the conventions mechanical, not documentary.

## The actual timeline

| Period | Mode |
|---|---|
| 2026-08-06 → 08-20 | Spec-pipeline era: 12 pebbles get restatement-bound typed specs; probes authored per spec; one full handoff recorded (exo-526). |
| 2026-08-13 | Sole-integrator hooks removed as inapplicable; recorded in `labbook/exophial-hooks-without-dispatch.md`. |
| 2026-08-25 → 08-26 | Dispatch era: `exophial init` re-ran (hooks restored); repo history re-rooted in a single `reroute:` commit; 16 reroute-captured pebbles land through `exophiald` (`bus`/`integrate` commits). |
| 2026-08-27 → 09-01 | Plain-tracker era: pebbles used as create/comment/close issue tracking; no new specs; commits go directly to main with hand-written trailers. |

## Findings

### G1 — The spec pipeline covers 12 of 185 pebbles, none since 2026-08-20

185 pebbles exist; 12 carry a linked spec (`derived-exo-*`), all created 08-06 → 08-20
during the invariant work. Everything since — the P3/P4 landings, the two-instance
wire (exo-e17, exo-6bc), room-side submit (exo-966), latency (exo-38e), the current
open backlog (80 pebbles) — went through pebbles as a plain issue tracker with no
spec, no oracle, no gate. The `intake_derivation` config (criticality-routed spec
derivation, tiers + thinking budgets) is fully configured and, on this evidence,
unused since. The tool's load-bearing idea — acceptance graded by a machine-checkable
oracle, not by the worker's own account — applies to none of the recent work.

### G2 — Every merge exophiald performed was graded by nothing

The 16 pebbles `exophiald` merged (08-25/26) are all `land: worker/reroute-*`
pebbles — staged human work the reroute hook captured. None has a spec, and the
`gate:` command for spec-less pebbles is **commented out** in `.exophial/config.yaml`.
Each merge nonetheless recorded `exophial-verdict: {"verdict": "pass"}`. With no
spec oracle and no gate command, that verdict had nothing behind it. The ledger
asserts machine-graded acceptance that did not occur.

### G3 — Every spec-linked pebble that reached the integration regate failed it, and the work landed anyway

The reducer ledger records, for 8 spec-linked pebbles (exo-2dc, 307, 51e, 525,
8dc, 8e7, f60, 3a1): `base-replay-verdict: red_on_base` (the added test is real),
then `gate-verdict: <sha> failed`, then `exophiald: gate_failed — not merged`.
Yet all 12 spec pebbles are closed and their work is on main. The likely root
cause is environmental — the regate scrubs PATH/env, and
`module/tests/probes/probe_return_marshalling_host.nim` documents (exo-a5d) the
hermetic fallback written to survive exactly that scrub — but the outcome stands
either way: **the one flow exophial exists for (oracle-graded merge) has never
completed green end to end in this repo.** The specs were authored, the probes
pass by hand, and the gate that was supposed to connect them was bypassed.
**[verify on the exophial machine]** — re-run one regate and root-cause the failure.

### G4 — History re-rooting broke every evidence link

The repo's git history begins 2026-08-25 with one `reroute: capture staged work
off main` commit containing the entire tree — all P0–P2/P4 work CLAUDE.md dates
to 08-19/20 has no commit-level history here. Consequences:

- The exo-526 handoff cites commit `38e3a3b…` — unresolvable in this repo.
- Every `gate-verdict: <sha>` in the reducer ledger cites an unresolvable SHA.
- The audit chain the tooling is built to produce (handoff → commit → verdict →
  merge) is broken at every link for the pre-08-25 era.

The referents may survive in the original machine's kept worktrees
(`.worktrees/worker-exo-*`) or reflog. **[verify on the exophial machine]** —
recover or at least record the mapping before the worktrees are cleaned.

### G5 — The machinery exempts itself from the discipline it enforces

All 36 `bus`/`reroute`/`integrate` commits lack the `Tested-Behavior:` /
`TDD-Exempt:` trailer that `tdd-trailer.sh` rejects commits for, and lack the
`Session-Id` trailer. All 22 session commits since 08-27 comply. If machinery
commits are exempt by design, the exemption should be stated somewhere; today it
reads as two-tier enforcement.

### G6 — The trailers are not git trailers

Session commits write `Tested-Behavior:` followed by a blank line, then
`Co-Authored-By`, another blank line, then `Session-Id`. Git's trailer parser
recognizes only the final contiguous block: `git log --format='%(trailers:key=Tested-Behavior)'`
finds **0** of 58 commits. The grep-based hook accepts them, but any downstream
tool using real trailer parsing (`git interpret-trailers`, `%(trailers)`) sees
nothing. Fix: write all trailers as one contiguous block at the end of the message.

### G7 — The labbook's prediction came true, silently

`labbook/exophial-hooks-without-dispatch.md` (08-13) removed
`block_worktree_leak` / `fix_worktree_index`, noted `reroute-main-commit` was
deliberately not installed, and predicted `exophial init` would restore all of it
wholesale via `reconcile_claude_settings`. Current `.claude/settings.json` and
`.pre-commit-config.yaml` carry all of it again, and the reroute hook fired
repeatedly on 08-25/26. The labbook entry still tells a reader the hooks are
removed. Either the repo now deliberately runs dispatch (08-25/26 says it did,
briefly) and the labbook needs a follow-up, or reconciliation silently reverted
a recorded decision. Upstream ask either way: a per-repo opt-out in the init
manifest. **[verify on the exophial machine]** — whether HEAD has one now.

### G8 — Enforcement exists on exactly one machine

Six pre-commit hooks have `entry: exophial-*` with `language: system`, and
`.claude/settings.json` shells out to `exophial hook …` five ways. On any host
without the tool — this remote session included — those hooks fail or are
skipped, and the settings hooks silently no-op. Observable consequence: commits
on 08-27 → 09-01 landed **directly on main** with `reroute-main-commit`
installed in config; enforcement did not travel with the repo. The trailer
discipline held anyway (hand-written), which is to the sessions' credit, not the
tooling's. Related: `.exophial/config.yaml` pins `coordination_repo` to the
absolute path `/home/petty/Github/corpetty/muster`.

### G9 — Doctrine is the unedited generic seed

`principal.md` says "edit it freely once installed to match the actual
principal's stated preferences." Nothing in `.claude/doctrine/` mentions muster,
Nim, or chronos; the per-language files are `testing-python.md` and
`testing-typescript.md` for a Nim repo. The repo's real conventions live in
CLAUDE.md. A dispatched worker seeded with this doctrine gets generic guidance
plus no `testing-nim.md`.

### G10 — Smaller drift

- **claude-md-coverage vs. reality:** the hook requires new source directories
  to carry a CLAUDE.md; all eleven `module/src/*/` directories lack one. Either
  the hook's "new directory" semantics never matched these, or it never ran.
  **[verify on the exophial machine]**.
- **discuss-issue skill links:** `docs/decisions/…` and
  `tests/test_discuss_issue_spine.py` are exophial-repo paths; they resolve to
  nothing in muster. The muster-local note is pinned to observations of HEAD
  `ab26cdb` (08-08) and tracks HEAD — the `relation_class` set, the
  `proof_obligation` gate defect, and the missing CLI verbs may all have moved.
  **[verify on the exophial machine]**.
- **settings.json `"if": "Bash(git commit:*)"`** on the `fix_worktree_index`
  hook — confirm current Claude Code honors a per-hook `if` key; if not, the
  hook runs on every Bash call. **[verify on the exophial machine]**.
- **worker_model:** the `default: "sonnet"` tier is unreachable (routing sends
  everything to `frontier`). Harmless; confusing.
- **Backlog:** 80 open pebbles, including decomposition children and superseded
  items. Needs a triage pass.

## What works as intended (for contrast)

- The 12 specs are real new-form specs: restatement spans, span-bound oracles,
  `property_test`/`model_check` acceptance tests, every referenced probe exists
  under `module/tests/probes/`, every spec is pebble-linked by a `pb comment`.
- The exo-526 handoff is a model completion-contract artifact: status, summary,
  verification transcripts, and a discriminating-mutation proof (green at HEAD,
  red under a seeded fault, reverted).
- Pebble hygiene in the recent era is good *as an issue tracker*: closes carry
  evidence comments, follow-ups are spun out as new pebbles (exo-001, exo-38e,
  exo-76a from the e17 close).

## The shape of the gap, in one place

Muster adopted exophial's **vocabulary** (pebbles, specs, trailers, doctrine,
hooks) and, for two weeks in August, its **spec authoring**. It has never had a
working **grading loop**: spec-linked work failed the regate and landed by hand;
spec-less work merged with vacuous verdicts; recent work skips specs entirely;
and enforcement only exists on the one machine that has the binary. The decision
that needs making is the posture: either fix the regate environment and adopt
dispatch for real, or record officially that muster uses exophial for
discuss-issue spec authoring plus pebble tracking only — and make the hook set
match that choice so `exophial init` stops re-installing the rest.
