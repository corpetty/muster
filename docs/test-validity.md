# What makes a test valid

A test is only evidence if it can fail. Referenced from
[`../.claude/doctrine/testing.md`](../.claude/doctrine/testing.md).

## Demonstrate discrimination, don't assume it

A test earns trust by having been observed to fail against a version of the
code that violates the behavior it claims to prove — red before green, or a
deliberately broken variant that the test catches. A test that has never been
seen to fail is not proven to test anything; it may simply be a no-op wearing
an assertion.

## Self-grading is not verification

A test (or a check) that is written, and can be edited, by the same author
and same change that produced the code under test is not independent
evidence. Prefer an acceptance criterion that is fixed before the
implementation begins, or owned/graded by something outside the change being
graded.

## Vacuous assertions

Watch for the assertion that can never be false given how the test is
constructed — asserting a mock returned what you told it to return, asserting
a function "did not raise" with no check on its actual output, or asserting a
value against itself after a no-op round-trip. These pass forever regardless
of the code's correctness.

## Structural checks are not behavioral proof

Grepping for a string, a flag, or an import is a legitimate check only when
the presence of that literal text *is* the acceptance criterion (e.g. "this
doc must cite its source"). It is not legitimate as a stand-in for "the
feature actually works" — that requires observing real behavior, not text.

See
[`../.claude/doctrine/testing.md`](../.claude/doctrine/testing.md) for how
this maps onto the unit/integration/e2e taxonomy, and
[`labbook/verification-is-ast-decidable-or-observational-not-semantic.md`](labbook/verification-is-ast-decidable-or-observational-not-semantic.md)
for why this reduces to two mechanical checks rather than an open-ended
judgment call.
