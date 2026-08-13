# Exophial's sole-integrator hooks in a repo that runs no dispatch

**Finding, 2026-08-13.** `.claude/settings.json` carried exophial's per-pebble worktree machinery in a repo that uses none of it. The guard blocked every push and every branch creation until it was removed, and its own escape hatch asks you to assert a role nobody here holds.

## What happened

Opening a pull request failed at `git branch`:

```
Blocked: writing to 'refs/heads/docs/diagram-programme' is an irreversible,
integrator-only git operation on shared state. A worker/lead process is scoped
to exactly one branch, its own `worker/<id>` … only exophiald may move, create,
or delete. (If you ARE exophiald's integration step, set EXOPHIALD_INTEGRATOR=1 …)
```

`git push origin main` failed the same way (`push-main`), so **every route to the remote was closed**. The hook is `exophial hook block_worktree_leak` — "enforce exophiald's sole-integrator keystone", wired as a `PreToolUse(Bash)` hook.

## Why it did not apply here

This repo already reached the same conclusion on the pre-commit side and wrote it down. From `.pre-commit-config.yaml`:

> `reroute-main-commit` is DELIBERATELY NOT installed here: this repo does not use exophial's dispatch/worker/integrator machinery (exophiald never runs as the sole integrator here), only its discuss-issue spec-authoring flow — so the sole-integrator restriction has no daemon on the other end to land through and only blocks normal human commits to main.

The same reasoning applies to the settings hooks, and the same restriction had survived in the other place. There is no exophiald here to "append a pebble and let exophiald reap" to; the instruction the guard gives has no recipient.

It also **false-positives on read-only commands**. `git branch -a | grep diagram` was rejected as a write to a ref named `|`.

## What was removed, and what was kept

Removed — the worktree / sole-integrator machinery:

| Hook | Where |
|---|---|
| `block_worktree_leak` | `PreToolUse(Bash)` — the blocker |
| `fix_worktree_index` | `SessionStart`, and `PreToolUse(Bash)` on `git commit` |

`fix_worktree_index` works around a Claude Code bug that bites a repo opened in a *linked git worktree* — exophial's per-pebble model. This checkout is an ordinary one, so it was a no-op that travels with the machinery.

Kept — generic cross-repo guards with nothing to do with dispatch: `block_ssh`, `doctrine_preflight`, `block_memory_rule_write`, `statusline`, and both `pb prime` calls.

## The part that will bite later

**`exophial init` restores them.** `reconcile_claude_settings` treats the `PreToolUse(Bash)` block and the whole `SessionStart` array as *managed* — reconciled to a canonical manifest, replaced wholesale. So this removal holds until someone runs `exophial init` in this repo, at which point the guard returns silently and the next push fails again.

There is no per-repo opt-out in the manifest today. Until there is, the options are: re-remove after any `init`, or pass `EXOPHIALD_INTEGRATOR=1` on the git commands that need it.

When dispatch is actually adopted here, put these back deliberately rather than by reconciliation — the guard is correct for the model it was written for.
