# Runbooks

Repeatable scripts for demos and posts. Not specs — the specs are `docs/01-furps.md` and
`contracts/specs/`; these are how to *show* what the specs guarantee.

- [`client-tour.md`](client-tour.md) — try everything by hand, two instances on one
  machine. `scripts/try-infra.sh up` brings up every local chain it uses, funded (anvil
  with the real Safe and an ERC-20; Bitcoin Core on regtest with a miner), and
  `scripts/try-peer.sh` launches each peer seeded for them. Then: rooms that name
  nobody, chat authorship, a signed decision and its audit trail, a Safe settled on
  chain, a Bitcoin multisig with a signer outside muster and a FROST key, splitting a
  bill (ETH, a token, for someone else, another currency, settle up, Bitcoin, and the
  private split on the LEZ testnet), the LEZ multisig and LEZ FROST, the wallet, and the
  walkthrough. Marks the steps no one has yet done on screen, and the known rough edges.
  Each built action in the atlas links to its part.
- [`transaction-lifecycle-demo.md`](transaction-lifecycle-demo.md) — a live, step-by-step
  demo of the whole transaction lifecycle (compose → propose → review → contribute →
  submit → final), with the provenance / proof / flow dive-ins and a claim→surface
  cheat-sheet. For a talk, a recording, or a written walkthrough.
- [`explaining-muster.md`](explaining-muster.md) — the concepts to narrate over that demo
  and write posts from: what Muster is built to do, data provenance (captured thoroughly +
  validatable), information leakage across the lifecycle, and the PriFi credibility
  narrative. Ends with a claim→surface fact-check.

Related setup runbooks: [`../two-party-demo-runbook.md`](../two-party-demo-runbook.md)
(Safe + FROST, two participants), [`../two-instance-fleet-runbook.md`](../two-instance-fleet-runbook.md)
(two instances over the live fleet).
