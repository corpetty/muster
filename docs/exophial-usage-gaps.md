# Exophial usage in muster: intended model vs. actual practice

Audit date: 2026-09-01. Evidence: this repo's git history, `.pebbles/events.jsonl`,
`.pebbles/reducer_ledger.jsonl`, `.exophial/config.yaml`, `.claude/settings.json`,
`.pre-commit-config.yaml`, `.claude/doctrine/`, `.claude/skills/discuss-issue/SKILL.md`,
`contracts/specs/`, and the labbook. The exophial install itself was **not** available
to this audit — items it alone can settle are marked **[verify on the exophial machine]**
and collected in [`exophial-gaps-handoff.md`](exophial-gaps-handoff.md).

> **Verification pass: 2026-09-02, on the exophial machine.** Every deferred item
> below has now been checked against the real install. Preflight green: `exophial`
> + `pb` on PATH, tool venv at `~/.local/share/uv/tools/exophial`, 46 kept
> `.worktrees/worker-reroute-*`, and the pre-08-25 objects present. Tool version
> **`exophial 0.2.0+dc69cd1d`**. Each finding below now carries a verdict —
> **CONFIRMED**, **REFUTED**, or **REFINED** — with the evidence that settled it.
> Two findings (G3, G4) were substantially wrong and are corrected in place.
> The audit's own text is left standing so the correction is legible.

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

> **VERDICT: CONFIRMED.** Unchanged by anything on this machine. Backlog is now
> **54 open** pebbles (the audit counted 80; triage has happened since).

### G2 — Every merge exophiald performed was graded by nothing

The 16 pebbles `exophiald` merged (08-25/26) are all `land: worker/reroute-*`
pebbles — staged human work the reroute hook captured. None has a spec, and the
`gate:` command for spec-less pebbles is **commented out** in `.exophial/config.yaml`.
Each merge nonetheless recorded `exophial-verdict: {"verdict": "pass"}`. With no
spec oracle and no gate command, that verdict had nothing behind it. The ledger
asserts machine-graded acceptance that did not occur.

> **VERDICT: CONFIRMED.** `.exophial/config.yaml` still has the entire `gate:`
> block commented out, so `exophial gate run` for a spec-less pebble has no
> command to run. Nothing on this machine supplies a default. Filed as **exo-efc**.

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

> **VERDICT: CONFIRMED that the loop has never run green — but the stated root
> cause is REFUTED.** All 12 specs were re-graded at HEAD on 2026-09-02 by calling
> the real grader in-process (`spec_oracle.run_spec(Spec.from_dict(...),
> Path('.'))`), which is the same entrypoint the reducer's completion gate uses.
> Result: **43 checks across 12 specs, 0 pass.** The failures are not what the
> audit guessed:
>
> | Cause | Checks | Share |
> |---|---|---|
> | `artifact stdout is not valid JSON: Extra data: line 2 column 1` | 42 | 42/43 |
> | `probe_return_marshalling_host.nim` exits 1 — `cannot open file: pkg/results` | 1 | 1/43 |
>
> **The dominant cause is an artifact-output contract mismatch, not the
> environment.** `nim` resolves fine (`/usr/local/bin/nim`, Nim 2.2.10), every
> probe compiles, and every probe exits 0. The oracle's `_parse_measurement` does
> `json.loads(stdout)` on the *whole* buffer, so an artifact must emit **exactly
> one** JSON document; muster's 43 probes emit **JSONL** — one observation per
> line. Reproduced directly:
>
> ```
> $ nim r -d:release tests/probes/probe_materialization_derivation_agrees.nim
> {"agrees": true}
> {"agrees": true}
> ...
> ```
>
> Two distinct contracts are being violated:
>
> - **`property_test` trace form** — the oracle wants a single
>   `{"traces": [[state, ...], ...]}` object, which it then hands to
>   `trace_monitor.py`. Our probes emit a bare stream of per-trial objects. The
>   probe's stream *is* one trace; it just isn't wrapped in the envelope.
> - **`model_check` stepper form** — the oracle invokes the stepper with a state
>   as the final argv and expects that state's *successors*. Our steppers ignore
>   the argv entirely and dump the whole reachable space as JSONL.
>
> So the probes are substantively right (they measure the real invariant and pass
> by hand) and mechanically wrong (they speak a different wire format than the
> grader). This is a **muster-side fix**, well-scoped and mechanical: re-emit to
> the oracle's envelope, and make the steppers actually step. Filed as **exo-dbc**.
>
> The one non-JSON failure is also **not** an oracle-env problem: it fails
> identically in a plain interactive shell (missing nimble `results` package —
> it needs the nix dev shell), so it is a probe-dependency gap, not a scrub.
> Filed as **exo-a7b**.
>
> Note this supersedes **exo-a5d**, which the audit cited as the standing
> hypothesis. exo-a5d was *closed as resolved on 2026-08-20* — it symlinked `nim`
> into `/usr/local/bin` and made the probe self-resolve secp256k1, and that fix
> is still in place and still working. The regate kept failing afterwards for the
> entirely different, never-diagnosed reason above. The audit inherited a stale
> hypothesis from a closed pebble.

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

> **VERDICT: REFUTED — this finding is an artifact of the audit's own
> environment, not a fact about the repo.** On the real checkout the full history
> is intact and pushed:
>
> - `git log --oneline HEAD | wc -l` → **271 commits**, oldest
>   `6febea9 2026-08-04 Initial project scaffold`. The P0–P2/P4 work has ordinary
>   per-commit history.
> - `aabcb69` is **not a root commit** — it has parent `6320dbf`. There are ~16
>   such `reroute: capture staged work off main` commits, each with parents.
> - All three cited SHAs resolve: `38e3a3b` = *"module: host-client
>   return-marshalling probe (derived-exo-526)"*, `2723d24` = exo-2dc handoff,
>   `8c40c7f` = exo-3a1 worker capture. **All 8** `gate-verdict:` SHAs in
>   `.pebbles/reducer_ledger.jsonl` resolve to real 2026-08-19 commits.
> - `git merge-base --is-ancestor 38e3a3b origin/main` → **true**. The objects are
>   on the remote; nothing needs recovering or bundling.
>
> The audit ran in a container with a **shallow clone**, whose boundary commit
> always presents as a parentless commit containing the entire tree — exactly the
> "single `reroute:` root commit" it described. **The audit chain is unbroken.**
> No action needed; the "record the mapping before `git gc`" advice is moot.

### G5 — The machinery exempts itself from the discipline it enforces

All 36 `bus`/`reroute`/`integrate` commits lack the `Tested-Behavior:` /
`TDD-Exempt:` trailer that `tdd-trailer.sh` rejects commits for, and lack the
`Session-Id` trailer. All 22 session commits since 08-27 comply. If machinery
commits are exempt by design, the exemption should be stated somewhere; today it
reads as two-tier enforcement.

> **VERDICT: CONFIRMED, and the exemption is by design but undocumented.**
> `exophiald`'s own integration commits run with `EXOPHIALD_INTEGRATOR=1`, the
> marker `reroute_main_commit.is_integrator()` and `block_worktree_leak` both
> honor. That covers the reroute guard; nothing in the vendored hook set exempts
> machinery commits from `tdd-trailer.sh`, which is a grep over the message. So
> the two-tier read is accurate for the trailer hooks specifically.

### G6 — The trailers are not git trailers

Session commits write `Tested-Behavior:` followed by a blank line, then
`Co-Authored-By`, another blank line, then `Session-Id`. Git's trailer parser
recognizes only the final contiguous block: `git log --format='%(trailers:key=Tested-Behavior)'`
finds **0** of 58 commits. The grep-based hook accepts them, but any downstream
tool using real trailer parsing (`git interpret-trailers`, `%(trailers)`) sees
nothing. Fix: write all trailers as one contiguous block at the end of the message.

> **VERDICT: CONFIRMED.** Re-checked on the full 271-commit history; the trailer
> block is still split by blank lines and git's own parser still sees none.
> Filed as **exo-4ed**.

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

> **VERDICT: CONFIRMED — no per-repo opt-out exists at `0.2.0+dc69cd1d`.** The
> mechanism is now documented in the tool itself (`ansible/init.yml` steps 5b/6):
> `reconcile_claude_settings.py` reconciles the exophial-owned hook block **to the
> canonical manifest**, and `reconcile_pre_commit_config.py` reconciles
> `.pre-commit-config.yaml` to include the guard hooks. Neither reconciler exposes
> a skip/exempt/opt-out flag (`--settings`, `--manifest`, `--check` only), and no
> `opt_out` / `skip_hooks` / `hooks_enabled` knob exists anywhere in the package.
> So the labbook's prediction is exactly right and re-running `init` will restore
> the hooks again. The upstream ask stands. Filed as **exo-aa7**.
>
> One useful nuance: doctrine files install **create-if-absent** per file
> (`init.yml` step 5b), so muster-local doctrine edits (G9) are *not* clobbered by
> a later `init`. Editing doctrine is safe; removing hooks is not.

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

> **VERDICT: REFINED.** The portability half is confirmed: the hooks are
> `language: system` shelling out to `exophial-*`, so they do not travel. But the
> *observable consequence* the audit cited has a different explanation here — on
> this machine the enforcement is fully live:
>
> - all five `exophial-*` entrypoints are on PATH; `pre-commit` is installed and
>   `.git/hooks/{pre-commit,commit-msg,pre-push}` are framework-generated;
> - `pre-commit run reroute-main-commit` executes and **passes** (correctly a
>   no-op off `main`);
> - `should_reroute("main", integrator=False)` → `True`, and
>   `EXOPHIALD_INTEGRATOR` is unset in an ordinary session.
>
> So the guard *would* have refused a direct commit on `main`. `git reflog main`
> shows how the tip actually moved:
>
> - **08-25/26** — `reset: moving to integrated` then `merge integrated:
>   Fast-forward` (exophiald's integrator route).
> - **08-27 → 09-01** — `merge <sha>: Fast-forward` from feature branches. The
>   reroute hook correctly does not fire on a non-protected branch, and a
>   fast-forward runs no `pre-commit` stage. This is a legitimate route *around*
>   the guard, not a bypass of it: the guard only ever protected direct commits.
> - **09-01 → 09-02** — the last five entries are literal `commit:` **on main**
>   (`dbd5589`, `6db79b2`, `28d7f64`, `e49d557`, `2e69c77`). Those the hook should
>   have refused, so they were made with `--no-verify` or `SKIP=`.
>
> Corrected reading: enforcement does not travel to other machines (true, and
> `coordination_repo` being an absolute path makes that concrete), **and** on the
> machine that has it, it is routinely stepped around — by fast-forward for most
> of the window, by `--no-verify` for the last five commits. The gap is a policy
> gap, not only a distribution gap.

### G9 — Doctrine is the unedited generic seed

`principal.md` says "edit it freely once installed to match the actual
principal's stated preferences." Nothing in `.claude/doctrine/` mentions muster,
Nim, or chronos; the per-language files are `testing-python.md` and
`testing-typescript.md` for a Nim repo. The repo's real conventions live in
CLAUDE.md. A dispatched worker seeded with this doctrine gets generic guidance
plus no `testing-nim.md`.

> **VERDICT: CONFIRMED.** Still the generic seed, and the same Nim blindness
> shows up structurally elsewhere (see G10's `SOURCE_SUFFIXES`). Because
> `init.yml` installs doctrine **create-if-absent**, editing these files in place
> is durable across a future `exophial init`. Filed as **exo-c5d**.

### G10 — Smaller drift

- **claude-md-coverage vs. reality:** the hook requires new source directories
  to carry a CLAUDE.md; all eleven `module/src/*/` directories lack one. Either
  the hook's "new directory" semantics never matched these, or it never ran.
  **[verify on the exophial machine]**.

  > **VERDICT: REFINED — neither. The hook cannot see Nim at all.**
  > `check_claude_md_coverage.py` defines
  > `SOURCE_SUFFIXES = {.py, .ts, .tsx, .js, .jsx, .swift, .go, .rs, .sh}`.
  > `.nim` is absent, so no `module/src/*/` directory is a "source directory" to
  > this gate and it correctly passes. The hook ran; it had nothing to say.
  > Same root as G9: exophial's vendored conventions have no Nim. Rolled into
  > **exo-c5d**.
- **discuss-issue skill links:** `docs/decisions/…` and
  `tests/test_discuss_issue_spine.py` are exophial-repo paths; they resolve to
  nothing in muster. The muster-local note is pinned to observations of HEAD
  `ab26cdb` (08-08) and tracks HEAD — the `relation_class` set, the
  `proof_obligation` gate defect, and the missing CLI verbs may all have moved.
  **[verify on the exophial machine]**.

  > **VERDICT: CONFIRMED stale, and now partly resolved upstream.** At
  > `0.2.0+dc69cd1d`: the CLI has **no** `issue` verb and no `spec generate` —
  > the real verbs are `exophial specify <pebble_id>` (with `--refresh`), plus
  > `discuss` / `error` / `feature` / `review-relation`. The `relation_class` set
  > is now *derived* rather than restated
  > (`ops/derivation_schema._RELATION_CLASS = {"enum":
  > list(RUNNABLE_RELATION_CLASSES)}`, sourced from `spec_oracle._RELATIONS` =
  > `conservation`, `no_arbitrage`, `monotonicity`) — exactly the upstream fix for
  > the drift the note recorded (exo-a57). `exo-178` is an exophial-repo pebble,
  > not resolvable from muster's bus. The muster-local note should be re-pinned or
  > dropped. Rolled into **exo-c5d**.
- **settings.json `"if": "Bash(git commit:*)"`** on the `fix_worktree_index`
  hook — confirm current Claude Code honors a per-hook `if` key; if not, the
  hook runs on every Bash call. **[verify on the exophial machine]**.

  > **VERDICT: UNRESOLVED — left open deliberately.** Claude Code here is
  > **2.1.247**; the install ships no settings JSON schema to check the key
  > against, and the honest test is behavioral (observe whether
  > `fix_worktree_index` fires on a non-`git commit` Bash call), which this
  > evidence pass did not run. `"if"` is not a documented `hooks[]` key, so the
  > likely answer is that it is ignored and the hook runs on every Bash call —
  > but that is inference, not evidence. Rolled into **exo-aa7** as a question
  > for upstream.
- **worker_model:** the `default: "sonnet"` tier is unreachable (routing sends
  everything to `frontier`). Harmless; confusing.
  > **VERDICT: CONFIRMED**, and the config's own comment explains why: difficulty
  > banding from `V_spec` (ADR D1) "is not built yet, so every pebble routes
  > `default` today; the extra tiers/rows activate for free once specs commit a
  > `difficulty_class`." Intentional forward-compatibility. No action.
- **Backlog:** 80 open pebbles, including decomposition children and superseded
  items. Needs a triage pass.
  > **VERDICT: PARTLY ADDRESSED** — now **54 open**.

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

## Verification outcome (2026-09-02) — what actually stands

| # | Finding | Verdict |
|---|---|---|
| G1 | Spec pipeline covers 12 of 185 pebbles, none since 08-20 | **CONFIRMED** |
| G2 | Every exophiald merge was graded by nothing | **CONFIRMED** — `gate:` still commented out |
| G3 | Every spec regate failed; work landed anyway | **CONFIRMED** (0/43 checks pass at HEAD) — **root cause REFUTED**: an output-format mismatch, not the environment |
| G4 | History re-rooting broke every evidence link | **REFUTED** — artifact of a shallow clone; 271 commits and all cited SHAs are intact and pushed |
| G5 | Machinery exempts itself | **CONFIRMED** — by design for the reroute guard (`EXOPHIALD_INTEGRATOR`), undocumented for the trailer hooks |
| G6 | Trailers are not git trailers | **CONFIRMED** |
| G7 | Labbook's prediction came true | **CONFIRMED** — no per-repo opt-out exists at `0.2.0+dc69cd1d` |
| G8 | Enforcement exists on one machine | **REFINED** — true off-machine; on-machine it is live and was stepped around (fast-forward, then `--no-verify`) |
| G9 | Doctrine is the unedited generic seed | **CONFIRMED** — and safe to edit (create-if-absent) |
| G10 | Smaller drift | **REFINED** — `claude-md-coverage` has no `.nim` suffix; skill CLI verbs stale; `"if"` key unresolved; `worker_model` intentional; backlog now 54 |

### The corrected shape of the gap

The audit's conclusion was that muster has never had a working grading loop.
**That conclusion survives — 43 of 43 checks fail at HEAD — but the reason is
much better news than the audit thought.** The blocker is not a hostile hermetic
environment, a broken audit chain, or specs that were never really green. It is
that muster's 43 probes emit JSONL while the oracle reads a single JSON document.
The invariants are genuinely proven by these probes; only the envelope is wrong.

That reframes the posture choice. "Adopt dispatch for real" is no longer gated on
an environment fix nobody knows how to do — exo-a5d already did the environment
work in August, and it held. It is gated on a mechanical, bounded change to how
43 probes print their results (**exo-dbc**), plus one probe's missing nimble
dependency (**exo-a7b**), plus a `gate:` command for spec-less pebbles
(**exo-efc**). Those are ordinary work items, not research.

### Filed

| Pebble | What |
|---|---|
| **exo-dbc** | P1 — probes emit JSONL; oracle wants one JSON doc. Re-emit to the `{"traces": [...]}` envelope and make `model_check` steppers actually step. The single fix that makes the grading loop real. |
| **exo-a7b** | P2 — `probe_return_marshalling_host.nim` fails on missing nimble `results`; needs the nix dev shell or a vendored dep. |
| **exo-efc** | P2 — configure `gate:` in `.exophial/config.yaml` so a spec-less merge is graded by something (G2). |
| **exo-4ed** | P3 — write commit trailers as one contiguous block so git parses them (G6). |
| **exo-c5d** | P2 — muster-edit the doctrine seed, add `testing-nim.md`, re-pin the discuss-issue note (G9, G10). |
| **exo-aa7** | P3 — upstream asks: per-repo hook opt-out; `.nim` in `SOURCE_SUFFIXES`; does Claude Code honor a per-hook `"if"` key (G7, G10). |
