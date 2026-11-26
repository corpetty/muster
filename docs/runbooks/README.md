# Runbooks

Repeatable scripts for demos and posts. Not specs — the specs are `docs/01-furps.md` and
`contracts/specs/`; these are how to *show* what the specs guarantee.

- [`ui-redesign-review.md`](ui-redesign-review.md): the by-hand review of the UI redesign (exo-720), done 2026-10-14 and kept for the next review of the UI. The new UI in the standalone app with two peers, card by card, then installed into a fresh Basecamp 0.3.2 from a catalogue served on this machine (`scripts/basecamp-local-catalogue.sh`). It ends with what to send back.
- [`install-from-catalogue.md`](install-from-catalogue.md): install Muster in Logos Basecamp 0.3.2 from Muster's own catalogue. Add the URL, install from Applications, untick the full Monero node, and read what adding the catalogue trusts. These are the stranger-facing steps the campaign page reuses. The maintainers' section tests a release from a local https server.
- [`macos.md`](macos.md): build and check Muster on a Mac (Apple Silicon). The two packages
  with Nix, installed with their Logos Official dependencies into a Basecamp 0.3.2 profile;
  a headless check with `logosctl`. For maintainers and acceptance
  (`docs/design/platforms.md`).
- [`basecamp-fresh-install.md`](basecamp-fresh-install.md): Muster in a fresh Basecamp,
  nothing seeded. Two people, each on their own machine, set up an account and chains, make
  a room, and split a bill on Sepolia through the platform's Signer and sender. Written for
  Basecamp 0.3.1; its §1 on applies after installing from the catalogue.
- [`xmr-payment-request.md`](xmr-payment-request.md): request XMR in a room. The payee's own
  Monero wallet mints the address and confirms the payment; the payer pays from any wallet
  through a `monero:` link or QR. Stagenet. The payment and confirmation steps have not yet
  been done with a real payment, and are marked.
- [`xmr-multisig.md`](xmr-multisig.md): three people set up a 2-of-3 Monero multisig in a room and spend from it, each with their own `monero-wallet-rpc` holding their key (ADR-020). Stagenet. Each step ran on regtest with real wallets, and the whole runbook ran on stagenet through the UI on 2026-10-17.
- [`client-tour.md`](client-tour.md) — try everything by hand, two instances on one
  machine. `scripts/try-infra.sh up` brings up every local chain it uses, funded (anvil
  with the real Safe and an ERC-20; Bitcoin Core on regtest with a miner), and
  `scripts/try-peer.sh` launches each peer seeded for them. Then: rooms that name
  nobody, chat authorship, a signed decision and its audit trail, a Safe settled on
  chain, a Bitcoin multisig with a signer outside muster and a FROST key, splitting a
  bill (ETH, a token, for someone else, another currency, settle up, Bitcoin, and the
  private split on the LEZ testnet), a request for XMR (it needs Basecamp, and points to
  `xmr-payment-request.md`), the LEZ multisig and LEZ FROST, the wallet, and the
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
