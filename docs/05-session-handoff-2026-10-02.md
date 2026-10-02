# Muster: session handoff for moving machines

**Date:** 2026-10-02
**Repo:** https://github.com/corpetty/muster (`main`, with this document merged)

This document resumes muster work on a different machine. It extends
[`04-session-handoff-2026-09-25.md`](04-session-handoff-2026-09-25.md): §2 there (clone, hooks,
the Nix substituter, the local chains) still holds. This one covers only what changed since
then, what was in flight, and the gotchas found along the way. `CLAUDE.md` stays authoritative
for layout, invariants and the current phase.

---

## 1. State at handoff

**Everything from the split, settle-up, atlas and card work is merged to `main`.** That covers
every PR up to #207, and the tracker's events for that work are committed.

**Merged after this was written:** #208, `docs/atomic-swaps-lez-v03` (2026-10-02). It is the
LEZ v0.3 escrow session's note on the atomic-swaps HTLC (exo-f60d),
`docs/upstream/atomic-swaps-htlc-on-lez-v03.md`. Nothing is open on GitHub.

**Only on the old machine.** None of the items below is pushed; each belongs to another session.
They were deliberately left as they are, so the new machine starts without them:

| Branch | Last commit | Ahead of `main` | What |
| --- | --- | --- | --- |
| `claude/zealous-franklin-8adb24` | 2026-10-01 | 2 | exo-3e8: a Bitcoin settle-up never nets to a payment below dust (red test + fix) |
| `docs/seaqt-ui-scope` | 2026-09-28 | 1 | exo-607 scoping note |
| `docs/figures-truth-2026-09-25` | 2026-09-25 | 1 | diagram truth pass |
| `fix/demo-peer-appimage`, `fix/demo-peer-tmpdir` | 2026-09-18 | 1 each | `demo-peer.sh` AppImage fixes |
| `fix/keystore-clear-error` | 2026-09-17 | 2 | runbook: the "account not loaded" fix |

Two stashes are also local: `pre-ff-store-catchup`, and `WIP on main: 26df8de` (exo-6bc).

**exo-3e8 exists only in its branch's event log.** It was filed on that branch, so `pb show`
on `main` does not know it; it reaches `main` with its branch or not at all. The same holds
for exo-149 and its children, whose events are on the pushed `feat/keystore-module` (below).

**`feat/keystore-module` is pushed** too, with no PR: `e63069d` (2026-10-02), 10 commits
ahead of `main`. It is epic exo-149, the official `keystore_module` as muster's EVM key
backend; the design note is `docs/design/keystore-module-backend.md`.
- **Closed:** K1, K2 and K5, each verified headless under logoscore 0.3.1:
  `scripts/keystore-logoscore-test.sh` and `scripts/keystore-approval-logoscore-test.sh`
  (anvil, the real Safe, `evm_keystore_cli`, `evm_signer_cli`).
- **Not verified:** K5's UI build (Settings, the `.rep`, the backend). An uncapped `make build`
  exhausted the old machine. Build the UI plugin alone and capped:
  `cd ui && nice -n 19 nix build .#lgx --max-jobs 1 --cores 4 -L`.

**The v0.3 session's L5 work is pushed** as a WIP commit with no PR:
`feat/lez-v03-live` at `024fea8`. It contains `infra/lez/funder.sh`, the three v0.3 e2e tests
funding through `tests/probes/lez_funding.nim`, and their pebbles events. When this was
written, the e2e reruns on a local zone had not finished, and their result is not in that
commit.

---

## 2. Landed since 2026-09-25

The table lists merged PRs on `corpetty/muster`.

| PRs | What |
| --- | --- |
| #158 | Bring-up on a second machine: `module/tests/run-suite.sh`, the one-command suite. It fetches the Nim closure itself. |
| #160, #164, #172, #174, #179 | Fold and authorship hardening. Author-bearing events are signed by their author (exo-f76). A k-of-n decision needs k distinct signers (exo-a5a). The card counts only what the fold counts. |
| #162, #163, #166, #197 | The action atlas, served at <https://corpetty.github.io/muster/atlas/>, and its detail pane scrolling on its own (exo-eee). |
| #167 | exo-661.7: nothing on a room's topic says who is in it. **This changes the wire format:** builds from before and after it cannot share a room. |
| #168–#170, #191 | The hands-on client tour (`docs/runbooks/client-tour.md`, `scripts/try-infra.sh`, `scripts/try-peer.sh`) and the fixes it needed. |
| #171, #173, #176, #177, #182–#185, #187–#190, #192, #194, #195 | **Split the bill** (epic exo-a90), with the families `evm.split`, `lez.split` and `btc.split`. It covers ERC-20 shares, fiat quotes, settle-up, renewal, expiry, and payments in flight. The private split ran on the LEZ testnet. |
| #196 | The spec `derived-exo-a90.20`, graded 8/8. |
| #199 | **Settle up across assets and chains** (exo-a90.17): rates per unit, conversions refused on overflow (exo-df6), and payment at vouched addresses. Its spec is `derived-exo-a90.17`, graded 6/6, and it was looked at on a display. |
| #205 | The address-request card knows who answered (exo-8e2). Chains are named for the reader by `chainLabel` in `drivers/profile.nim` (exo-e71). |
| #180 | Home: "waiting on you" is a query over intents across every room (exo-ed5). |
| #181, #186 | exo-607 T0–T4: the UI parity harness and the nim-seaqt toolchain. |
| #193 | Rejoining a room reads its whole history (exo-aaf). |
| #198, #200–#204, #206, #207 | **Testnet v0.3** (epic exo-eb6, the v0.3 session's): delivery v0.3.0 on `logos.dev`, RLN R1, `MUSTER_FLEET=local`, `lez_core` 0.5.0, a local v0.3 zone with a funder, v0.3 public transactions, the private split on a local v0.3 zone, and the LEZ multisig on v0.3. |
| #208 | A shareable note for `logos-co/atomic-swaps-poc`: what LEZ v0.3 does to its HTLC escrow (exo-f60d). |

**Upstream, still open:** [logos-co/lez-multisig#45](https://github.com/logos-co/lez-multisig/pull/45)
(the v0.2.4 port plus the #40 fix) and
[logos-co/logos-module-builder#226](https://github.com/logos-co/logos-module-builder/pull/226)
(`nim.packages` + RUNPATH; `module/flake.nix` still pins the fork).

---

## 3. Setting up the new machine: what changed since 04 §2

1. **The pebbles merge driver lives in `.git/config`, so a clone does not have it.**
   `.gitattributes` routes `.pebbles/events.jsonl` through `merge=pebbles-union`. Without the
   driver, every rebase that touches the log conflicts. After cloning, run:

   ```bash
   git config merge.pebbles-union.name "union+dedup+timestamp-sort merge for the append-only .pebbles bus"
   git config merge.pebbles-union.driver "exophial-bus-merge %O %A %B"
   ```

2. **exophial** is the `uv` tool from the pinned git rev. It provides every hook entry point
   and `exophial-bus-merge`:

   ```bash
   uv tool install "exophial @ git+https://github.com/AFDudley/exophial.git@dc69cd1"
   ```

   **`pb`** is a standalone binary, `~/.local/bin/pb` on the old machine. Copy it across.

3. **The Nim test closure is automatic.** `module/tests/run-suite.sh` clones the closure at
   `module/metadata.json`'s pins into `~/.cache/muster/nimpkgs` the first time it runs. The
   hand setup in 04 §2.3 is no longer needed. The suite is now 75 invariant probes plus the
   unit tests. Of the specs, `scripts/grade-specs.sh exo-a90.17` grades 6/6 and
   `exo-a90.20` grades 8/8.

4. **Fleets.**
   - The default is `logos.dev`: cluster 3, no RLN.
   - `logos.test` needs a funded RLN membership before a node sends anything. See
     `docs/design/rln-membership.md`.
   - `MUSTER_FLEET=local` runs the two-instance self-tests on a two-node network the
     instances make on this host, with no fleet. `scripts/try-peer.sh` does not support
     `local` yet.

5. **Claude Code memory** is per machine, in `~/.claude/projects/<path-derived dir>/memory/`.
   The directory name comes from the checkout path, so copy it into the directory that
   matches the new path. Nothing in it is needed to build. It holds the per-epic pointers the
   sessions used for recall.

---

## 4. Gotchas found this stretch

- **Pull requests show CONFLICTING on GitHub when only `.pebbles/events.jsonl` diverges.**
  GitHub has no `pebbles-union` driver. Rebase locally, where the driver merges the log
  cleanly, then `git push --force-with-lease`.
- **Hooks block integrator-only git.** `git merge`, `git worktree remove`, `git branch <new>`
  and commits on `main` are all refused. Use `git switch -c` or `git worktree add -b` for a
  branch, `gh pr merge` to land it, and cherry-pick to move commits. Every commit needs a
  `Tested-Behavior:` or a `TDD-Exempt:` trailer.
- **Several sessions on one machine share the Nim cache.**
  - Two `run-suite.sh` runs at once collide on `~/.cache/nim` and on fixed temp paths.
  - A session compiling the same tests can corrupt another's nimcache. The symptom is a
    link error naming undefined mangled symbols.
  - Run one suite at a time, or give each session its own cache:
    `XDG_CACHE_HOME=<scratch>/xdg-cache module/tests/run-suite.sh …`.
- **High machine load produces false failures.** At a load average near 100, a gcc link step
  or the 900 s probe cap can fail. Rerun the single test before believing it.
- **Display runs.**
  - Use Xvfb plus xdotool, with the runner under `QT_QPA_PLATFORM=xcb
    QT_QUICK_BACKEND=software`. The recipe is in
    `docs/labbook/qml-errors-are-invisible-to-nix-build.md`.
  - For two peers without a fleet, use `MUSTER_FLEET=local`; `scripts/lib/ui-build.sh` has
    `ui_local_config` and `ui_peer_config`.
  - Kill only your own runners. Match `LOGOS_INSTANCE_ID` or the exact cwd, never a pattern
    that matches other sessions' worktrees.

---

## 5. Open work

`pb ready` gives the live list. These are closest to hand:

- **exo-a90.21:** run a split across two machines, with each peer on its own host. This is
  the first thing a second machine makes possible.
- **The multi-party runs from 04 §4** are still open:
  - exo-a50.8: the LEZ multisig, propose → vote → settle across two instances.
  - A two-instance FROST ceremony.
  - The cross-host Safe-txn settle over the live wire, plus R-4/R-6.
- **Card copy.**
  - exo-4d4: an Ethereum address-share card says "Anyone reading the zone…".
  - exo-1d9: a member's own address-share card offers them "Use as recipient".
- **exo-3e8** (Bitcoin settle-up dust) is on an old-machine branch only (§1).
- **exo-149** (`keystore_module` as the EVM key backend) is on the pushed `feat/keystore-module`
  (§1). Next: K5's UI build check, then K3 (Basecamp hands the person to the signer), K4
  (`tx_sender_module`) and K6 (typed attestation and binding, an ADR).
- **exo-eb6:** the v0.3 migration, owned by the v0.3 session.
  - Open: RLN Q1 and Q3.
  - LEZ v0.3: the live-testnet half of L5.
  - Proof validation on `logos.test` starts about 2026-10-14.
- **exo-a90.17 follow-ups:** none open. The display run found and fixed its own copy
  problems, and the card problems that predate it are exo-8e2 and exo-e71, both now closed.
