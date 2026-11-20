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
