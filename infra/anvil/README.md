# infra/anvil — the Safe fixture (the real Safe v1.4.1)

`devnet.sh` starts anvil and deploys the **real Safe v1.4.1** from
`safe-global/safe-smart-account` at the pinned tag (fetched into `lib/`, built with
solc 0.7.6 — the release compiler — into `out-safe/`, both gitignored): the Safe
singleton, `SafeProxyFactory`, `CompatibilityFallbackHandler`, then a **2-of-3 proxy
owned by anvil accounts 0/1/2**, funded with 5 ETH. On a fresh anvil the addresses are
deterministic; the Safe is `0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841` (the module's
local test Safe suggestion, `describe()`).

It replaced `MiniSafe` (exo-a50.1.4), a four-argument subset the real Safe does not
have. Against the real contract, muster's `safeTxHash` for a transaction using every
field (data, DELEGATECALL, the gas fields, gas token, refund receiver) equals the
Safe's own `getTransactionHash`; settlement uses the real ten-argument
`execTransaction`; the account check reads `getOwners` / `getThreshold`; and the ways
around the threshold are read (`getModulesPaginated`, the guard slot).

## Run it

```bash
nix shell nixpkgs#foundry     # anvil / forge / cast (or any foundry install) + jq + git
infra/anvil/devnet.sh         # prints SAFE_ADDR / RPC
```

In a room, a member **discloses** the Safe (Accounts → **Disclose the local test
Safe**) before a Safe payment can act from it — accounts live in the room, disclosed by
members (exo-a50.1.3).

## The on-chain tests (collect 2-of-3 off-chain, execute on-chain, no indexer)

Each expects a FRESH Safe (nonce 0) — re-run `devnet.sh` on a fresh anvil between them.
Put the secp closure on the path first (see `module/tests/README.md` for `$SECP`).

```bash
cd module
nim r -d:release --threads:on $SECP tests/safe_anvil_e2e.nim        0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841
nim r -d:release --threads:on $SECP tests/coordinate_submit_anvil.nim 0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841
nim r -d:release --threads:on $SECP $SODIUM tests/safe_real_anvil_e2e.nim 0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841
```

Verified 2026-09-23 against Safe v1.4.1: all three OK. A successful `execTransaction`
is itself proof that muster's local safeTxHash matched the contract's — the Safe
reverts otherwise; `safe_real_anvil_e2e` additionally compares against
`getTransactionHash` directly, for every field.
