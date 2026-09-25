# Muster: session handoff for moving machines

**Date:** 2026-09-25
**Repo:** https://github.com/corpetty/muster (`main`, with this document merged)

This document starts a session on a different machine. It assumes neither the previous
conversation nor anything from the previous machine: no Claude Code memory, no scratch
toolchains, no sibling checkouts. `CLAUDE.md` is authoritative for layout, invariants and
the current phase. This document covers only what a new machine needs and what was in
flight.

---

## 1. State at handoff

**Nothing exists only on the old machine.** All work is merged to `main`. There are no
unpushed branches and no stashes, and the tracker's events (`.pebbles/events.jsonl`) are
committed, so `pb` shows the same state here.

**Landed 2026-09-24/25**, all merged PRs on `corpetty/muster`:

| PR | What |
| --- | --- |
| #143–#148 | Phase C, the LEZ multisig: the vote locus against the program model, settlement, the #40 bypass fix, the rebuilt program, and the testnet docs. |
| #149 | exo-3c9, the live binding. The room drives `lez-multisig` on a real LEZ v0.2.4 chain: in-app member keys derived in the keystore, async hosted steps, and the UI. |
| #150 | The rest of Phase D. FROST on Bitcoin: an in-room ChillDKG and both rounds over the log, with a regtest exit test. The chain sees one 64-byte signature. |
| #151 | The FROST hosted surface and room UI: open or join a ceremony; Approve runs both rounds. |
| #152 | `lez.frost-public-account`. A FROST group acts from its own untweaked LEZ public account: a `lez-call` at a nonce read from the chain, and settlement re-reads the nonce and refuses on mismatch. |
| #153 | LEZ FROST hosted surface and UI: the transfer composer sends from the group's account. |
| #154 | Campaign post 3 (working draft) and the action-manifest §2a defection facet (exo-3ae). |
| #155 | `.gitignore` excludes third-party reference sources at the repo root. |
| #156 | exo-cf7. A malformed signature is never fatal: the fold no longer raises when a hostile approval is in the log. This PR also ported `dcbor_golden_test`. |

**Upstream, open:**

- [logos-co/lez-multisig#45](https://github.com/logos-co/lez-multisig/pull/45) is the
  LEE v0.2.4 port plus the #40 fix. CI is green and it needs a maintainer review.
  - The program is **deployed on the public testnet** `https://testnet.lez.logos.co`:
    ImageID `2ced3d301a4d1cd5db6cad9c428b9f3463155073f8bacf73179c6ea6536de4c7`,
    tx `61a7abe2…faa0`, block 23405.
  - `lez_multisig_live_e2e` passes against it.
- [logos-co/logos-module-builder#226](https://github.com/logos-co/logos-module-builder/pull/226)
  holds `nim.packages` and the RUNPATH fix. Until it merges, `module/flake.nix` pins the fork
  (`corpetty/logos-module-builder@c10a94c`).

---

## 2. Setting up the new machine

**The build needs no local path.** Every flake input is a GitHub ref. `ui/flake.nix` reaches
`muster_module` through `git+file:../?dir=module`, which resolves inside the clone. This was
verified at handoff from a fresh GitHub clone; see §5.

1. **Clone, then install the git hooks.**

   ```bash
   git clone https://github.com/corpetty/muster && cd muster
   pre-commit install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push
   ```

   The hooks call exophial entry points (`exophial-reroute-main-commit`,
   `exophial-check-claude-md`, `exophial-session-trailer`, `exophial-red-before-green`,
   `exophial-check-subtree-edits`). The old machine ran **exophial 0.2.1+b192e1ef** as a
   `uv tool`, plus `pb` for the tracker. Without them every commit fails its hooks.

2. **Nix substituter.** The user is not a trusted nix user, so pass the Logos cache
   explicitly on every build:

   ```bash
   --extra-substituters https://cache.nix.logos.co/public --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=
   ```

   `make build` builds the standalone runner, and `scripts/card-self-test.sh` is the
   offscreen QML check.

3. **The Nim test closure.** `module/tests/README.md` lists the package clones and the flags
   each test needs:
   - `$SECP`: nim-secp256k1, nim-stew, nim-results, nimcrypto.
   - `$STINT`: nim-stint, nim-intops.
   - The web3 closure adds nim-eth, nim-web3, nim-chronos, nim-chronicles, nim-bearssl,
     nim-faststreams, nim-json-rpc, nim-serialization, nim-json-serialization and
     nim-http-utils.
   - libsodium.

   The invariant-probe baseline is **54 pass, 1 environment failure**:
   `probe_return_marshalling_host` also needs `--path` to `logos-nim-sdk/src`, at the rev
   `module/metadata.json` pins (`9aa82f3`).

4. **Local chains for the e2e tests**, only when a test needs one:
   - **LEZ v0.2.4:** `infra/lez/localnet.sh`, which runs on `127.0.0.1:3040`. The first
     build takes about 15 minutes. It needs Rust 1.94.0, `r0vm` 3.0.5 on `PATH`
     (`rzup install r0vm 3.0.5`) and `LIBCLANG_PATH`. The script header lists these, and the
     reasons are in `docs/labbook/lez-multisig-versions.md`.
     - Build the multisig guest with `make build` in a `logos-co/lez-multisig` checkout
       (PR #45 or later). It reproduces the testnet ImageID.
   - **Bitcoin regtest:** `nix shell nixpkgs#bitcoind -c bash infra/bitcoind/regtest.sh start`.
     `phase_d_exit_test` needs a **fresh** regtest; stop any other worktree's instance first.
   - **Anvil and the real Safe v1.4.1:** `infra/anvil/devnet.sh`.

---

## 3. What does not transfer, and what replaces it

- **Claude Code memory on the old machine** had one entry: direct commits to `main` are
  refused. `.pre-commit-config.yaml`'s `reroute-main-commit` enforces this. Land work on a
  branch, then PR, then merge.
- **Scratch toolchains** do not transfer: the Nim package clones, the built LEZ sequencer,
  and the risc0 tools. Rebuild them per §2.
- **Sibling checkouts on the old machine hold nothing muster needs.**
  - The `logos-basecamp` bake-in for the P4 UI harness is documented step by step in
    `ui/tests/README.md` §1. Use that recipe; it uses `git+file:`, not the old `path:` spike.
  - The local `logos-module-builder` checkout is no longer referenced by any muster flake.
- **Two audit SHAs** that `docs/exophial-usage-gaps.md` (G4) records as resolving,
  `2723d24` (exo-2dc handoff) and `8c40c7f` (exo-3a1 worker capture), **no longer resolve on
  the old machine either**. They were local worker captures, never pushed, and were lost
  between 2026-09-02 and 2026-09-25. `38e3a3b` is on `origin/main` and still resolves.
  Nothing depends on the lost two except that record.

---

## 4. Open work

See `pb ready` and `pb dep tree exo-a50` for the live list. The ones closest to hand:

- **The multi-party runs across two machines.** A second machine makes these possible:
  - exo-a50.8: the LEZ multisig, propose → vote → settle between two instances through the UI.
  - A two-instance FROST ceremony and signing.
  - The cross-host Safe-txn settle over the live wire, plus the R-4/R-6
    kill-mid-collection resilience check (P3's remainder, `CLAUDE.md`).
  - `docs/two-instance-fleet-runbook.md` and `scripts/demo-peer.sh` are the starting points.
- **On-display click-through** of the LEZ multisig, FROST and LEZ FROST room surfaces
  against a live sequencer. Each is verified headless and offscreen (runner builds, no QML
  errors), but nobody has clicked through them on screen.
- **exo-a50.6:** the offscreen self-test for a Bitcoin intent through the real UI.
- **exo-a50.5:** a Keycard Shell cosigns a PSBT over QR. This needs the device.
- **exo-a50.7:** a wallet-backed LEZ chain. It is blocked upstream, because `lez_core` needs
  0.4.1+ for the `send_generic_public_transaction` fix, and that targets v0.2.5-rc.
  Until then muster signs LEZ transactions in-app with keystore-derived member keys.
- **exo-1ec.2:** fresh-clone build. The flake half is done (§5); the CI job is still missing.
- **exo-3ae:** post 3 and the defection facet. In progress, the operator's.

---

## 5. Verified at handoff (2026-09-25)

The checks below ran against a fresh `git clone https://github.com/corpetty/muster` at
`d8645cb`:

- `nix flake metadata` for `module/` and `ui/` resolves every input (4,348 and 8,696 lock
  nodes) with **no local-path inputs**.
- `cd module && nix build .#lgx-portable` builds from the fresh clone.
- `dcbor_golden_test` runs from the fresh clone, pure Nim.
