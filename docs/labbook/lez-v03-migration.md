# LEZ v0.3: what changed for muster, and the traps on the way (2026-10-01)

The public LEZ testnet (`testnet.lez.logos.co`) was reset to **LEZ v0.3.0** on 2026-09-30.
This is the record of moving muster onto it (epic exo-eb6.4): what v0.3 changed that muster
depends on, and each trap, with where it is fixed. L1–L3 are done; L4 (the multisig
program) and L5 (live testnet runs) are not.

## What v0.3 changed, for muster

- **No faucet.** The pinata program is gone. Native LEZ reaches an account at genesis,
  over the bridge, or by a transfer from an account that holds some. `lez_core` 0.5.0
  drops `claim_pinata*`, `register_public_account` (a fresh public account is claimed by
  its first funded transfer) and the vault calls. muster dropped all of them (L1).
- **Fees.** Every public transaction declares
  `Option<FeeDeclaration { payer, gas_limit: u64, tip: u64, max_fee: u128 }>`, inside the
  signed message; the payer signs like any signer, and a co-signing payer's nonce goes
  after the others. The LEZ wallet's default is gas 2_000_000, tip 0, max_fee
  `(gas + 100_000) × 64` = 134_400_000. A plain native transfer was charged **2_968**; a
  co-paid one 3_864. The payer must be able to cover `max_fee`; the rest is refunded.
- **The public message.** The hash is still `SHA-256("/LEE/v0.3/Message/Public/" padded ‖
  borsh)`, but the message is now `{program_account_id, shard_selectors, nonces,
  instruction_data: Vec<u8> (borsh of the instruction), fee}`. A program is called by an
  account id; each row names which program's shard of it the call sees. The native
  token program is account 0 (`"1111…"` in base58), and its instruction is borsh
  `Transfer { amount: u128 }`. Account ids are derived exactly as before.
- **Accounts.** `getAccount` returns `{nonce, data: {shards: {<program, base58>: bytes}}}`.
  The native balance is the 16-byte little-endian shard of the native program; there is no
  single owner or data any more (`lez/account_view.nim` reads both lines).
- **Program deployment** is no longer a transaction variant: it goes through
  `program_loader` (segment accounts plus a header account), and the deployer pays.

## Traps

1. **`lez_core` opens a wallet once and has no close.** `open()` refuses a second time, so a
   config edited after `create_new` never reaches the wallet in memory: a new wallet kept
   reading the public testnet's balances while its config named the local zone. A new
   wallet on another zone now gets `lez_core`'s own default config, pointed there, written
   *before* `create_new` reads it (`lez_encoding.newWalletConfig`, `lez_lp.nim`).
2. **LEZ's CLI checks in with a sequencer before any command**, even `account new public`,
   and the genesis that funds an account must name it first. `infra/lez/localnet.sh` makes
   the funder's account once on a throwaway chain from LEZ's debug config.
3. **v0.3 logs no "RPC server started".** The local zone is detected by its RPC answering.
4. **A backgrounded `cd && nohup …` list holds a caller's `$(…)` pipe open**, so the
   script hung forever after the sequencer started. The sequencer is now exec'd from a
   redirected subshell.
5. **`nix build nixpkgs#gcc` prints two store paths** (the wrapper and its man page), which
   broke `PATH`. Ask for `'nixpkgs#gcc^out'`. A binary built with that gcc also needs nix's
   `libstdc++` on its rpath or `LD_LIBRARY_PATH` (`'nixpkgs#gcc.cc^lib'`).
6. **The CLI links Keycard support** (`pcsc-sys`), so it needs `libpcsclite` and
   `pkg-config` to build and run.
7. **muster's fee and funding assumptions were v0.2's.** The `MUSTER_AUTOLEZFUND` autopilot
   shields the whole public balance, which leaves nothing for v0.3's fee, and muster's LEZ
   fee estimate is still a v0.2 constant. Both are L5's (exo-357).

## What is verified, and where

- **L1**, live on the v0.3 testnet: `lez_core` 0.5.0 creates a wallet's accounts and reads a
  balance; `wallet_lez_setup()` names the account to fund.
- **L2**, on a local v0.3.0 zone: the funder sends, and muster reads the exact amount
  through `lez_core` (`scripts/lez-local-self-test.sh`).
- **L3**: the v0.3 encoder is held to vectors from LEZ v0.3.0's own crates
  (`tests/vectors/lez-tx-v030`, `lez_tx_v030_test`). On the local zone a FROST key owns an
  account and pays its own fee, a keystore member can co-sign as its fee payer, and a
  wrong aggregate moves nothing (`lez_frost_v030_e2e`). The room path runs end to end with
  a `lez-call` v2 effect: ceremony, propose at a chain-read nonce, two rounds, one
  aggregate signature landed, a stale nonce refused at settle (`lez_frost_room_v030_e2e`).

Sources: logos-execution-zone v0.3.0 (`lee/state_machine/src/{public_transaction,fees.rs}`,
`lee/state_machine/core/src/{account.rs,native_token.rs,program/mod.rs}`,
`lez/wallet/src/{lib.rs,config.rs}`), logos-execution-zone-module `b89e5d2`
(`src/lez_core_module.{h,cpp}`).
