# lez-msig on LEZ v0.4.0-rc3: traps found the expensive way (exo-0d3.9)

*2026-11-20. Roadmap M1 (the devnet runs v0.4.0-rc3). Code: `programs/lez-msig/lez04`,
`module/src/lez/tx.nim` (`LezMessage4`), `module/src/wallet/lez_msig_chain.nim`,
`infra/lez/{localnet,funder}.sh`.*

1. **risc0-zkvm 3.0.5 is yanked.** A fresh resolve picks 3.1.0, which does not build with LEZ
   (`risc0-zkos-v1compat`). Seed both the host's and the guest's `Cargo.lock` from LEZ rc3's own
   lockfile.
2. **The sequencer is set up, then started.** `sequencer_service setup <home> --config
   networks/local.json --funding-public-key <key> --create-channel`, then `start <home>`. A
   second instance on the same port fails to bind, but the RPC check still passes against the
   first one: stop stray sequencers before starting.
3. **The wallet encrypts its storage.** It reads the password from `LEE_WALLET_PASSWORD`; without
   it, it prompts on a terminal (`os error 6` with none).
4. **A public account no one has used must be admitted.** A transaction that declares it fails
   ("declared public but not admitted") unless it carries evidence: the account's **key**, or
   for a PDA its (program, seed). Consequences:
   - funding a fresh account takes its public key (`wallet auth-transfer send --to-pk`,
     `funder.sh fund <id> <amount> <key>`);
   - a lez-msig Create on a public PDA carries `Pda { program, seed }` evidence;
   - a payee no one has used is **left undeclared**, and its credit waits as a pending message
     it claims. The wallet does the same. Declaring it would refuse the whole transaction.
5. **A payment's credit is an async message.** It lands in the same transaction only when the
   payee is a declared public actor. A test that reads the payee's balance needs a payee that
   exists.
6. **The account view renamed shards to actor states.** `getAccount` answers
   `{nonce, data: {actor_states: {<program>: [bytes]}}}`, or `null` for an account no one has
   used. The native balance is still the native program's 16 little-endian bytes.
7. **The message changed shape; the hash and wire form did not.** On 0.4 the message carries:
   - a public context: the actors (a set), the authorized accounts (the nonces' accounts) and
     the promotions;
   - the root call, then an optional fee;
   - a nonce map;
   - the admission evidence.

   The hash is still SHA-256 under `/LEE/v0.3/Message/Public/`, and `sendTransaction` still
   carries base64 of `0x00 ‖ borsh(tx)`. Held to vectors from LEZ's crates
   (`tests/vectors/lez-msig/v04.json`).
8. **The lez-msig envelope is unchanged for the public posture.** `create_key ‖ 0 (Public) ‖ op`
   is the same bytes as on v0.3, so the room's proposals and approvals carry over. A private
   PDA's placement loses its identifier, so private addresses change (D13).
9. **A refused transaction burns its whole declared gas.** Measured on a local 0.4.0-rc3 zone at
   base fee 8 (exec and storage), the public posture:

   | step | what the payer paid |
   |---|---|
   | Create (2-of-3) | 834,360 (fits a 110k gas limit) |
   | Execute, 2 approvals, a payment | 4,657,224 (about 580k gas) |
   | Execute refused below threshold, gas limit 4M | 32,006,640: the whole limit × 8, plus storage |

   The sequencer refuses a `max_fee` below the fee reserve, which is about the gas limit × the
   base fee ("max_fee 400000 below the fee reserve 8005280" for a 1M limit). A refusal then costs
   the whole reserve. So Muster has to declare a gas limit close to what a step uses: under v0.3's
   wallet default (2M gas), every refusal costs about 16M. The sequencer has no simulate call
   (LEZ's wallet simulates by running the program itself), so Muster declares a per-step limit
   from a model fitted to what each step meters on LEE's own state (exo-50c,
   `module/src/lez/msig_gas.nim`, vectors from `lez04/host/tests/v04_gas.rs`):
   - each approval or executor signature is a BIP-340 verification in the guest, about 275k
     cycles: a 2-of-3 Execute meters about 580k, a 10-of-10 about 2.78M;
   - a config change costs about 29k more per member; Create about 30k per member;
   - ExecuteQueued carries no signatures, about 30k;
   - the fee cap is the reserve at twice the next block's base-fee ceiling (`getFeeState`).

   Whether the payer must also hold the whole reserve was not tested.
10. **The devnet makes a block about a minute apart**, irregularly (0.4.0-rc3 devnet,
    2026-11-20). A local zone makes one every 15 s. Waits sized for a local zone time out there.
11. **On the devnet** (2026-11-20), the program deployed immutable at
    `2tTh5nUpBxtTAoQBCQbzmG32JGapm2KaEpH9oxktGanG` (hex `1c0a7ce6…8170d`); the deploy cost about
    8.6M. `live_public04` passed there with a 700k gas limit:
    - Create 834,360;
    - an Execute refused below threshold 5,606,640: the whole limit, again;
    - a 2-of-3 Execute that paid 4,687,312.
12. **Muster's room drives it on the devnet** (2026-11-20, exo-50c): `lez_msig_live_e2e` passed 7/7
    against the deployed program, every step under its own gas limit (`lez/msig_gas.nim`): the
    ceremony, Create, a 2-of-3 payment, R.2's stale epoch, a queued time-locked payment, nothing sent
    below threshold, a multisig over a member's disclosed account. Run with
    `MUSTER_LEZ_VERSION=v0.4.0-rc3 MUSTER_LEZ_E2E_FUND=50000000 MUSTER_LEZ_E2E_WAIT_SCALE=4
    TEST_TIMEOUT=5400 MUSTER_LEZ_MSIG_PROGRAM=1c0a7ce6…8170d TEST_ARGS=http://46.225.45.199:3040
    module/tests/run-suite.sh e2e lez_msig_live`; about 25 minutes at a block a minute, so the
    suite's default 900 s budget cuts it off in step 7. `funder.sh` must run the 0.4 wallet
    (`MUSTER_LEZ_VERSION`): the v0.3.0 one fails a deploy on a v0.4 zone at its first segment,
    reading a fresh account's `null`.
13. **The private posture on the devnet** (2026-11-21, exo-05f): `live_private04` passed with real
    proofs against the immutable program, every proof naming no program (D18):
    - a top-up of the group's fee account (104 s to prove, 229 KB);
    - Create at the private PDA (257 s);
    - a deposit (233 s);
    - 1 of 2 refused while proving, nothing sent;
    - a 2-of-3 payment to a public payee (292 s).

    Each fee was 5,704,443 in the proof; the funder spent about 34.2M on the run. Run with
    `CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true cargo test --release -p msig_host04 --test
    live_private04 -- --nocapture` and `MSIG_LIVE_WAIT_S=900`. A test enables LEE's test-utils
    through its dev-dependencies, and LEE refuses them in a release build unless debug assertions
    are on. Those assertions make proving about 38% slower than `msig_bench04`'s figures.
14. **Muster's room drives the private posture on 0.4** (2026-11-21, exo-05f): `lez_msig_private_e2e`
    passed 9/9 on a local 0.4.0-rc3 zone through `msig_exec04` (lez04's executor, the same JSON as
    v0.3's plus `feeNote` / `feePost` / `topup`). The group's fee account has its own notes in the
    room (`lmsig/<ck>/feenote/<n>/<who>`), numbered apart from the vault's: a top-up changes only
    the fee note, every other step both. A member who lost both recovers both from the chain.
    Run with `MUSTER_LEZ_VERSION=v0.4.0-rc3 RISC0_DEV_MODE=1 MUSTER_LEZ_MSIG_PROGRAM=<hex>
    module/tests/run-suite.sh e2e lez_msig_private`, after `cargo build --release -p msig_host04
    --bin msig_exec04` in `programs/lez-msig/lez04`. Hosted in Basecamp it still needs the
    `lez_msig_module` rebuilt from lez04.
