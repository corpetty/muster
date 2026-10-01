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
- **Fees.** Private transactions pay none: a privacy-preserving message has no fee field
  ("fee-exempt under the interim policy", `lez/sequencer/core/src/fees.rs`). Every public
  transaction declares
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
7. **muster's fee estimate was v0.2's**: a flat 1_000_000 base units on every rail. On v0.3
   a privacy-preserving transaction (a shield, a deshield, a private transfer) carries no
   fee field and pays none — "fee-exempt under the interim policy", in the sequencer's
   `fees.rs` — while a public one pays up to its declared cap. `LezAdapter.estimateFee` now
   says so (L5). An earlier version of this entry, and the descriptions of #202 and #203,
   said the funding autopilot's full-balance shield leaves nothing for the fee. It does
   not: a shield is a privacy-preserving transaction, so it pays no fee.
8. **A refused call is included, and pays.** On v0.2.4 the sequencer dropped a transaction
   whose program refused it, so "included" meant "took effect". On v0.3 it is included: the
   action reverts, the reserved fee is kept and the signers' nonces are burned
   (`lez/chain_state/src/apply.rs`, `settle_charged_transaction`: "a failed action is
   ordinary execution semantics"). The sequencer's RPC reports no outcome — `getTransaction`
   returns the transaction and its block, nothing more; events live only in the separate
   indexer, and a reverted call emits none. So a step is judged by the state it should have
   changed, never by inclusion or a nonce. The v0.3 multisig e2e does this for every step;
   an outsider's refused vote cost it 16,003,672 base units. muster's FROST `lez-call`
   settlement still treats inclusion as final (exo-53a).
9. **A program's chained call selects only the transaction's own rows.** A v0.3 program
   that calls another (the multisig's Execute calling the native token program) must list
   the callee's rows in its own transaction; a selector the transaction did not carry is
   refused. So Execute's rows are the state, the proposal, then the call's rows in order.
10. **A v0.3 program is deployed in pieces.** `program_loader` takes the guest's user ELF in
   96 KiB segments, one fresh account each, then a header account that names them; the
   header's id is the program's account id, and every PDA is derived from it, not from
   the image id. `infra/lez/localnet.sh deploy <prog.bin>` does this through LEZ's CLI.

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
- **L5, its local half**: the private split end to end on a local v0.3.0 zone
  (`LEZ_SPLIT_ZONE=local scripts/split-lez-testnet.sh`): B names its account, the funder
  funds it, B shields it to its own key node (fee-exempt), agrees, and pays its share
  shielded → shielded; A's own scan finds a note of exactly that share, final on both in
  about 50 s with dev-mode receipts. The private rails, the scan and a received note's key
  node and amount all hold on v0.3's 256-bit private ids. Real proving on v0.3 and the
  live testnet remain (they need native LEZ from someone who holds it).
- **L4c**: the lez-multisig program, rewritten for v0.3's `run_program(plan, apply)` (no
  SPEL), deployed on a local v0.3.0 zone with `localnet.sh deploy`, runs its own e2e there
  (`e2e_v03` in the port's workspace): create a 2-of-3, fund its vault by transfer,
  propose a native transfer out of it, approve, execute — R holds the amount, the vault
  that much less; refused, with nothing changed: an outsider's vote, a substituted
  recipient, a second multisig naming this vault's seed, and a second Execute.

Sources: logos-execution-zone v0.3.0 (`lee/state_machine/src/{public_transaction,fees.rs}`,
`lee/state_machine/core/src/{account.rs,native_token.rs,program/mod.rs}`,
`lez/wallet/src/{lib.rs,config.rs}`), logos-execution-zone-module `b89e5d2`
(`src/lez_core_module.{h,cpp}`).
