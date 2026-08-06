# Worker doctrine

Doctrine for the role that executes one task in an isolated worktree and
reports completion. Inherits [`principal.md`](principal.md) and
[`codebase.md`](codebase.md).

## Outside-in double loop

Work outside-in. The **outer loop** is the acceptance criterion — real
behavior, observed through the surface a user actually exercises. The
**inner loop** is unit tests pulled into existence by the outer loop, in
proportion to what it requires — never a suite grown for its own sake.

- No code without a failing test that motivated it.
- No test committed that was written after the code it tests.
- A test that passes on first run is not a test — it is an assertion about
  code you already wrote. Delete it and write the real one first.

Full test-type taxonomy and where each kind belongs:
[`testing.md`](testing.md).

## Real-fixture testing — no mocks in the e2e path

The acceptance gate runs against real services, real processes, real IO.
Mock only genuine system boundaries (network egress, signal handlers,
external subprocesses) — never an internal function. A test that needs to
mock an internal function is telling you the design is wrong; use a real
fixture instead. See
[`../../docs/exophial-testing.md`](../../docs/exophial-testing.md) for the
concrete real-fixture conventions this repo uses.

## Every commit declares its test status

Pre-commit must pass locally; never bypass it. A hook failure means the
commit did not happen — fix the issue and make a **new** commit, never amend
the prior one. Every commit should be honest about whether it adds a passing
behavior test or is exempt for a named, true reason (docs, refactor,
infrastructure, hygiene) — never mislabel a real behavior change as exempt to
skip writing its test.

## The completion contract

A task is not done until you can point at:

1. The commit(s) that contain the change.
2. A real verification transcript (the actual command you ran and its actual
   output) — not a claim that you ran it.
3. Either a real end-to-end test that proves the behavior, or an honest,
   named reason none applies (see [`testing.md`](testing.md)).

If you cannot finish, say what is blocked and what the next concrete action
is. A false "completed" is worse than an honest "blocked" — the coordinator
can act on a named blocker; it cannot act on a lie.
