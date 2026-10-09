# Muster: session handoff, the Monero campaign's first days

**Date:** 2026-10-09
**Repo:** https://github.com/corpetty/muster (`main` at `0b99493`, #257)

This document picks up where [`05-session-handoff-2026-10-02.md`](05-session-handoff-2026-10-02.md)
left off. 05 §3 (setting up a machine: the pebbles merge driver, exophial, `pb`, the Nim test
closure, the fleets) and 04 §2 still hold. This one covers what landed since 2026-10-02,
what is in flight, the decisions made, what waits on the operator, and the traps found.
`CLAUDE.md` stays authoritative for layout, invariants and the current phase.

---

## 1. State at handoff

**Everything below is merged to `main`, through #257.** No pull request is open.

**The direction changed on 2026-10-07.** Development now aims at one outcome: people in the
Monero community use XMR from inside Muster rooms, on their own machines. This is epic
`exo-dcc`; the plan is [`design/monero-in-rooms.md`](design/monero-in-rooms.md), with live
status in its §0 and in `pb dep tree exo-dcc`. Day 0 was 2026-10-07; today is day 2.

**Where the epic stands:**
- Phase 0 (ground truth) is done, and so is Phase 2 (the XMR payment request), except its
  live payment. That is ahead of the plan's calendar.
- The live payment (`exo-dcc.19`) and the messaging gifter (`exo-dcc.2`) wait on funds (§4).
- The first catalogue release, `muster-v0.2.0`, is being published (§3).

The suite is 233/233 (149 unit tests, 84 invariant probes). `scripts/grade-specs.sh exo-dcc.5`
grades 7/7, and `scripts/ui-parity.sh` was 10/10 on #256.

---

## 2. Landed since 2026-10-02

The table lists merged PRs on `corpetty/muster`.

| PRs | What |
| --- | --- |
| #215–#219, #221 | The new machine's bring-up, finished in 05; a relaunched member re-enters its rooms (exo-ecbe); an intent's propose and policy count only as the pair its id hashes (exo-dbd). |
| #222 | exo-a90.21: a split's R-4/R-6 rerun (a kill mid-collection) passed across two machines. |
| #218, #226 | `docs/design/side-modules.md`: what leaves `muster_module`, and what never does (exo-ff5). |
| #223–#225, #230, #232 | Every chain call on the module thread runs under a budget, and a failed read raises (exo-14f, exo-496). A configured RPC URL is masked in Settings. |
| #228, #229, #231 | `make build`, `build-lgx` and `appimage` cap their own memory (`BUILD_MEM`); uncapped on bugger. |
| #233 | Quieter logs (exo-9eed). |
| #234, #237 | ADR-017, the typed (EIP-712) attestation and identity binding for keys the platform holds. Accepted; K6b's builders, verifiers and probes landed. |
| #235, #236 | **Real use on Basecamp** (epic exo-d4d). The member's EVM key is a `keystore_module` account approved in the platform's Signer. Chain reads go through `eth_rpc_module`, and every EVM send through `tx_sender_module`. Nothing is seeded. R6 passed on display on Sepolia: two fresh Basecamp 0.3.1 profiles, a split and a Safe. |
| #238 | The Monero plan. All seven links of the transaction pipeline are Muster's scope (exo-dcc.9). |
| #239 | **Install what's missing, from the card and the proposal form** (exo-dcc.10): three-state readiness from `modules_state`, and Basecamp's `packages.install`. |
| #240 | **The mixnet for a room's sends, opt-in** (exo-dcc.4): the `mix` setting, off by default, sends only. |
| #241 | ADR-018 (Monero settlement), `monero.split` on the atlas, the network and catalogue options. |
| #242, #246 | **Basecamp 0.3.2.** Delivery 0.3.2 pinned (exo-dcc.12). A founder relaunched before admitting anyone reads its room again (exo-6dc.1, carried over from #220 by cherry-pick). One delivery node per module instance. |
| #243, #245 | Muster declares `monero_wallet_backend` (optional) and reaches it in Basecamp. A module the registry reports ready reads met (exo-dcc.1, exo-dcc.11). |
| #244 | The site: a landing page at the Pages root; diagrams move to `/diagrams/`. |
| #247 | `monero/address.nim`: a pure Monero address parser, the CAIP-2 map and the `monero:` URI. |
| #248, #251 | **The catalogue** (exo-dcc.3): version ranges on every dependency; Muster 0.2.0; `catalog/` and `scripts/catalog-release.sh`; a fresh Basecamp 0.3.2 installed Muster from a locally served copy. |
| #249 | ADR-018 accepted. The demo runs on `logos.test` with a gifter we run; the catalogue lives in this repo. |
| #250, #252, #254, #256 | **The XMR payment request** (exo-dcc.5, exo-dcc.20): the spec `derived-exo-dcc.5`, the module (`monero.split` built, 7/7), the UI (Request a payment, the `monero:` link and QR, I paid, the wallet remedies, n of 10, Share my Monero address), and the rough edges the display found. Labbook: `labbook/xmr-payment-request.md`. |
| #253, #255, #257 | Pebble events: closes and follow-ups. |

**Upstream, still open:** [logos-co/lez-multisig#45](https://github.com/logos-co/lez-multisig/pull/45)
and [logos-co/logos-module-builder#226](https://github.com/logos-co/logos-module-builder/pull/226),
as in 05.

---

## 3. In flight

- **The first catalogue release, `muster-v0.2.0` (exo-dcc.3).** It was being published when
  this was written. The order is in `catalog/README.md`:
  1. `scripts/catalog-release.sh` on a clean `main`;
  2. the GitHub release with the two `.lgx` files;
  3. then commit `catalog/index.json` and `catalog/icons/` to `main`.

  Until step 3, the catalogue URL lists nothing. After it, run the stranger's path once:
  [`runbooks/install-from-catalogue.md`](runbooks/install-from-catalogue.md).
- **This document's branch** (`docs/entry-points-monero`): the entry points and plan
  documents brought up to date, and the runbook `runbooks/xmr-payment-request.md`.
- **Other sessions** were editing the site (`site/`), the atlas and its action corpus, the
  claims registry, `infra/`, `two-party-demo-runbook.md` and `design/multisig-landscape.md`
  at the same time. Check their branches before touching those files.
- **From the v0.3 session, still open:** RLN R1 (exo-eb6.3.1), the v0.3 multisig port
  upstream (L4e), and the live LEZ runs on the v0.3 testnet (L5b).

---

## 4. Decisions made, and what waits on the operator

**Decided 2026-10-08, by the operator:**
- **ADR-018 accepted.** Monero settles on the `each` locus, through the platform's wallet,
  confirmed by the payee's own wallet. Stagenet first. Muster never makes itself approver.
- **The demo runs on `logos.test`, with a room gifter we run** (`design/rln-membership.md` §7).
  Our funded node is in every demo room, and the members' disclosed secp256k1 addresses are
  its EIP-191 allowlist, so participants never hold LEZ. Slices: R2 (one membership active
  end to end), R3 (the room gifter), R4 (the default fleet moves to `logos.test`). None is
  built.
- **The catalogue lives in this repo** (`catalog/`, served raw from `main`), with the `.lgx`
  files as release assets.

**Waiting on the operator: funding two addresses.** These are public addresses, safe to share.

| For | Network | Address |
| --- | --- | --- |
| The payer in the live XMR request run (`exo-dcc.19`) | Monero stagenet (stagenet XMR, from a faucet) | `57VTGxT3AW727aC8Df1WfxfkhrxwknsrZe8Wp2zvwCzt6CJvGjjtiW7Wiei8Y6XmGJjeQMHbZ4S5iFF7DbRqwc7dBsJnXeW` |
| The gifter's RLN payer (`exo-dcc.2`) | LEZ classic, sequencer `209.38.241.182:3240` (native LEZ, about 7.5×10⁷ per membership) | hex `0dd45a7ff56b70dc35023fe71dc8f8896bf9f7e638d9883e72ad38f2847af24e`; LEZ form `Public/vz7BbAs2n2zv3S2tC6Fh7dSfZz6Bk8rt9F6TV4Ygthj` |

**The wallets live outside the repo**, on bugger, in `~/.local/share/muster-campaign/`:
- `stagenet-payer/`: the stagenet wallet;
- `gifter/`: the gifter's Muster runner profile, whose RLN modules hold its LEZ wallet;
- `README.md`: what each is.

The directory is `0700`. Nothing in it is committed or copied anywhere, and nothing should
be. Back it up if the campaign depends on it. A second machine has none of it.

**Also the operator's:** publishing `muster-v0.2.0` (§3). And the asks of other teams in
`design/monero-in-rooms.md` §8: a review intent in `monero_wallet_ui` (`exo-dcc.6`), tx proofs
in the backend, and gating the core's commit.

---

## 5. Traps found this stretch

- **exophial's local exo-446 patch was lost in an upgrade.** The `resolve_script_path` patch
  makes the spec grader find a Nim probe. An exophial upgrade replaced it, and grading the
  new spec failed until it was put back. It was re-applied on 2026-10-08, with the
  pre-patch file kept as `.pre-nim-bak`. After any `uv tool install` or upgrade of exophial,
  re-check that `scripts/grade-specs.sh exo-dcc.5` still grades 7/7.
- **The hooks forbid `git merge` and `git rebase`**, and any write to a branch ref other
  than your own. Carry a PR built on an old `main` onto a fresh branch from `main` with
  `git cherry-pick`, as #246 did for #220. The hook matches text, not intent:
  `git branch -r | grep …` was refused as an attempt to write a ref named `|`. To read
  remote branches, use `git ls-remote --heads origin`.
- **Stacked PRs, and the pebbles log.**
  - A stacked PR names its base branch, not `main` (#239 was stacked on #238). Merge the
    stacked one into its base first, then the base into `main`, or retarget it to `main`
    once its base has merged.
  - Each branch appends to `.pebbles/events.jsonl`, so stacked and parallel branches always
    diverge there. GitHub shows CONFLICTING, because it has no `pebbles-union` driver.
  - Locally the driver merges by union, removes duplicates, and sorts by timestamp. So the
    order the commits land in does not matter: a cherry-picked or late-merged event takes its
    place by its own timestamp. Resolve such a conflict locally, where the driver runs, and
    never by hand-editing the log. The driver's setup is in 05 §3.
- **A shared nimcache races across worktrees.** `run-suite.sh` uses the default nimcache,
  `~/.cache/nim/<test>_r`, keyed by test name and not by checkout. Two worktrees running the
  suite at once link each other's half-written objects. The symptom is a link error, not an
  assertion, in a test the change never touched. Rerun that one test with a private cache
  before believing it, or give each session its own: `XDG_CACHE_HOME=<scratch>/xdg-cache`.
  See `labbook/concurrent-worktrees-share-the-nimcache.md`. The lasting fix, a per-checkout
  `--nimcache` in the runner, is not done.
- **`frost_ceremony_room_test` flakes** (exo-dcc.17). It asserts that a random junk event id
  sorts before a real one (line 181), which holds only most of the time. One red there is not
  a regression; rerun it alone.
- **`grade-specs.sh` leaves `module/.probe-env` behind** (exo-dcc.22).
  `audit-download-self-test.sh` then builds its verifier with the host compiler and fails.
  Remove the directory, and it is green.
- **In Basecamp, `lp_get_methods` always returns `[]`.** A readiness that waits on a module's
  methods waits forever. Ask `modules_state` instead. This was the "silent for five minutes"
  of exo-dcc.11 (`labbook/monero-stack-from-muster.md`).
- **Monero Wallet answers `monero.wallet.unlock` with `failed`** even after it opened the
  wallet (exo-dcc.21, upstream). Don't read that reply as a refusal.
- **Cached wallet reads that arrive in lockstep are never served.** If each re-read replaces
  the last reply before a status read confirms it, nothing is ever confirmed. Keep the last
  confirmed reply apart from the newest one (`WalletBoundCache`,
  `labbook/xmr-payment-request.md`).
- **The delivery store refuses a query wider than 24 hours.** Delivery 0.3.0's own startup
  catch-up asked for more; 0.3.2 splits it (`labbook/store-24h-rule-and-the-lost-relaunch.md`).
  A room lives only as long as the fleet's store keeps it (exo-dcc.14).

---

## 6. Open work

`pb ready` gives the live list. These are closest to hand:

- **exo-dcc.19:** the live XMR payment, two machines, stagenet, 10 confirmations. Fund the
  payer first (§4). It also answers the spike's two open questions: whether an incoming
  transfer shows in `history()` before it confirms, and how long a first sync takes.
- **exo-dcc.2:** R2, then R3 (the room gifter), then R4. Fund the gifter first (§4). From
  about 2026-10-14, `logos.test` rejects messages without RLN proofs.
- **exo-dcc.3:** finish the release, then run the stranger's install once.
- **exo-dcc.7:** the deal-desk demo, once `.2`, `.3` and `.19` are done. `audit.nim` must learn
  the split families first.
- **Follow-ups filed:** exo-dcc.13–.18 and .21–.23 (`design/monero-in-rooms.md` §0). The P2 one
  is exo-dcc.14, keeping a local copy of each room's log.
- **Still open from 05:** the multi-party runs across two machines (the Safe settle over the
  live wire with R-4/R-6, the LEZ multisig, a FROST ceremony), and exo-ff5.9: a room's
  payments are confirmed only while it is the open room. That also applies to the XMR request.
