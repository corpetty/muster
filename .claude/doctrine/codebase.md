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
- **Keep it under a hard memory cap**, so that only the build dies if it runs
  over, not the session. `make build`, `make build-lgx` and `make appimage`
  apply the cap themselves when `BUILD_MEM` is set: their nix calls run in a
  `systemd-run --user --scope` capped at it. Each refuses to start if the cap
  can't be applied, and says so when the build is killed at the cap.
  `BUILD_MEM` is unset by default, so a stranger's fresh clone builds with no
  cap and no systemd dependency. A machine short of memory sets it once in its
  shell profile (`export BUILD_MEM=10G`), so every build there is capped; a
  machine with headroom leaves it unset. Unsetting it on a capped machine is a
  deliberate choice, never a workaround for a refused cap. A flake evaluated
  any other way (`nix build`/`nix run` by hand, `make run`) is not capped, so
  on a machine short of memory wrap it yourself:

  ```bash
  systemd-run --user --scope -p MemoryMax=10G -p MemorySwapMax=0 nice -n 19 <command>
  ```

  The scope holds the evaluating `nix` process. Size the cap to what the host
  can spare with everything else running. If the build dies at the cap, it
  needs a quieter host or a quieter hour, not a higher cap on a busy one.
- **Reuse an existing runner when the change touches nothing compiled into
  it.** That means no change under `module/src`, `module/nim-lib`,
  `module/metadata.json`, `ui/src`, or any `flake.nix`/`flake.lock`. A check
  that drives a runner (`scripts/audit-download-self-test.sh`, and so
  `scripts/grade-specs.sh exo-403`) can then run against an existing build:
  `ln -sfn "$(readlink -f <main checkout>/.run/runner)" .run/runner`, run
  under the same cap. Say in the PR which runner the check ran against, and
  remove the link afterwards so that no later session mistakes it for this
  branch's build.

## Load on `bugger` (muster)

This section is muster's own; it is not in exophial's seed. It holds until the
operator says `bugger`'s hardware is fixed. Then remove it, don't loosen it.

`bugger`'s memory hardware is failing, and heavy parallel compiling brings the
fault out. On 2026-11-23 the host hard-reset twice, at 19:52 and 20:42 UTC.
Both times one session had several subagents running `module/tests/run-suite.sh`
at once, one of them at `JOBS=24`. Each reset came after a burst of
*uncorrected* memory errors: `Uncorrected hardware memory error`, `Poison`, and
the kernel sending SIGBUS to `cc1`, `nim` and `gcc`. The errors hit many cores
and physical addresses. On restart the firmware reported one error record saved
from before the reset (`BERT: … Skipped 1 error records`). Under them runs a
storm of corrected errors on `mc0` (rows 2 and 3, six channels, about 9,000 so
far; `~/gpu-diag/README.md`). The uncorrected errors began in the boot of
2026-11-04. The cause is the hardware, not muster's code, and a session cannot
fix it. A session can avoid being what sets it off, and can avoid losing work
when that happens.

`BUILD_MEM` above is about how much memory the host has. This section is
about whether that memory works, so it applies even where builds run uncapped.

- **One heavy job on the host at a time, across every session.** A heavy job is
  a `run-suite.sh` run (any group), a runner build (`make build`, `build-lgx`,
  `appimage`, `build-nim`), or any flake evaluation. Before starting one, check
  that no other session is running one:
  `pgrep -af 'run-suite\.sh|nix (build|run|eval|develop)'`.
  If one is running, wait for it or ask the operator. Don't add a second.
- **Never fan out subagents that each run the suite or a build.** Subagents may
  edit and read in parallel, but their test runs go one at a time, either
  through the coordinator or one after another. The resets came from exactly
  this fan-out.
- **Leave `JOBS` at the suite's default (8) or lower.** Don't raise it to speed
  up a run. Single default-`JOBS` runs went through 2026-11-04 to 2026-11-20
  without a reset, but that shows the risk is lower, not that it is safe.
- **Commit or stash before a heavy job.** A reset loses whatever is uncommitted
  in the working tree and the session.
- **Watch the counter.** Before and after a heavy job, run
  `journalctl -k -b | grep -c 'Uncorrected hardware memory error'`. If it rose,
  stop starting heavy jobs and tell the operator the count and the time. Treat
  that run's results as suspect: a SIGBUS-killed `cc1` can look like a failing
  test, and poisoned data that wasn't caught can corrupt a result silently.
  Rerun before believing a red or a green.
- **A crash after a reset is not a bug in the code.** When a session resumes
  after a reset, check `journalctl --list-boots` and the previous boot's tail
  (`journalctl -b -1 -n 40`) before debugging a mysterious failure.

## Side repos (muster)

This section is muster's own; it is not in exophial's seed.

Muster work sometimes needs a repo that exophiald does not integrate: no daemon
merges into its `main`, and no pebble's worker owns its branches. The integrator
guard (`exophial hook block_worktree_leak`, wired in this repo's
`.claude/settings.json`) still checks every Bash command a muster session runs,
including one that `cd`s into such a repo, so without this rule nothing could
ever advance that repo's `main`.

- **In a listed side repo, mark the one command.** The guarded git operations
  (push or merge to `main`, creating or moving a branch) may carry the
  integrator marker inline on that command alone, after the `cd` into the side
  repo:

  ```bash
  cd /home/petty/logos-signer-module && EXOPHIALD_INTEGRATOR=1 git push -u origin main
  ```

  Run the marked git command as the only git command of its call: a marker on a
  later command after an unmarked `git log` or `git diff` on the same line is
  not honoured. Never in muster or any of its worktrees, never exported into the
  environment, and never for a repo the table below does not list.
- **The list is the operator's.** A repo joins it only when the operator says
  so, recorded here with the date and what the repo holds. A fork carrying a
  feature branch for upstream (`corpetty/logos-*`) is not a side repo: its
  branches push without the marker, and its `main` is upstream's.

| Repo | Local checkout | Holds | Listed |
|---|---|---|---|
| `corpetty/logos-signer-module` | `/home/petty/logos-signer-module` | specs and pebbles for the platform signer work (epic exo-833) | 2026-10-25, by the operator |

**The guard defect behind this**, until it is fixed in exophial: installed as
`exophial hook block_worktree_leak`, the hook takes its topology (the main
checkout, the linked worktrees, the configured remotes) from its own install
location, the uv tool's `lib/python3.x` directory, which is not a git repository.
So it sees no remotes and no worktrees: the publish carve-out (exo-896.3, a
plain `git push <remote> main` to a configured remote) can never apply, and no
branch write is ever recognized as the caller's own branch (exo-439). Checked
2026-10-25 against exophial `0.2.0+dc69cd1d`: `git push origin main` is denied
both from a side repo and from muster's own checkout.
