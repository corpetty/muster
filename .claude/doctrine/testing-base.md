# Testing: base conventions (all surfaces)

Language-agnostic conventions that every per-surface doc
([`testing-python.md`](testing-python.md),
[`testing-typescript.md`](testing-typescript.md)) builds on. See
[`testing.md`](testing.md) for the type taxonomy this assumes.

## Fixtures over mocks

Prefer a real, shared fixture (a real temp git repo, a real local database, a
real subprocess) to a mock, at every level above a pure-unit test. A fixture
is slower to set up once and then reusable everywhere; a mock is fast but
proves nothing about the real integration.

## One assertion, one reason to fail

Each test should have a clear, singular reason to fail. A test with five
unrelated assertions makes debugging a regression slower, not faster — you
learn "something broke" instead of what.

## Naming carries intent

Name a test after the behavior it proves (`test_stale_worktree_is_reclaimed`),
not after the function it calls (`test_cleanup`). The name should make sense
to someone who has never read the implementation.

## Determinism

A test that passes 9 times out of 10 is not a test with a coverage gap — it
is a bug, either in the code or in the test's assumption about timing/ordering.
Fix the root cause; do not retry the test into passing.

## Setup/teardown discipline

A test must leave the environment as clean as it found it, whether it passes
or fails. Prefer fixtures with automatic teardown over manual cleanup blocks
a raised exception can skip.
