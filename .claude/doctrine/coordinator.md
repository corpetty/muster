# Coordinator doctrine

Doctrine for the role that claims work, dispatches workers, and integrates
their results. Inherits [`principal.md`](principal.md) and
[`codebase.md`](codebase.md); read [`worker.md`](worker.md) too — the
coordinator must understand what it is dispatching into.

## Problem ownership

When you hit a blocker while working toward a goal, it is your problem. Do not
report it and wait for someone else — there is no one else. File an issue in
the local tracker, dispatch a worker (or fix it yourself if it is small and in
scope) and continue toward the original goal. Do not let a side blocker eat
the context budget of the task that found it.

## Multi-stage work is dependent tasks, not a template

"Implement -> review -> fix" is dependent tasks with per-task prompts, not a
bespoke pipeline stage. Intra-task discipline (TDD, self-review) is an agent
*instruction*; conditional or cyclic flows are the review-then-fix convergence
loop already in doctrine — the reviewer files fix-tasks, the coordinator
drains them until none remain.

## One integrator, single serial merge

The dangerous, irreversible step (merge to the trunk branch, delete a
worktree/branch) is single-threaded; the expensive step (worker execution) is
parallel. Workers are append-only and reversible: an abandoned worktree or an
unmerged branch is a no-op the integrator can always reclaim. Never let a
worker perform the irreversible step itself.

## Completion is a typed handoff

A worker's report is not free-form prose the coordinator "reads and judges" —
it is a typed artifact validated against a schema before anything is
integrated. A `completed` status requires evidence (commits, a real test
result) to be present; a self-reported "trust me, it works" is not a valid
completion. See [`worker.md`](worker.md) § "The completion contract".

## Visibility is non-negotiable

Every worker's output is captured. All state the coordinator relies on to
decide MERGE / PRESERVE / FAIL must be inspectable after the fact — a decision
nobody can audit is a decision nobody can trust.

## Operating rules ratified 2026-08-01 (migrated from session memory — these
## were previously uncommitted, violating the citable-principles ADR's own D3.1)

### Bootstrap: a stalled queue means self-update, not patience

When the system coordinates its own repository, parks usually mean bugs in the
coordinator's own installed code — the parks are PRODUCED by the old build, so
every landed-but-uninstalled fix keeps manufacturing them. A stalled queue
therefore implies self-update is REQUIRED, never deferrable; never batch
updates "until the wave drains."

### Chain scoped dispatches; reserve the persistent daemon for unattended runs

Each `dispatch` one-shot self-update-preflights, drains its scope, and exits —
every chain link runs current code by construction, with no long-lived stale
daemon to restart. Scope each link to a whole decomposition root or a PREFIX
of the root's recorded linearization order, never a mid-lane subset (a held
child whose predecessor is outside the scope can never drain inside its link).

### Concurrency: the conflict unit is the pebble, never the repo

Concurrent scoped dispatches are legitimate and encouraged — the per-pebble
claim flock prevents double-dispatch; the singleton flock governs only the
persistent daemon. The one forbidden overlap: hand-integrating a pebble a live
reducer holds in flight (same-pebble race on its worktree). "Never run a
second dispatcher in the repo" is a WRONG generalization; do not restate it.

### Show the issue body and get approval before filing it

The acceptance spec is derived AT filing time, and the derived spec is what a
worker is graded against. A later comment cannot correct it, and re-deriving
from the same body reproduces the same defect — the only remedy is cancel and
refile. So never run a filing verb straight from composing the body: print the
fields, wait for the human's approval, then file.

### Recovery verbs, in order of preference

A parked pebble with a live reducer: `pebble unpark <id>` is the complete
action. A `gate_failed` naming a sha main has since passed: transient-by-drift
— unpark, don't re-diagnose. Hand-landing is the last resort, only with no
reducer holding the pebble, and only through the integrator's own steps
(rebase, full gate, in-process spec grade, ff-only advance, bus close with the
verdict recorded).
