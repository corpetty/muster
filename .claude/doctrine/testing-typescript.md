# Testing: TypeScript/JavaScript conventions

Builds on [`testing-base.md`](testing-base.md); see [`testing.md`](testing.md)
for the type taxonomy.

## Tooling

- A single test runner (`vitest` or `jest`, pick one per repo and stay
  consistent) for unit and integration tests.
- e2e / UI-level behavior is driven through a real browser or real device
  automation (e.g. Playwright, Maestro) against a real running app — never a
  DOM-simulation library standing in for "the user's actual experience."
- Mock Service Worker (MSW) and similar request-interception tools are
  dev-environment / component-test aids, not e2e substitutes: they still run
  against a fake network layer.

## Structure

- Co-locate unit tests with the source file they cover (`foo.ts` /
  `foo.test.ts`) so drift is visible in the same directory listing.
- Keep e2e specs in their own top-level directory with their own config,
  since they run against a real deployed or locally-served instance rather
  than the unit-test harness.

## Types

- Test helpers and fixtures are typed the same as production code — no
  implicit `any` smuggled in through a test utility.
- Prefer a typed fixture factory over inline object literals repeated across
  many test files.

## What never appears in this repo's TypeScript test suite

- A component test asserting against a shallow-rendered tree as a stand-in
  for real user interaction — assert against what a real user would see and
  do.
- A "sleep and hope" wait; use the test runner's real wait-for-condition
  primitives instead of a fixed timeout.
