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

## Runner builds (muster)

This section is muster's own; it is not in exophial's seed.

`make build`, the standalone runner, is the heaviest command in this repo, and
its memory goes to flake **evaluation**, not compilation. On 2026-10-05 the
`nix` client alone reached 7.4 GB RSS while evaluating, before any derivation
built. With other sessions' processes already resident, the kernel OOM-killed
the operator's desktop apps, and the operator was logged out mid-meeting. This
happened twice. `--max-jobs`/`--cores` did not help: they limit only the build
phase, and builds run under nix-daemon, which a client-side `nice` never
reaches.

- **Ask before starting one.** The timing of a runner build on the operator's
  workstation is the operator's call. Never start one unannounced in the
  background.
- **Run it under a hard memory cap**, so that only the build dies if it runs
  over, not the session:

  ```bash
  systemd-run --user --scope -p MemoryMax=10G -p MemorySwapMax=0 nice -n 19 make build
  ```

  The scope holds the evaluating `nix` process. Size `MemoryMax` to what the
  host can spare with everything else running. If the build dies at the cap,
  it needs a quieter host or a quieter hour, not a higher cap on a busy one.
- **Reuse an existing runner when the change touches nothing compiled into
  it.** That means no change under `module/src`, `module/nim-lib`,
  `module/metadata.json`, `ui/src`, or any `flake.nix`/`flake.lock`. A check
  that drives a runner (`scripts/audit-download-self-test.sh`, and so
  `scripts/grade-specs.sh exo-403`) can then run against an existing build:
  `ln -sfn "$(readlink -f <main checkout>/.run/runner)" .run/runner`, run
  under the same cap. Say in the PR which runner the check ran against, and
  remove the link afterwards so that no later session mistakes it for this
  branch's build.
