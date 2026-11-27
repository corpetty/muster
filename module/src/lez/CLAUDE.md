# module/src/lez/

Logos Execution Zone *programs*, as muster reads and drives them (Phase C, epic exo-a50.3).
The LEZ *wallet* rails (public / shield / deshield / private transfers) live in
`module/src/wallet/lez_*.nim`. This directory is about programs the room coordinates:

- `multisig.nim`: logos-co/lez-multisig's on-chain objects.
  - `MultisigState` and `Proposal` in the program's borsh layout, in three named proposal
    layouts: `count-only` for the published c45100b; `account-ids` for the rebuild with
    the #40 fix, which the v0.2.4 testnet ran until its reset to LEZ v0.3 on 2026-09-30; and
    `v0.3` (`plV03`), the port to v0.3's `run_program(plan, apply)` ABI
    (`docs/design/lez-multisig-v03.md`, vectors `tests/vectors/lez-multisig-v030`), run on a
    local v0.3 zone.
  - SPEL seeds and the chain's public-PDA formula, **versioned**:
    - `psNssa02` for nssa v0.2.0-rc3;
    - `psLee02` for the LEE v0.2.x line, over the program's image id: v0.2.2–v0.2.4, the
      testnet's line until 2026-09-30. The v0.3 port keeps v0.2.4's seeds and formula over
      the program's account id.
  - The program's voting rules.
- `multisig_chain.nim`: the chain seam muster needs (`readAccount` / `submit(signer, op,
  payer)` / `txIncluded`).
  - It is also a `ChainAdapter`, so the settlement seam can hold it.
  - `FakeLezMultisig` reproduces the program handlers with the program messages, over borsh
    accounts at their PDAs. A refused transaction changes and charges nothing.
- `msig.nim`: lez-msig's bytes (epic exo-0d3, `docs/design/lez-msig.md`).
  - The types its program stores and its members sign, their borsh, and the tagged hashes an
    approval covers.
  - The multisig's public PDA, and the card's decode of a proposal (RFP U.6).
  - It is held byte for byte to vectors the program's own host generates
    (`tests/vectors/lez-msig`). The rules are the program's (`programs/lez-msig/core`), not
    re-implemented here.
- `msig.nim` also reads a private payee on LEZ v0.4 (exo-ea3): `decodeRecipient` (lee_core::Recipient
  borsh, regular accounts only) and `recipientAddress` (its account id, blinded by its opening), held
  to `tests/vectors/lez-msig/v04-recipients.json` from LEZ's crates.
- `msig_gas.nim`: the gas limit and fee cap a lez-msig step declares on LEZ v0.4, where a refusal
  burns its whole limit (exo-50c). A model per step (signatures, members, config changes, a call's
  allowance), held above every step measured on LEE's own state (`tests/vectors/lez-msig/v04-gas.json`
  from `programs/lez-msig/lez04/host/tests/v04_gas.rs`) by `msig_gas_test`. Also a private
  multisig's fee account (exo-8ef): `privateReserve`, what the next private transaction takes from it
  (fee_core's private fee at getFeeState's ceilings, as the executor prices it), and
  `feeAccountStatus`, its balance from the newest fee note against that reserve.
- `quest.nim`: the quest record program's on-chain objects (exo-267.7, its source in
  `programs/lez-quest`, design `docs/design/lez-quest-program.md`): `QuestRecord` in its borsh
  layout, every instruction, and the record's PDA (psLee02). Held to vectors from the
  program's own crate (`tests/vectors/lez-quest-v010`).
- `quest_fake.nim`: the quest program's rules in process, plugged into `FakeLezMultisig`
  (`addProgram`), which carries an Execute's vault grant into the program's transfers as
  v0.3's executor does; `submitCall` / `readShard` are the seam's member call and another
  program's shard (exo-267.8).
- `tx.nim`: a LEZ v0.2.4 public transaction as bytes.
  - The multisig instruction in risc0 serde words.
  - The borsh message and its domain-separated hash.
  - The BIP-340 witness set, the transaction hash, the `sendTransaction` payload, and a
    program deployment.
  - It is held to vectors that LEZ's own crates generated (`tests/vectors/lez-tx-v024`).
  - The v0.3.0 message (`LezMessage3`) and the v0.4.0-rc3 one (`LezMessage4`: public actors, a
    nonce map, admission evidence), the latter held to `tests/vectors/lez-msig/v04.json` from
    LEZ v0.4's crates (`programs/lez-msig/lez04/host/src/bin/msig_vectors04.rs`). Traps:
    `docs/labbook/lez-v04-port.md`.

Rules:
- Every layout cites the upstream file and revision it was read from. A live chain is the
  arbiter: real chain bytes are vendored in `tests/vectors/lez-multisig-{v024,testnet}`.
- A partial or padded account is refused (`LezDecodeError`), never decoded as best-effort.
- The two PDA schemes never mix silently: an account names its scheme.
- Nothing here signs or touches the network. The live chain is
  `wallet/lez_multisig_live.nim`: the member's own key, held in the keystore like the
  in-app EVM and Bitcoin signers, signs the member's own transaction, and the user's own
  sequencer carries it (invariant 8). Plugins never sign (invariant 3). The room never
  holds a member's LEZ key.
