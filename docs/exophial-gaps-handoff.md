# Handoff: verify the exophial gap findings on a machine with exophial installed

> **EXECUTED 2026-09-02.** This handoff has been run on the exophial machine.
> Preflight was green and checks 1–5 are answered; results are recorded inline in
> [`exophial-usage-gaps.md`](exophial-usage-gaps.md) as per-finding verdicts plus
> a "Verification outcome" section. Headline: **G4 is refuted** (the audit ran on
> a shallow clone; history is intact), and **G3's root cause is refuted** (the
> regate fails on an output-format mismatch, not the environment — exo-a5d's
> environment fix held). Six pebbles filed: **exo-dbc** (the load-bearing one),
> exo-a7b, exo-efc, exo-4ed, exo-c5d, exo-aa7. Check 6 — the posture decision —
> is the operator's and remains open. Checks below are kept for provenance.

Run this in a **local Claude Code session started from
`/home/petty/Github/corpetty/muster`** — the workstation that has exophial
installed (`~/.local/share/uv/tools/exophial`), the kept worker worktrees, and
the original reflog. It cannot run in a Claude Code on the web / remote session:
those get a fresh clone of the pushed repo in a container with no exophial, no
`.worktrees/`, and no pre-08-25 objects. Switching the model in a remote session
does not change the machine.

The findings this verifies are in [`exophial-usage-gaps.md`](exophial-usage-gaps.md)
— read that first. Everything below is a check the repo-only audit (2026-09-01)
could not complete for exactly that reason.

## Prompt for the session

### 0. Preflight — prove you are on the right machine before anything else

Run this first and read the output. If any line says MISSING, **stop** and report
that the session is on the wrong machine. Do not substitute, simulate, or reason
around a missing tool — every check below depends on the real install.

```bash
command -v exophial pb || echo "MISSING: exophial/pb not on PATH"
ls -d ~/.local/share/uv/tools/exophial || echo "MISSING: exophial tool venv"
ls -d /home/petty/Github/corpetty/muster/.worktrees || echo "MISSING: kept worktrees"
git -C /home/petty/Github/corpetty/muster cat-file -t 38e3a3b1887c0ad74cfb930a285bf31f7f04ce52 \
  || echo "MISSING: pre-08-25 objects (check 3 is already answered: unrecoverable here)"
```

With preflight green, work through the numbered checks. For each: run the
command, record the actual output, and update `docs/exophial-usage-gaps.md` —
confirm the finding, refute it, or refine it. Do not fix anything yet unless a
check says so; this pass is evidence collection.

### 1. Pin the tool version the findings were made against

```bash
exophial --version 2>/dev/null || ~/.local/share/uv/tools/exophial/bin/python -c "import exophial; print(exophial.__version__, exophial.__file__)"
git -C <exophial checkout> log -1 --format='%h %ad %s' --date=short   # if installed from a checkout
```

Record the version/SHA. The vendored `discuss-issue` SKILL.md note observes HEAD
`ab26cdb` (2026-08-08). List what moved since that matters to the note:
`exophial issue ingest` / `exophial spec generate` as CLI verbs (do they exist
now?), the accepted `relation_class` set, the `proof_obligation` gate defect
(exo-178), and whether `reconcile_claude_settings` gained a per-repo opt-out
(finding G7).

### 2. Root-cause the failed spec regates (G3 — highest value)

The reducer ledger records `gate-verdict: <sha> failed` for exo-2dc, 307, 51e,
525, 8dc, 8e7, f60, 3a1. In the original checkout:

```bash
ls /home/petty/Github/corpetty/muster/.worktrees/           # which worker-exo-* survive?
```

Pick one surviving worktree (exo-526 or exo-3a1 preferred) and re-run its spec
oracle the way exophiald does (`spec_oracle.run_spec`, or the regate entry point
the current build exposes), capturing full output. Answer precisely:

- Did it fail because the scrubbed PATH/env cannot reach `nim`/nix/secp256k1
  (the exo-a5d hypothesis recorded in `probe_return_marshalling_host.nim`)?
- Or did an oracle genuinely fail at the worker's head?

If environmental: state what the regate env needs (a pinned toolchain path, a
nix develop wrapper, an env allowlist) and file it as a pebble — this is the
single fix that makes the grading loop real.

### 3. Recover the unresolvable SHAs (G4)

These SHAs are cited by the audit trail but do not exist in the pushed repo:

- `38e3a3b1887c0ad74cfb930a285bf31f7f04ce52` (exo-526 handoff commit)
- `2723d24d4bc7de3aa9b4493653dea669c8ecc7e6` (exo-2dc gate-verdict)
- `8c40c7ffef9881ed99d2fea5cb8911e888b306fe` (exo-3a1 gate-verdict)
- plus the gate-verdict SHAs for exo-307, 51e, 525, 8dc, 8e7, f60 in
  `.pebbles/reducer_ledger.jsonl`

```bash
cd /home/petty/Github/corpetty/muster
for s in 38e3a3b 2723d24 8c40c7f; do git cat-file -t $s 2>&1; done
git worktree list; git reflog --date=short | head -50
```

If they resolve locally: push the objects somewhere durable (a `refs/audit/*`
namespace, or a bundle committed under `docs/labbook/`), or record a
SHA→description mapping in the labbook before any `git gc` / worktree cleanup
destroys them. If they do not resolve, record that the pre-08-25 evidence chain
is unrecoverable, so future handoffs must cite pushed SHAs only.

### 4. Reconstruct how history was re-rooted (G4)

The pushed repo starts at `aabcb69 reroute: capture staged work off main`
(2026-08-25). In the original checkout, check whether an older history exists
(`git reflog`, other branches, an `old-main`). Answer: was per-commit history
for 08-06 → 08-24 ever pushed anywhere, and can it be grafted (`git replace`)
or is the single-blob root permanent?

### 5. Settle the enforcement questions (G7, G8, G10)

```bash
# Did init restore the hooks, and when? Shell history or ansible logs if available.
grep -n reroute-main-commit .pre-commit-config.yaml
# Is exophiald expected to be running now?
pgrep -af exophiald; ls .exophial/locks .exophial/logs 2>/dev/null | head
# claude-md-coverage semantics: why do module/src/*/ dirs pass?
exophial-check-claude-md; echo "exit=$?"
# Does the current build's reroute hook still fire on a plain commit to main?
# (dry: read the hook source rather than committing)
# settings.json per-hook "if" key: is it honored by the Claude Code version on this machine?
```

Answer: (a) is dispatch intended to be live on this machine today, or was
08-25/26 a one-off? (b) what does `exophial-check-claude-md` actually define as
a covered directory? (c) does the `"if": "Bash(git commit:*)"` key in
`.claude/settings.json` do anything?

### 6. The posture decision (the actual deliverable)

With 1–5 answered, put the choice to the operator with a recommendation:

- **Adopt dispatch fully.** Requires: the regate env fix (check 2), a configured
  `gate:` command for spec-less pebbles in `.exophial/config.yaml` (today a
  spec-less merge is graded by nothing — G2; the conformance/probe suite is the
  obvious candidate), a `testing-nim.md` + muster-edited doctrine (G9), and the
  trailer-block fix so trailers parse as git trailers (G6).
- **Officially spec-authoring + tracking only.** Requires: remove the dispatch
  hooks again, this time with whatever init-proof mechanism check 1 found (or an
  upstream issue if none exists), update the labbook entry, and state the
  posture in CLAUDE.md so the next `exophial init` is run with open eyes.

Either way, file the outcome as pebbles and update
`docs/exophial-usage-gaps.md` with what was confirmed, refuted, and decided.
