# module/src/lez/

Logos Execution Zone *programs*, as muster reads and drives them (Phase C, epic exo-a50.3).
The LEZ *wallet* rails (public / shield / deshield / private transfers) live in
`module/src/wallet/lez_*.nim`. This directory is about programs the room coordinates:

- `multisig.nim`: logos-co/lez-multisig's on-chain objects.
  - `MultisigState` and `Proposal` in the program's borsh layout, in two named proposal
    layouts: `count-only` for the published c45100b, and `account-ids` for the rebuild with
    the #40 fix, which is what the testnet runs.
  - SPEL seeds and the chain's public-PDA formula, **versioned**:
    - `psNssa02` for nssa v0.2.0-rc3;
    - `psLee02` for the LEE v0.2.x line, over the program's image id: v0.2.2–v0.2.4, which
      is the testnet.
  - The program's voting rules.
- `multisig_chain.nim`: the chain seam muster needs (`readAccount` / `submit(signer, op,
  payer)` / `txIncluded`).
  - It is also a `ChainAdapter`, so the settlement seam can hold it.
  - `FakeLezMultisig` reproduces the program handlers with the program messages, over borsh
    accounts at their PDAs. A refused transaction changes and charges nothing.
- `tx.nim`: a LEZ v0.2.4 public transaction as bytes.
  - The multisig instruction in risc0 serde words.
  - The borsh message and its domain-separated hash.
  - The BIP-340 witness set, the transaction hash, the `sendTransaction` payload, and a
    program deployment.
  - It is held to vectors that LEZ's own crates generated (`tests/vectors/lez-tx-v024`).

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
