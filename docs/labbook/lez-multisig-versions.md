# lez-multisig, nssa and LEE: three PDA schemes, one program binary (2026-09-24)

Context: Phase C (epic exo-a50.3) puts the vote locus on Logos's own chain through
`logos-co/lez-multisig`. Before building the live binding (exo-3c9), check which chain the
program can run on. The published program cannot run on the chain muster's `lez_core`
talks to.

## What is pinned where

| Thing | Pin | Chain core it speaks |
|---|---|---|
| `logos-co/lez-multisig` @ `c45100b` | `nssa_core` **v0.2.0-rc3**, `spel-framework` **v0.3.0** | nssa |
| muster's `lez_core` (runner) | `logos-execution-zone-module` @ `549cf11` (metadata 0.4.0) | LEZ **v0.2.2** |
| `lez_core` HEAD `825d2a4` (0.4.2) | LEZ **v0.2.5-rc2** | LEE, programs as accounts |
| testnet (`testnet.lez.logos.co`) | whatever `lez_core` 0.4.x targets | LEE v0.2.5 line |

## The PDA formula moved twice

Public PDAs are `SHA-256(prefix32 || program32 || seed32)` in every version, but the prefix
and the program's 32-byte identity changed:

| Version | Prefix | Program identity |
|---|---|---|
| nssa v0.2.0-rc3 (`nssa/core/src/program.rs`) | `/NSSA/v0.2/AccountId/PDA/` + 7 zero bytes | the image id (`[u32; 8]`) as LE bytes |
| LEZ v0.2.2 (`lee/state_machine/core/src/program/mod.rs`) | `/LEE/v0.2/AccountId/PDA/` + 8 zero bytes | the image id as LE bytes |
| LEE v0.2.5-rc2 (same file) | `/LEE/v0.2/AccountId/PDA/` + 8 zero bytes | the program's **account id** (programs are deployed as accounts) |

muster's `lez/multisig.nim` names the scheme on every account (`psNssa02`, `psLee02`).
`psLee02` covers both LEE versions, because the formula only takes 32 bytes; the config
says which program identity those bytes are.

## Why the program cannot just be deployed

The program's guest computes its own PDAs with the core it was compiled against (SPEL's
`compute_pda` calls `AccountId::for_public_pda` from its linked `nssa_core`). The chain
checks the accounts a transaction names against its own derivation. A guest built on
nssa rc3 therefore derives `/NSSA/...` addresses that a LEE chain will not match. The
program has to be rebuilt against the chain's core. That may be only a dependency bump
(SPEL is at v0.7.0), but it is an upstream change to `lez-multisig`, followed by a risc0
guest build (Docker) and a deployment (`send_program_deployment_transaction` in `lez_core`
0.4.2).

## What else the live binding needs

- `lez_core` **0.4.2** (bump from `549cf11`):
  - `send_generic_public_transaction(account_ids, signing_requirements, instruction,
    program_id, payer)`. The byte-string instruction IPC fix (`51eadfb`) and the `payer`
    argument (`0ea57f8`) are both after muster's pin.
  - `poll_transaction_status` (`aeb91ca`).
  - `get_account_public` for reading the state and proposal PDAs; the data is borsh.
- **Members must be fresh.** `CreateMultisig` requires every member account to be
  `Account::default()` (never used) and claims it for the program. A member's vote fee is
  therefore paid by a separate funded account of theirs (the `payer`). The in-process
  model enforces the same rule.
- **Instruction encoding.** The program's `Instruction` is a serde enum, so the
  instruction words follow the risc0 serde encoding. Pin this against a real sequencer
  before trusting it.
- **A local chain is possible on this box.** `logos-scaffold` (`lgs setup`) builds a LEZ
  v0.2.2 localnet (see `atomic-swaps-toolchain-on-fedora.md`), which is enough once the
  program is rebuilt for that core.

Until then, Phase C runs against `FakeLezMultisig` (`lez/multisig_chain.nim`), which
reproduces the handlers of `c45100b` with their own messages, over borsh accounts.

## Update: what the live testnet runs, and the rebuild (2026-09-24)

- **The testnet is on the v0.2.2–v0.2.4 line.** This was probed read-only on
  `testnet.lez.logos.co`:
  - `getProgramIds` returns `[u32; 8]` image ids (amm, authenticated_transfer, pinata,
    privacy_preserving_circuit, token);
  - `getProofsAndRoot` exists (v0.2.2+);
  - `getFeeState` does not (v0.2.5);
  - `getProofForCommitment` does not (v0.2.0).

  Its PDAs are `/LEE/v0.2/…` over the **image id**. That is muster's `psLee02` with the
  config's program set to the image id bytes. v0.2.5's programs-as-accounts is not live
  yet.
- **SPEL v0.7.0 targets LEZ v0.2.4**, so the rebuild targets v0.2.4. It lives in a local
  clone, `~/Github/corpetty/lez-multisig`, on branch `feat/lee-v0.2.4`:
  - dependencies ported (nssa → `lee_core` / `lee` aliases, SPEL v0.3.0 → v0.7.0, Rust
    1.94.0);
  - `multisig_state` PDA-checked on every instruction (as upstream #43 does);
  - **the #40 fix from draft PR #41**: a proposal commits `target_account_ids` and execute
    binds them.

  The 29 program unit tests pass, including #41's substituted-account regression.
  The host crates are ported too:
  - the FFI: `WalletCore::from_env()` is async now, and the IDL/client regenerate with
    `spel-client-gen` v0.7.0;
  - the e2e suites.

  **Both of lez-multisig's own e2e suites pass on a local v0.2.4 sequencer:**
  - `e2e_multisig`: create a 2-of-3; initialize the vault through a ChainedCall into the
    token program; fund it; propose, approve and execute a transfer;
  - `e2e_member_management`: add a member, change the threshold, remove a member, and the
    N < M guard;
  - a new step in `e2e_multisig`: an execute that substitutes the recipient is refused
    **by the program on chain** ("Target account 1 does not match the approved
    proposal").

  The guest's ImageID is `2ced3d30…d4c7`.
- **Muster models both builds.** `ProposalLayout`: `count-only` is the published
  c45100b, where the card names #40. `account-ids` is the rebuild, where the ids are
  checked on the S5 re-read and the card names no bypass. An account's config names its
  layout. The test is `lez_multisig_rebuilt_test`. Its §5 holds muster to **real chain
  bytes**: the state and both proposals read back from that sequencer after the e2e run
  (`module/tests/vectors/lez-multisig-v024/`). Muster:
  - decodes them under `account-ids` and re-encodes them byte for byte;
  - derives the state, proposal and vault PDAs the chain used (`psLee02` over the image
    id).
- **Build notes.** The v0.2.4 `wallet` crate pulls in Keycard support
  (`keycard-rs` → `pcsc-sys`), which needs libpcsclite, and `openssl-sys` needs OpenSSL
  headers. On this box both come from Nix: `PKG_CONFIG_PATH` points at
  `nixpkgs#pcsclite.dev` and `nixpkgs#openssl.dev`, and the Nix `pkg-config` wrapper
  searches only that path. The stale upstream `Cargo.lock` pins `hybrid-array` 0.4.10
  against `k256` 0.14's `^0.4.12`, so regenerate it. The guest builds with
  `cargo risczero build` (cargo-risczero 3.0.5, installed into a scratch root) inside the
  `risczero/risc0-guest-builder:r0.1.91.1` image, the tag LEZ v0.2.4's Justfile pins.
  **`RISC0_DOCKER_CONTAINER_TAG=r0.1.91.1` is what selects that image.** Without it,
  risc0-build 3.0.5 falls back to `r0.1.88.0`, whose rustc 1.88 cannot build the v0.2.4
  tree (`ruint` needs 1.90). The rzup-installed Rust version does not choose the image;
  upstream CI hit this exactly.
  risc0-build still asks rzup which Rust the guest targets, so answer it with an empty
  `$RISC0_HOME/toolchains/r0.1.91.1-risc0-rust-x86_64-unknown-linux-gnu` marker rather
  than installing a second toolchain. `cargo check --workspace` needs
  `RISC0_SKIP_BUILD=1`, because the methods crate otherwise builds the guest on the host.
  The sequencer (`--features standalone`) links RocksDB, whose bindgen needs libclang:
  set `LIBCLANG_PATH` to `nixpkgs#libclang.lib` and pass its resource headers through
  `BINDGEN_EXTRA_CLANG_ARGS`. It also runs genesis in risc0's executor, which needs
  `r0vm` 3.0.5 on `PATH`. Without it genesis panics with a bare "No such file or
  directory".

## Deployed to the testnet (2026-09-24)

- **The testnet is v0.2.4.** Its five built-in program image ids (amm,
  authenticated_transfer, pinata, privacy_preserving_circuit, token) equal a v0.2.4 build's
  byte for byte. v0.2.4's wallet also defaults to `https://testnet.lez.logos.co`.
- **The rebuilt program is deployed there.**
  - ImageID (its program id): `2ced3d301a4d1cd5db6cad9c428b9f3463155073f8bacf73179c6ea6536de4c7`.
  - Deploy transaction: `61a7abe2…faa0`, in block 23405.

  A program deployment is unsigned (bytecode only) and its hash is the bytecode's, so the
  same build deploys to the same id anywhere. The sequencer drops a failing deployment at
  block production, so inclusion is the proof that the program is on chain.
- **lez-multisig's `e2e_multisig` passes against the testnet itself**
  (`SEQUENCER_URL=https://testnet.lez.logos.co BLOCK_WAIT_SECS=60`):
  - the vault is initialized through a ChainedCall into token, then funded;
  - a proposal is made and approved;
  - an execute that **substitutes the recipient is refused on the live chain**;
  - the approved execute lands, leaving the vault at 300 and the recipient at 200.

  Testnet blocks are about 35–40s apart, so the suite's old 15s block wait gave up on
  transactions that did land.
- **Upstream:** [logos-co/lez-multisig#45](https://github.com/logos-co/lez-multisig/pull/45)
  covers the port, #41's fix, CI on v0.2.4, and the testnet deployment in the README. It
  supersedes #41.
  - **Its CI is green** on unit, check and E2E; E2E runs against a freshly built v0.2.4
    sequencer. That also fixes upstream `main`, which had been red since July: the
    circuits installer script it curled was gone, and the circuits now arrive as a cargo
    git dependency.
  - **CI's independent guest build reproduces the deployed ImageID** (`2ced3d30…d4c7`),
    so the testnet program is verifiably the PR's source.
  - The PR awaits a maintainer review; the repo requires one to merge.
- **Muster reads the testnet deployment.** `lez_multisig_rebuilt_test` §5 decodes the
  testnet multisig's state and both proposals (`module/tests/vectors/lez-multisig-testnet/`),
  re-encodes them byte for byte, derives their PDAs, and accepts the multisig as a room
  account on `lez:testnet`. A room discloses a testnet multisig with this config:

  ```json
  {"program": "2ced3d301a4d1cd5db6cad9c428b9f3463155073f8bacf73179c6ea6536de4c7",
   "createKey": "<the multisig's create key, hex>", "pda": "lee-v0.2", "layout": "account-ids"}
  ```
- **What the live binding (exo-3c9) still needs:**
  - a `lez_core` that can send a generic public transaction to this program on the v0.2.4
    line;
  - the multisig `Instruction` in risc0 serde words. The e2e builds these with
    `Message::try_new`, which gives muster a reference encoding to pin its own against.

  "Why the program cannot just be deployed" above is resolved.

## The live binding (2026-09-25, exo-3c9)

- **Why muster signs, not `lez_core`.** muster's pin, lez_core 0.4.0 at `549cf11` (LEZ
  v0.2.2), has `send_generic_public_transaction`, but its instruction argument is a
  `std::vector<uint32_t>`. The module's header→LIDL generator turns that into an opaque
  `any`, and QtRO silently drops every argument across the process boundary. Upstream fixed
  it in `51eadfb` (a byte string of LE words), but it ships only in lez_core 0.4.1+, which
  targets LEZ **v0.2.5 release candidates**, while the testnet runs **v0.2.4**. So muster
  builds the member's transaction itself (`lez/tx.nim`, held to vectors from LEZ's own
  crates) and signs it with the member's key from the keystore, as the in-app EVM and
  Bitcoin signers do. It then sends it to the user's own sequencer over JSON-RPC
  (`wallet/lez_multisig_live.nim`). A wallet-backed chain can slot in behind the same
  `LezMultisigChain` seam once lez_core can reach the program on the testnet's line.
- **The transaction** (v0.2.4):
  - the instruction is risc0 serde words: a byte is a word, a u64 two, a u128 four, a
    `Vec` its length then its items;
  - the message is borsh, hashed as SHA-256("/LEE/v0.3/Message/Public/" padded ‖ borsh);
  - signatures are BIP-340 over that hash, with the x-only key in the witness;
  - the account id is SHA-256("/LEE/v0.3/AccountId/Public/" padded ‖ x-only);
  - `sendTransaction` takes base64 of `0x00 ‖ borsh(tx)`, and the tx hash is SHA-256 of
    the tx borsh;
  - v0.2.4 has no fees, so the seam's `payer` is unused.
- **Member keys.** The program requires every member account to be fresh at create. The
  keystore derives one key per label: HMAC-SHA256(secret, "muster/lez-member-key/v1" ‖
  label ‖ counter). The hosted surface uses labels `lez-member/<i>` and recomputes which
  are ours from the keys, so nothing is stored (invariant 4).
- **Found on the chain:** the SPEL v0.7.0 rebuild's `CreateMultisig` asserts that members
  are fresh but does **not** claim them. Its own doc comment says it does; the chain shows
  them unowned. One member account can therefore sit in several multisigs until its first
  transaction.
- **Refusal = not included.** A transaction the program refuses is dropped at block
  production, and its reason is only in the sequencer log. Muster reads non-inclusion
  within 4 blocks as refusal.
- **Asynchronous.** A UI call to the module times out at 20s, and a testnet block is about
  40s. So every hosted LEZ step sends and returns at once (`waitForInclusion = false`). A
  pump driven by the `coordinate_intents` tick completes it once the chain includes it,
  through the split in `coordination/vote.nim`. Nothing is published before the chain has
  it: no intent before the proposal, no receipt before the vote, nothing final before
  Executed. A step not included in 10 minutes is dropped.
- **Verified.** `lez_multisig_live_e2e` §1–7 are green on a local v0.2.4 sequencer
  (`infra/lez/localnet.sh`), and §1–6 against the **public testnet**. In both, the room
  drove the deployed program:
  - create a 2-of-3, mint a token;
  - #1, the vault setup: the proposer's own Propose, then Bob's own Approve after an S5
    re-read, then settlement counting the votes on chain and Executing;
  - fund the vault;
  - #2, a transfer: a substituted recipient is refused on the live chain, then the
    transfer settles;
  - §7 repeats the flow asynchronously.
  The hosted module and the UI build as `.lgx`.
- **Not yet.** The on-display render in a runner. A room of two instances doing it over
  the live wire. A proposal's account list is still hand-built by the composer (transfer
  / vault setup) or given as raw JSON (`coordinate_propose_lez`).
