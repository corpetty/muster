---
name: discuss-issue
description: Turn an issue (a GitHub issue, a Slack thread, or a spoken utterance) into a validated, gate-passing typed spec through an in-session dialogue. Use when an operator wants to intake a feature request or human-originated bug and author its acceptance oracles before any implementation. Supersedes scope-work.
---

# discuss-issue: interactive multi-source intake → a gated typed spec

This is the **human side of LINK 4** of the exophial pipeline
(utterance/issue → validated typed spec). It is NOT a trained classifier and
NOT a one-shot emitter: it is a **structured in-session dialogue** where the LLM
proposes and the human approves, per criterion. v1 is **in-session** (the
dialogue runs in the operator's session, sourced from GitHub/Slack/utterance);
replying inside the GitHub/Slack thread is a **non-goal** for v1.

Design canon (read first):
[`docs/decisions/2026-07-03-discuss-issue-skill.md`](../../../docs/decisions/2026-07-03-discuss-issue-skill.md).
It conforms to the pipeline FSM
([`../../../docs/decisions/2026-06-28-feature-as-assertions-pipeline-fsm.md`](../../../docs/decisions/2026-06-28-feature-as-assertions-pipeline-fsm.md),
the SPECIFY `needs-input → author` branch) — this skill adds **no workflow**; it
orchestrates ops that already exist.

## Muster-local note (installed 2026-08-07)

This copy was hand-installed (not shipped by `exophial init`, which only seeds
`.claude/doctrine/`) after the native `exophial discuss` Textual TUI proved
unreliable in this environment. Two adjustments versus upstream:

- The upstream doc below references `exophial issue ingest` / `exophial spec
  generate` as CLI verbs. The pinned install here (`exophial 0.2.0+6b362fef`)
  does not expose those as top-level subcommands — call the same underlying ops
  directly instead: `exophial.ops.ingest.ingest_issue(...)` and
  `exophial.ops.intake.generate_spec(...)` (plus `validate_spec` for the
  pre-check in step 4). Same gates, same schema, Python call instead of a CLI
  wrapper that doesn't exist in this build yet.
- The TUI (`tui/discuss.py`) references in step 2b/3 below are how upstream
  implements the restatement-block and per-criterion approval. Driven manually
  here, the *same two hard gates* still apply and must not be skipped:
  (1) the human approves the whole restatement before any oracle is authored,
  (2) each oracle is LLM-proposed and human-confirmed, never hand-written by
  the human and never emitted without at least the chance to send it back.

## What this skill is (and is not)

- It **orchestrates deterministic ops that already exist** — it does not
  reimplement them. The gates and the emitter are real code, invoked as CLI verbs
  / Python ops:
  - **ingest** — `exophial issue ingest` (`src/exophial/ops/ingest.py:ingest_issue`):
    GitHub/Slack/utterance → the normalized `IssueContext`
    `{source, ref, raw_text, participants, source_url}`, filed as a pebble with a
    `source_url` backlink. (exo-b0a.2.)
  - **the inline SPECIFY gate** — `validate_spec`
    (`src/exophial/ops/intake.py:validate_spec`) = `enforce_resolved ∧
    enforce_provenance ∧ enforce_vacuity ∧ enforce_restatement_coverage ∧
    enforce_level`. It **raises** on an unauthored / trivial / vacuous / unprovenant /
    intent-incomplete / under-verified spec. (`enforce_restatement_coverage` is the
    exo-cc7 intent-coverage gate: for a new-form spec every restatement span must be
    covered by ≥1 span-bound oracle.)
  - **the emitter** — `exophial spec generate`
    (`src/exophial/ops/intake.py:generate_spec`): writes the typed spec into the
    repo's spec dir and links it to the pebble via `pb comment`. `generate_spec`
    **runs `validate_spec` internally before it writes**, so a spec that fails the
    gate never reaches disk — the gate is un-skippable by construction.
- The **dialogue** (steps 2–3 below) is human-in-the-loop judgment via
  **AskUserQuestion**; it is deliberately NOT autonomously testable. The
  deterministic spine it drives IS tested:
  [`tests/test_discuss_issue_spine.py`](../../../tests/test_discuss_issue_spine.py).

## The flow

### 1. Present the normalized issue context; confirm intent

Run the ingest for the source at hand:

```bash
# `source` is a positional arg (github | slack | utterance).
# GitHub — fetched live via gh:
exophial issue ingest github --ref <issue-number-or-url>
# Slack — the thread is read by THIS session's Slack MCP tools
# (slack_read_thread / slack_read_channel); hand the tool result in as JSON:
exophial issue ingest slack --payload-json '<slack MCP result>'
# Direct utterance:
exophial issue ingest utterance --text "make a cli snake game"
```

This files a pebble carrying the `source_url` backlink and returns the pebble id.
Present the normalized `raw_text` / `participants` / `source_url` back to the
operator and, with **AskUserQuestion**, confirm: *is this the issue we are
specifying, and is the captured text complete?* If not, re-ingest / amend before
proceeding.

### 2. Elicit problem / goal / acceptance_criteria / criticality

Using **AskUserQuestion** at each step, elicit:

- **problem** — the observable symptom / why the work exists.
- **goal** — the end state in plain language.
- **acceptance_criteria** — each an outcome **verifiable WITHOUT reading code**.
  Press until concrete: *if you cannot name a test that would observe this, the
  scope is unclear — refine it.* "It should feel fast" is not a criterion; "p95
  request latency < 200ms measured over 100 requests" is.
- **criticality** — the MIL-STD-882E failure-consequence **severity**:
  `catastrophic` (Cat I) | `critical` (Cat II) | `marginal` (Cat III) | `negligible`
  (Cat IV). This selects the required **Level of Rigor** (see the oracle table below).
  A path whose failure means death / irreversible-loss / large financial loss is
  `catastrophic`; a serious-but-recoverable failure is `critical`; a moderate one is
  `marginal`; a minor one is `negligible`. (A "value can be minted/burned/moved" money
  path is classed by the SEVERITY of getting it wrong — usually catastrophic/critical
  — not by a separate `money` class; exo-cd2 retired that.)

### 2b. Restatement — show the LLM's faithful prose; human APPROVES it FIRST

For a **new-form (intent-captured)** intake (an `original_statement` — a captured
utterance — is present), the human faithfulness check happens **at the altitude
where completeness is visible: prose-to-prose, BEFORE any oracle exists** (exo-cc7;
ADR [`2026-07-05-restatement-bound-intent-capture.md`](../../../docs/decisions/2026-07-05-restatement-bound-intent-capture.md)).
This is what the snake capstone's per-oracle sign-off could not catch — each clause
was individually true while "played with arrow keys" had been silently dropped.

1. **show** — present the LLM's proposed `restatement`: the faithful, expanded PROSE
   of what the `original_statement` means as a requirement (e.g. "a person plays a
   snake at a terminal, steering with the arrow keys in real time, growing by eating,
   losing on wall/self collision"), decomposed into id-bearing `restatement_spans`
   (`s1`, `s2`, … — the intent enumerated where completeness is visible).
2. **approve (the block)** — with **AskUserQuestion**, the human approves the whole
   restatement as capturing intent. This approval is the **FIRST sign-off and a hard
   gate**: **no oracle is authored until it is approved.** In the TUI
   (`tui/discuss.py`) the flow sits in `Step.RESTATEMENT` and authoring / the emitter
   are unreachable until the human presses approve.

The TUI drives this step; the block + span-bound authoring is proven by
[`tests/test_tui_discuss.py`](../../../tests/test_tui_discuss.py)
(`test_restatement_blocks_oracle_authoring_until_approved`). A legacy
(`problem`-only) intake skips this step — the coverage gate is a no-op without
`restatement_spans`.

### 3. Per-criterion oracle — LLM proposes, human approves

For **each** acceptance criterion, run the loop (**AskUserQuestion** at the
decision point). For a new-form intake each criterion is **parallel 1:1 to a
restatement span**, and the authored oracle is **bound to that span** (its
`restatement_span_id`) with a one-line `proves` — so exo-cc7's two-way
`ops.restatement.check_restatement_coverage` gate has a span on every oracle (every
span covered by ≥1 oracle, every oracle bound to a declared span; a "played with
arrow keys" span with no covering oracle is REJECTED, forcing a play-and-verify
oracle):

1. **propose** — the LLM proposes the **gaming-resistant oracle** matched to the
   severity, and states **in plain language what it pins** (what a passing
   run proves, and what a broken implementation it would catch).
2. **correct / regenerate** — the human **confirms**, OR critiques and asks the
   LLM to **generate a different one**. The human **never hand-writes** the
   oracle — the LLM always authors it (well-formed in the executor's shape); the
   human is the critic/approver. Iterate until confirm.

This is the load-bearing guarantee (FSM ADR §1): *the feature IS its assertions,
and there is no prose→assertion compiler to confabulate* — the human owns the
**faithfulness** judgment (does this oracle pin what actually matters), with the
trivial classes machine-stripped in step 4.

**Oracle kinds by severity** (the gaming-resistant floor, exo-e2f.4 / exo-cd2):

| severity | required Level of Rigor | oracle kind the emitter writes | status |
|---|---|---|---|
| `negligible` (declaring a behavioral level) | `property` | `property_test` (Hypothesis property; inputs regenerate each run) | **emit-ready** |
| `marginal` | `bounded_model_check`+ AND a gaming-resistant oracle | `model_check` (bounded state-space), or `property_test` | gate-recognized (`model_check` executor pending) |
| `catastrophic` / `critical` | a TOP-STRENGTH oracle: `metamorphic` \| `model_check` \| `proof_obligation` | `metamorphic` (e.g. `relation_class: conservation`, sum-in == sum-out over real execution) | **emit-ready** (`metamorphic`); `model_check`/`proof_obligation` executor pending |
| any (highest core) | `proof` | `proof_obligation` (z3 / Lean discharge) | gate-recognized; executor pending |

`model_check` / `proof_obligation` are recognized by the criticality gate as
gaming-resistant (`src/exophial/ops/criticality.py:GAMING_RESISTANT_TYPES`; the
top-strength subset is `TOP_STRENGTH_TYPES`) but their executors are not yet landed;
for such a criterion, author the oracle intent and record it in the sign-off, and emit
at the highest **emit-ready** Level of Rigor the criterion admits (a `metamorphic`
oracle IS top-strength and emit-ready), noting the pending executor in the handoff. Do
NOT downgrade a catastrophic/critical/marginal criterion to a `grep`/`file_exists` —
the gate rejects an enumerable oracle standing in for a gaming-resistant one.

### 4. Inline SPECIFY gates — surface + regenerate IN the conversation

As criteria and their confirmed oracles accumulate, run the gate. The emitter in
step 5 runs `validate_spec` for you, but you can pre-check a candidate to catch a
weak one before you propose it as done:

```python
from exophial.ops.intake import validate_spec
validate_spec(candidate_spec)   # raises VacuityError / CriticalityError / ProvenanceError
```

If it raises — the oracle is **vacuous** (tautological/universal — `ops.vacuity`),
**unprovenant** (an assertion with no request clause — `ops.provenance`), or
**under-verified** (a catastrophic path without a top-strength oracle; a behavioral
verification level with only enumerable checks — `ops.criticality`) — surface the specific failure **in
the dialogue** and go back to step 3 to **regenerate that criterion**, not after.
A deliberately weak criterion caught here and regenerated is the normal loop, not
an error.

### 5. Emit the typed spec, linked to the pebble

Once every criterion has a confirmed oracle, emit:

```bash
# spec_id, problem, goal are positional; acceptance criteria are ONE
# comma-separated --acceptance-criteria value.
exophial spec generate <dotted-id> "<problem>" "<goal>" \
  --acceptance-criteria '<criterion 1>,<criterion 2>' \
  --criticality <negligible|marginal|critical|catastrophic> \
  --pebble <the pebble id from step 1>
```

`generate_spec` builds the spec **provenant by construction** (one oracle per
criterion, each citing its `request_clause`), runs `validate_spec` inline, writes
`<spec_dir>/<spec-id>.spec.json`, and adds a `pb comment` linking the spec to the
pebble. If it raises, the gate caught a residual weakness — return to step 3.

### 6. Sign-off provenance → handoff

Record the **auditable sign-off** in the discuss-issue session's handoff yaml —
this is the evidence that a human blessed each oracle:

```yaml
discuss_issue:
  pebble: <id>
  source: <github|slack|utterance>
  source_url: <backlink>
  spec: <written spec path>
  criteria:
    - text: "<criterion>"
      oracle_kind: <property_test|metamorphic|model_check|proof_obligation>
      pins: "<plain-language: what a passing run proves>"
      rounds:                 # the propose → correct/regenerate trail
        - proposed: "<oracle v1>"
          verdict: corrected
          critique: "<why the human sent it back>"
        - proposed: "<oracle v2>"
          verdict: confirmed
      confirmed_by: <operator>
```

One `criteria` entry per acceptance criterion; `rounds` shows every
propose/correct/regenerate step and the human's final `confirmed`. The record
must make plain that **the human never hand-wrote an oracle** — only proposed,
critiqued, and confirmed.

## Acceptance (what "done with a discussion" means)

A discussion is complete when: the ingested pebble carries its `source_url`
backlink; a typed spec exists, is **linked to the pebble**, and **passes
`validate_spec`** (non-vacuous, provenant, criticality-satisfying); every oracle
was **LLM-proposed and human-confirmed** with at least one demonstrated
correct→regenerate round where the first proposal was weak; and the handoff
records the per-oracle sign-off. The deterministic spine (ingest → validate_spec
→ generate) is proven wired to the real ops by
[`tests/test_discuss_issue_spine.py`](../../../tests/test_discuss_issue_spine.py).

## References

- `src/exophial/ops/ingest.py` — `ingest_issue` (the normalized front door, exo-b0a.2).
- `src/exophial/ops/intake.py` — `validate_spec` (the SPECIFY gate) + `generate_spec` (emit + link).
- `src/exophial/ops/criticality.py` — the severity floor + gaming-resistant oracle types.
- `src/exophial/ops/vacuity.py`, `src/exophial/ops/provenance.py` — two more SPECIFY gates.
- `src/exophial/ops/restatement.py` — the two-way oracle↔restatement-span intent-coverage gate (exo-cc7).
- `src/exophial/tui/discuss.py`, `src/exophial/tui/discuss_state.py` — the TUI shell + pure flow state (the `Step.RESTATEMENT` block + span-bound oracle authoring, exo-f11).
- `docs/decisions/2026-07-05-restatement-bound-intent-capture.md` — the intent-capture ADR (exo-cc7).
- `docs/decisions/2026-07-03-discuss-issue-skill.md` — the design canon (exo-b0a.1).
- `tests/test_discuss_issue_spine.py` — the deterministic-spine outer-loop test (exo-b0a.3).
- Supersedes the retired `scope-work` skill (removed in exo-b0a.4); its one
  durable idea — "if you cannot state a concrete test, the scope is unclear" — is
  carried forward in step 2.
