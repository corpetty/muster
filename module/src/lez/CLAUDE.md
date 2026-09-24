# module/src/lez/

Logos Execution Zone *programs*, as muster reads and drives them (Phase C, epic exo-a50.3).
The LEZ *wallet* rails (public / shield / deshield / private transfers) live in
`module/src/wallet/lez_*.nim`. This directory is about programs the room coordinates:

- `multisig.nim` — logos-co/lez-multisig's on-chain objects: `MultisigState` and
  `Proposal` in the program's borsh layout, SPEL seeds, and the chain's public-PDA
  formula, **versioned** (`psNssa02` for the published program on nssa v0.2.0-rc3,
  `psLee02` for LEE v0.2.5, which lez_core v0.4.2 speaks), plus the program's voting
  rules.
- `multisig_chain.nim` — the chain seam muster needs (`readAccount` / `submit(signer, op,
  payer)` / `txIncluded`), which is also a `ChainAdapter` so the settlement seam can
  hold it. `FakeLezMultisig` reproduces the program handlers with the program messages,
  over borsh accounts at their PDAs. A refused transaction changes and charges nothing.

Rules:
- Every layout cites the upstream file and revision it was read from. Upstream publishes no
  fixed-output PDA vectors, so a live chain is the arbiter (exo-3c9).
- A partial or padded account is refused (`LezDecodeError`), never decoded as best-effort.
- The two PDA schemes never mix silently: an account names its scheme.
- Nothing here signs or touches the network. A member's vote is their own LEZ transaction,
  and their LEZ wallet signs it through the chain seam, never muster (invariant 3).
