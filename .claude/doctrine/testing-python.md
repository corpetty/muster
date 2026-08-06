# Testing: Python conventions

Builds on [`testing-base.md`](testing-base.md); see [`testing.md`](testing.md)
for the type taxonomy.

## Tooling

- `pytest` for unit, integration, and e2e alike — the type is a property of
  what the test exercises, not which runner invokes it.
- Real fixtures via `pytest` fixtures (`tmp_path`, a real subprocess, a real
  temp git repo), not `unittest.mock.patch` on internal collaborators. Mock
  only at genuine system boundaries (network egress, signal handlers,
  external processes not under test).
- Parametrize (`@pytest.mark.parametrize`) instead of copy-pasting near
  identical test bodies for different inputs.

## Structure

- Mirror the source layout under `tests/` so a reader can find a module's
  tests without grepping.
- Keep e2e tests physically separate (e.g. `tests/e2e/`) from unit/
  integration tests, since they typically have a different runtime cost and
  different real-world dependencies (a running service, a real network call).

## Type hints and assertions

- Type-hint test helpers the same as production code — a fixture with an
  untyped return value is a landmine for the next test that uses it.
- Prefer explicit `assert` with a clear left/right comparison over a helper
  that swallows the actual vs. expected values on failure.

## What never appears in this repo's Python test suite

- A test that imports and calls the function it is also responsible for
  grading (self-grading tests) — the judgment belongs to the assertion, not
  to code the same author wrote alongside it.
- A test disabled with a bare `@pytest.mark.skip` and no reason string.
