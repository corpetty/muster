# Engineering practices: testing

General engineering-practice context behind this repo's testing doctrine.
Referenced from
[`../.claude/doctrine/testing.md`](../.claude/doctrine/testing.md).

## Shape of the test suite

Most tests should be fast unit tests; a smaller number of integration tests
should prove real modules compose; a small, deliberately-curated set of
end-to-end tests should prove the whole system works from the outside. If the
mix inverts — many slow e2e tests and few fast unit tests, or the reverse,
zero integration coverage between a large unit suite and a thin e2e layer —
that is a structural smell worth fixing, not a tooling problem.

## Coverage is a signal, not a target

A high coverage percentage achieved by asserting nothing meaningful (calling
a function and checking it didn't raise) is worse than no test: it reads as
safety net while providing none. Prefer fewer tests that assert real,
specific behavior over many tests that only execute lines.

## Non-determinism is a design smell

A test whose verdict varies on an unchanged tree — its result depends on some
hidden input H beyond the code under test (verdict = f(A, H), not f(A)) — is
not a CI infrastructure problem to work around with retries. It usually means:
a hidden dependency on wall-clock time, an unawaited async operation, shared
mutable state between tests, or a race the production code also has. Fix the
underlying cause; a retried-until-green test hides a real bug from everyone
who reads the green checkmark afterward.

## Regression tests carry provenance

When a test exists specifically because of a past bug, name the bug or the
fixing commit in the test name or docstring. A regression test without that
context is indistinguishable from a test someone will "simplify" away later.
