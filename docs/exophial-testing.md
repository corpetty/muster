# Exophial-driven worker testing conventions

How agents dispatched by exophial (or any similar per-task worker harness)
should test their own work in this repo. Referenced from
[`../.claude/doctrine/testing.md`](../.claude/doctrine/testing.md) and
[`../.claude/doctrine/worker.md`](../.claude/doctrine/worker.md).

## The outer loop is the acceptance test

A worker's task is graded against a real, observable acceptance criterion —
not against the worker's own account of what it did. Write the acceptance
test (or identify the existing one) before writing implementation code, and
make it fail for the right reason before making it pass.

## Real fixtures, real processes

Every test a worker adds above the pure-unit level must exercise a real
instance of the thing it is testing — a real subprocess, a real temporary git
repository, a real local server — never a mocked stand-in for a collaborator
that lives in this same codebase. Mocking is reserved for genuine external
boundaries (a third-party network call, a signal handler, a paid API).

## Verification before completion

Before a worker reports a task complete, it must have:

- Run the test(s) it added or relies on, and observed them pass for real.
- Run the repo's linter/type-checker/pre-commit gate and observed it pass.
- Captured the actual command and actual output as evidence, not a
  paraphrase.

A worker that reports success without having run these checks is producing a
claim, not a verification.
