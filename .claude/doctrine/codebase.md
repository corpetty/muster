# Codebase doctrine

Load-bearing project rules every agent operating in this repo must respect.
Both the coordinator and every worker inherit this. This is a generic seed
installed by `exophial init`; once installed it is free to drift from
exophial's own copy to match this repo's actual conventions.

## Behavioral norms (inherited from principal)

Full doctrine: [`principal.md`](principal.md). Load-bearing summary:

- Evidence-based reasoning: run before you read, when diagnosing.
- Fail fast, no fallbacks: no retry loops, no silent catch-all.
- Done = integrated + end-to-end verified, against the real surface.
- Own your consequences: grep for orphans before declaring a change done.

## Literate code principle

An agent should be able to derive all the state needed to safely modify a file
from three sources:

1. **Directory structure** — the layout tells you what exists and how it's
   organized.
2. **Imports within the file** — these declare the file's dependencies
   explicitly.
3. **Comments within the file** — these link to prose design docs that explain
   the *why*, not the *what* (well-named identifiers already say the what).

If a file is changed, any documentation that references it is potentially
stale and must be checked — documentation and code are a bidirectional graph.

## Functional core, imperative shell

Pure functions compute; IO (network, filesystem, subprocess, print) happens
only at the boundary. A function that does both is wrong — decompose it
before writing it. Small functions: if one is long, it does too much.

## DRY / KISS

Minimize duplication and complexity. Don't add abstractions beyond what the
task requires — three similar lines beat a premature abstraction. Don't design
for hypothetical future requirements.

## Own your consequences

If you move code, verify nothing still imports the old location. If you delete
a caller, delete the callee. The person making a change is responsible for
everything that change breaks — not just its immediate correctness, but its
ongoing cost.

## Testing

Testing conventions (unit vs. integration vs. e2e, and per-surface detail) are
owned by [`testing.md`](testing.md) — read it before writing or reviewing any
test in this repo. Do not restate the taxonomy here; that duplication is
exactly how conflicting definitions drift apart.

## Roles

- [`coordinator.md`](coordinator.md) — the role dispatching and integrating
  work across workers.
- [`worker.md`](worker.md) — the role executing one task in an isolated
  worktree.
