# Testing doctrine

The canonical test-type taxonomy for this repo. Read this before writing or
reviewing any test — the unit / integration / e2e conflation is exactly the
failure this doc exists to prevent. Inherits
[`principal.md`](principal.md) and [`codebase.md`](codebase.md).

## The three test types, precisely

- **Unit** — exercises one function or class in isolation. Fast, numerous,
  the inner loop of TDD. Mocks are acceptable here because the unit under
  test *is* the boundary.
- **Integration** — exercises two or more real modules/components together,
  with real objects (no mocked internals). Proves the pieces compose.
- **End-to-end (e2e)** — exercises the real, user-facing surface: a real
  process, a real service, real IO, through the actual interface a user or
  caller uses. No mocks anywhere in the path. This is the acceptance gate —
  see [`../../docs/exophial-testing.md`](../../docs/exophial-testing.md).

A test that mocks an internal function is not an integration test wearing a
disguise — it is a unit test, and should be named and treated as one.

## Which type a change needs

- A pure refactor needs unit tests around the invariant it preserves, not a
  new e2e path.
- A new user-visible behavior needs an e2e test proving it, with unit tests
  pulled in only for the specific logic the e2e failure isolates.
- "I should add coverage" is never a reason to write a test — a failing
  behavior, or a real invariant worth pinning, is.

## What makes a test valid

A test that always passes proves nothing. See
[`../../docs/test-validity.md`](../../docs/test-validity.md) for the full
discussion of self-grading tests, vacuous assertions, and how to tell a test
that discriminates real behavior from one that only looks like it does.

## Verification is decidable, not vibes

Whether an artifact satisfies a criterion reduces to something you can check
mechanically — static structure or observed runtime behavior — not a semantic
judgment call made once and trusted forever. See
[`../../docs/labbook/verification-is-ast-decidable-or-observational-not-semantic.md`](../../docs/labbook/verification-is-ast-decidable-or-observational-not-semantic.md).

## Broader engineering practice

For the surrounding engineering-practice context (coverage philosophy, test
pyramid shape, when a non-deterministic test is a design smell rather than a CI problem),
see
[`../../docs/engineering-practices-testing.md`](../../docs/engineering-practices-testing.md).

## Per-surface conventions

- [`testing-base.md`](testing-base.md) — language-agnostic conventions every
  surface follows.
- [`testing-python.md`](testing-python.md) — Python-specific conventions.
- [`testing-typescript.md`](testing-typescript.md) — TypeScript/JavaScript
  conventions.
