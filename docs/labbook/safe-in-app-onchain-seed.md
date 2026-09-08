# Safe settles on-chain from an in-app approval (exo-001)

**Date:** 2026-09-08. **Pebble:** exo-001. **Builds on:** exo-535 (in-app signing).

## The gap this closes

After exo-535 you approve a Safe intent **in-app** — the module signs the re-derived
`safeTxHash` with your keystore's secp key on an empty signature. But `coordinate_submit`
settles on-chain by assembling the Safe `execTransaction` from the folded signatures,
and the contract's `checkSignatures` only accepts **real on-chain owners**. A fresh
muster identity is a random address, not a MiniSafe owner — so its in-app signature
folds to executable but the chain would reject it.

## The mechanism

`openFileKeystore(path, pass, secpSeed)` seeds the secp authorization key when minting
a fresh keyfile; `moduleKeystore` reads it from **`MUSTER_DEV_SECP_KEY`**. Give an
instance a known anvil Safe owner key and it *is* that owner — its in-app Safe
signature recovers to a real on-chain owner, so an in-app approval can settle.

- Honoured only on first mint (an existing `identity.mks` keeps its identity) — wipe
  the peer dir (`make clean-peer PEER=<x>`) to re-seed.
- No env ⇒ a fresh random identity, the normal path (unchanged).
- `safe_owner_seed_test` asserts: seeded with anvil key 0 ⇒ `address == owner 0`, and
  the in-app `safeTxHash` signature is recognised by the Safe driver as a configured
  owner.

Anvil owner keys (from `infra/anvil/devnet.sh`):

| owner | address | key (`MUSTER_DEV_SECP_KEY`) |
|---|---|---|
| 0 | `0xf39Fd6…2266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |
| 1 | `0x709979…79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| 2 | `0x3C44Cd…93BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |

## The full 2-of-3 on-chain run (needs anvil + the fleet/a delivery node)

`make run-fleet` now wires this seed automatically: **alice → owner 0, bob → owner 1**
(and `make clean-peer PEER=<x>` re-seeds). The complete step-by-step — build, anvil,
launch, join/admit, propose, in-app Approve, Settle, and how each Settle outcome reads —
is the operator runbook: **`docs/two-instance-fleet-runbook.md`**. In brief:

1. `infra/anvil/devnet.sh` — anvil + the MiniSafe at `0x5FbDB…` funded, owners 0/1/2.
2. `make run-fleet PEER=alice` and `make run-fleet PEER=bob` (auto-seeded as owners 0/1;
   override with `SEED=0x…`, or set `MUSTER_DEV_SECP_KEY` yourself on the plain `make run`
   path).
3. Both join the same room (alice admits bob); alice proposes a Safe payment; **each clicks
   Approve** — two in-app owner signatures fold to executable (2-of-3), no paste.
4. Alice clicks **Settle on-chain** → `coordinate_submit` assembles the `execTransaction`
   from the two folded owner signatures, submits through the RPC, and reads finality from
   the receipt. `checkSignatures` passes because both signers are real owners; the card
   reports the outcome honestly and reaches **paid** on a status-1 receipt (exo-837).

Single instance, no second peer: seed as owner 0, Approve in-app (owner 0), then **Paste a
signature instead** with owner 1's signature (the advanced fallback) → 2-of-3 executable →
Settle.

## What is verified where

- **Signing** (a seeded account signs Safe in-app as a real owner) — `safe_owner_seed_test`,
  headless (needs the secp nimble deps; runs in CI / `nix build`).
- **In-app approval counting** — the `muster-ui` harness "Safe approve signs in-app and
  counts the local owner", on the offscreen bake.
- **On-chain settlement** — the `coordinate_submit` path was already proven against live
  anvil (`coordinate_submit_anvil`); exo-001 makes the *signers* be the local in-app
  identities. The two-instance on-chain run above is the remaining live-infra check
  (anvil + delivery node), not runnable in a sandbox without them.
