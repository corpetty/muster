# Muster

**Do things together, privately.** Muster is a local-first client for coordinating multi-party transactions inside conversations, built on the [Logos](https://logos.co) stack. The conversation is the security boundary: who is in the room determines who can read what is being done.

Muster's first mission is education — it walks people through the entire transaction lifecycle, showing at every step how the Logos stack maintains privacy and security, and where conventional stacks leak. The teaching client and the real client are the same client: everything demonstrated is enforced by running code, and the end goal is a usable application for coordinating with people securely and privately.

## What is actually here

The specified client now exists and runs. The Nim core (`module/`) and the QML UI (`ui/`) were built P0→P4: the whole transaction lifecycle runs in the UI against a real 2-of-3 Safe, and the room coordinates Bitcoin, LEZ and FROST multisigs too. A room can split a bill in ETH, a token, Bitcoin or privately on the LEZ, and can request a payment in XMR that the payee's own Monero wallet confirms. It runs inside Logos Basecamp on the platform's own keys and chains. The unit tests and invariant probes are green. Read the table before drawing conclusions from anything below it.

| | What it is | State |
|---|---|---|
| **[`module/`](module/) + [`ui/`](ui/)** | The specified client — a Nim core behind the `muster.lidl` contract (`muster-module.lgx`) and a QML frontend (`muster-ui.lgx`), hosted on logos-core | **Runs.** P0–P4 landed, plus the multisig families (Safe, Bitcoin PSBT, the LEZ multisig program, FROST), the split, and the XMR payment request; the full lifecycle (describe → propose → approve → submit) runs in the UI, standalone or in Basecamp. Unit tests and invariant probes green (`module/tests/run-suite.sh`) |
| **[`catalog/`](catalog/)** | Muster's own Basecamp catalogue: add one URL in Basecamp, then install Muster like any app ([steps](docs/runbooks/install-from-catalogue.md)) | Published: release [`muster-v0.2.0`](https://github.com/corpetty/muster/releases/tag/muster-v0.2.0) (2026-10-09), accepted on a fresh Basecamp 0.3.2. Linux x86_64 only |
| **[`demo/`](demo/)** | A one-week speed build of the simplest complete journey — one person pays another, coordinated inside a private conversation — composing Logos modules that ship today | **Runs.** Two peers, real payments on the LEZ testnet. Deliberately violates most invariants |
| **[`docs/`](docs/) + [`contracts/specs/`](contracts/specs/)** | The specification for the real client: vision, normative requirements, phase plan, the ten invariants as fourteen typed specs with acceptance oracles, and four more specs for features (the split, three; the XMR request, one) | Written, and now substantially implemented and probe-checked |
| **[The site](https://corpetty.github.io/muster/)** | What Muster is and why, on one page — the lifecycle, the invariants, what a room can do, what is still open — and the way into the diagrams and the atlas ([`site/`](site/)) | Published at **<https://corpetty.github.io/muster/>** |
| **[`docs/diagrams/`](docs/diagrams/)** | The figure programme — mechanics, architecture, and where each stage of a transaction leaks | Published at **<https://corpetty.github.io/muster/diagrams/>** |
| **[The action atlas](https://corpetty.github.io/muster/atlas/)** | Every action a person can take in Muster — each multisig family and what it lets a room do, every room action, every wallet send — with who acts, what is signed, who learns what, and what Muster refuses ([`contracts/actions/`](contracts/actions/), [design](docs/design/action-atlas.md)) | Built actions generated from the code; candidates declared from primary sources |

The demo and the specified client are different codebases. The demo violates most of the invariants the real client holds, which is why it could exist in a week. It says so on itself, at length, in [`demo/README.md`](demo/README.md). Do not cite it as how Muster works — for that, read `module/`.

**Ten invariants, fourteen specs — the mismatch is deliberate.** `CLAUDE.md` numbers the invariants 1–10 (5b is explicitly *not* an invariant). Two invariants carry more than one spec. Invariant 5 (deterministic bytes on signing paths) is the dCBOR encoder and the domain-separated hash-input records. Invariant 10 (provenance) is the record itself, its wiring into the live room, and the audit file a member can download. One further spec pins the P4 host-return gate, which is a phase gate rather than an invariant. Ten, plus one, plus two, plus one, is fourteen. A retired spec — anonymous membership, ADR-015 — stays in [`contracts/specs/retired/`](contracts/specs/retired/) as the record of why.

## Start here

| If you want to… | Go to |
|---|---|
| **Install Muster in Logos Basecamp** | [`docs/runbooks/install-from-catalogue.md`](docs/runbooks/install-from-catalogue.md) — add Muster's catalogue, install from Applications (Linux x86_64, Basecamp 0.3.2; once `muster-v0.2.0` is published) |
| **Run the specified client from source** | [Below](#run-the-specified-client) — `make build`, then `make run`; [`module/README.md`](module/README.md) for the module alone |
| **Run the tests** | `module/tests/run-suite.sh` — every unit test and invariant probe in one command; [`module/tests/README.md`](module/tests/README.md) for the chain-bound ones |
| **Run the demo instead** | [`demo/RUNBOOK.md`](demo/RUNBOOK.md) — two peers on one machine, and the journey end to end |
| **Understand the argument** | [`docs/posts/01-the-pipeline-and-discovery.md`](docs/posts/01-the-pipeline-and-discovery.md), then the [diagram site](https://corpetty.github.io/muster/diagrams/) |
| **Know why Muster exists** | [`docs/00-vision.md`](docs/00-vision.md) — the lifecycle-as-curriculum framing, and the honesty rules that bind every surface |
| **Read what is being built** | [`docs/01-furps.md`](docs/01-furps.md) (normative, stable ids) and [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) (phases P0–P6, ADRs) |
| **See how a claim is held to account** | The ten invariants in [`CLAUDE.md`](CLAUDE.md), and their typed specs in [`contracts/specs/`](contracts/specs/) |
| **Read what went wrong** | [`docs/labbook/`](docs/labbook/) — traps found the expensive way, kept rather than tidied |

## Run the specified client

**Without building: install it in Logos Basecamp.** Add `https://raw.githubusercontent.com/corpetty/muster/main/catalog/logos-repo.json` under Settings → Package Repositories, then install Muster from Applications. Every dependency comes from the official Logos catalogue. The steps, and what adding a catalogue trusts, are in [`docs/runbooks/install-from-catalogue.md`](docs/runbooks/install-from-catalogue.md); after that, [`docs/runbooks/basecamp-fresh-install.md`](docs/runbooks/basecamp-fresh-install.md) sets up an account and chains. Muster appears there once release `muster-v0.2.0` is published and `catalog/index.json` is on `main`.

**From source.** Needs [Nix](https://nixos.org/download) with flakes. There are three ways in; all build through `cache.nix.logos.co` (the Makefile passes it for you).

**Standalone app — the easy path.** `logos-standalone-app` hosts the muster UI and `muster_module` directly; no basecamp, no package manager.

```bash
make build   # the slow first build — pre-builds the runner (minutes); do this once. Memory-capped by BUILD_MEM (`make help` shows this host's cap)
make run     # launch: the lifecycle dashboard (propose → approve → submit) + the walkthrough
```

**In logos-basecamp** — `scripts/basecamp-profile.sh <name> --fresh` installs a Basecamp release and muster's own build into an isolated profile. `scripts/catalog-release.sh --local <dir>` writes a whole catalogue from this tree, to serve over local https for an install test. See [`ui/tests/README.md`](ui/tests/README.md) for the render harness.

**Headless / module only** — the core with no UI, plus the invariant probes:

```bash
cd module && nix build .#lgx-portable
lgpm install --file ./result*/*.lgx --modules-dir <dir>
logoscore -m <dir> -l muster_module -c 'muster_module.health()' --quit-on-finish
module/tests/run-suite.sh      # every unit test + invariant probe, in parallel — no host, no chain
```

**A fresh clone builds.** Every flake input is a GitHub ref. `module/` pins `logos-module-builder` to the `corpetty` fork (the `nim.packages` hook + a RUNPATH fix, upstream-pending in [logos-module-builder#226](https://github.com/logos-co/logos-module-builder/pull/226)), and `ui/` reaches `muster_module` inside the clone. See [`module/README.md`](module/README.md) and [`module/tests/README.md`](module/tests/README.md) for build and test details.

## Run the demo

**The released AppImages are out of date.** [`v0.1.0-demo`](https://github.com/corpetty/muster/releases/tag/v0.1.0-demo) and [`v0.2.0-demo`](https://github.com/corpetty/muster/releases/tag/v0.2.0-demo) are self-contained Linux downloads, but the wire format has changed since: neither can share a room with today's builds. To try today's Muster without building, install it from the catalogue (above). For the two-participant Safe + FROST walkthrough (seeding peers as anvil owners, running both coordination tracks), follow [`docs/two-party-demo-runbook.md`](docs/two-party-demo-runbook.md) with [`scripts/demo-peer.sh`](scripts/demo-peer.sh). The build recipe for the AppImage is in [`RELEASING.md`](RELEASING.md).

The Nix demo below is the from-source path: no local builder checkout, just Nix with flakes and an internet connection. Each peer joins the public `logos.test` delivery network and talks to the LEZ testnet sequencer. There is no chain to sync.

```bash
cd demo && make app
```

Then two terminals:

```bash
make alice
```

```bash
make bob
```

**The first `make alice` on a cold store is the slow one — tens of minutes.** It builds the standalone runner, which pulls the RISC Zero proving stack from source, and nix defaults to one job at a time. Get the parallelism back with:

```bash
NIX_CONFIG='max-jobs = 8' make alice
```

Wait for both account cards to read **Online**, open and fund each wallet, then copy Alice's address into Bob's **New chat**. [`demo/RUNBOOK.md`](demo/RUNBOOK.md) walks the whole journey; [`demo/WALKTHROUGH.md`](demo/WALKTHROUGH.md) is the annotated version, and [`demo/GAPS.md`](demo/GAPS.md) is the honest scorecard of what it does and does not protect.

## Repo map

```
module/          the Nim core behind muster.lidl → muster-module.lgx
  src/api/       muster.lidl (the only outward seam) + generated surface
  src/dcbor/     deterministic CDE encoder (inv 5)
  src/log/       content-addressed, hash-linked log, reduce(log) (inv 4)
  src/intents/   lifecycle · materialization · signing payload · provenance
  src/drivers/   driver interface (inv 6) · manifest · profile · conformance · safe · btc multisig ·
                 lez multisig · frost (btc + lez) · threshold · invoke · eip191
  src/crypto/    two bound identities (secp256k1 auth + Ed25519/X25519 enc), keystore, epochs
  src/transport/ Transport interface + local/delivery transports (inv 8)
  src/coordination/ multi-party session · intent lifecycle = reduce(log)
  src/wallet/    chain-agnostic wallet: EVM + Bitcoin Core + mock + real LEZ adapters, verified reads;
                 the platform's eth_rpc_module and tx_sender_module; the payee's Monero wallet (read and mint only)
  src/settlement/ the settlement seam: Safe · Bitcoin (multisig + FROST) · LEZ multisig · LEZ FROST, by the driver's profile
  src/bitcoin/   Bitcoin primitives + PSBT, pinned to the BIP vectors
  src/frost/     FROST (BIP-445) + ChillDKG, held to every draft vector
  src/lez/       the LEZ multisig program model + LEZ public transactions
  src/monero/    Monero addresses, their networks as CAIP-2, and the monero: payment URI — pure, no keys
  tests/         unit tests · probes/ the invariant probes · run-suite.sh runs them all
ui/              QML view + C++ backend → muster-ui.lgx
catalog/         Muster's own Basecamp catalogue (muster_module + muster_ui only); scripts/catalog-release.sh writes it
demo/            the speed build — runnable, and not the specified client
  RUNBOOK.md     how to run two peers · GAPS.md what it does not protect
docs/            00-vision · 01-furps · 02-implementation-plan
  diagrams/      the figure programme, its manifest, and the rot checker
  labbook/       traps found the expensive way · posts/ the campaign write-ups
contracts/specs/ typed specs with acceptance oracles, derived from the invariants
contracts/families/ the multisig family registry · claims/ the walkthrough's claims registry
infra/anvil/     devnet.sh: anvil + the REAL Safe v1.4.1 (singleton, factory, fallback handler, a 2-of-3 proxy) + foundry
infra/bitcoind/  regtest.sh: a fresh Bitcoin Core regtest · lez/ localnet.sh: a local LEZ v0.3.0 zone with a genesis funder (v0.2.4 on request)
infra/fleets/    the Logos delivery fleets the peers join
ui/prototype/    coordination-prototype-v2.html — the standalone HTML reference build
```

[`CLAUDE.md`](CLAUDE.md) carries the authoritative layout and the invariants.

## Status

**P0–P4 landed; two instances converge over the live Logos fleet; the multisig families (Phases A–D) landed 2026-09-24/25; Muster runs in Basecamp on the platform's keys and chains. Since 2026-10-07 the work aims at the Monero community campaign: the XMR payment request landed 2026-10-09, and its first live payment waits on stagenet XMR.**

- **Core and lifecycle.** The signing-path core (deterministic dCBOR, domain-separated hash-input records, a content-addressed hash-linked log whose author-bearing events — chat, declines, material shares, account disclosures — are signed by their author and dropped from every view when they are not), the intent lifecycle and driver interface, and all ten invariants. 149 unit tests and 84 invariant probes run green in one command (`module/tests/run-suite.sh`, 233/233 on 2026-10-09); seventeen more need a local chain. P4 put the whole lifecycle through the real UI (ADR-013; its acceptance harness is 6/6), and the room has since grown into the product: home → compose → room, chat, the closed card vocabulary, a scope panel, and on every card the **action manifest** — what an action does, needs, touches and discloses, and how the room agrees — with per-instance readiness, an information-flow view, and a downloadable, self-verifying audit file.
- **Transport and encryption (P3).** Two bound identities (a secp256k1 authorization identity and an Ed25519/X25519 encryption identity, joined by a signed binding the core verifies on ingest), forward-secret membership epochs (a mid-conversation joiner cannot open earlier epochs, F-16), a persistent keystore behind an operation seam, and the membership handshake. **Two instances converge over the public Logos fleet** (join → ask → admit → both at two members; `scripts/two-instance-proof.sh`), with ~1s cross-host receive. A room's messages can go out through the Logos mixnet: an opt-in setting, off by default, that hides which member sent a message but not who reads a room.
- **Multisig families (epic exo-a50).** Each family is a driver with a declared profile, held to [`contracts/families/registry.json`](contracts/families/registry.json). **Safe v1.4.1** on EVM: every SafeTx field reaches the signed hash, and the room settles on the real contract (anvil) at the Safe's live nonce. **Bitcoin** P2WSH sortedmulti and tapscript multi_a through PSBT, including signers outside muster (exit test on regtest). The **LEZ multisig program**, voted from the room, rebuilt for LEZ v0.2.4 and deployed on the public LEZ testnet; since the testnet moved to LEZ v0.3.0 (2026-09-30), ported to v0.3's plan/apply program ABI and driven from the room on a local v0.3 zone (exo-eb6.4.4); the live testnet runs fund through one account (`infra/lez/funder.sh`) once someone holding LEZ funds it. **FROST** (BIP-445 signing and the ChillDKG ceremony, held to every draft vector): the ceremony and both signing rounds run over the room's log, and settle as one 64-byte signature on Bitcoin or from an untweaked LEZ public account.
- **Wallet.** A chain-agnostic `ChainAdapter` seam: EVM (verified reads via `eth_getProof`, reusing the Nimbus verified-proxy core in-process), Bitcoin Core, and the real **LEZ** adapter on the zone's four rails (public / shield / deshield / private) with a per-rail disclosure of what reaches the public record.
- **Split the bill (epic exo-a90).** The first action with no shared account: one member fronted a bill, the room agrees who owes what (each debtor, and the creditor, whose agreement vouches for the address to pay; a split can be proposed on someone's behalf, paid where they said), and each person pays their own share from their own wallet, confirmed by the creditor's own read. On Ethereum in ETH or an ERC-20 token, in Bitcoin (each payer from their own key, confirmed on the creditor's own node), and privately on the LEZ, where it ran end to end on the public testnet. A bill may be in another currency at a recorded quote, and several splits can be settled up into fewer payments.
- **XMR payment requests (epic exo-dcc).** A payee requests XMR in a room. The payee's own Monero wallet, in Basecamp's Monero Wallet, mints a fresh subaddress for the request. The payer pays from any wallet through a `monero:` link or its QR code. The payment counts only when the payee's own wallet shows exactly that amount on that subaddress at 10 confirmations; "I paid" is a claim, never a confirmation. Muster holds no Monero key and never spends. It was seen on display in Basecamp 0.3.2 with a real stagenet wallet, up to the payment; no payment has been made through it yet. Stagenet only; mainnet waits on the Monero stack's threat model. Plan: [`docs/design/monero-in-rooms.md`](docs/design/monero-in-rooms.md).
- **In Logos Basecamp.** A member's EVM key is a `keystore_module` account approved in the platform's Signer, chain reads go through `eth_rpc_module`, and every EVM send goes through `tx_sender_module`, refused unless it is what the room agreed. Two fresh installs on Sepolia ran a split and a Safe end to end. When a proposal needs a module the person lacks, the card offers to install it through Basecamp's Package Manager; the person confirms, and Muster installs nothing itself.
- **Also beyond the phase plan.** A driver standard (a registry, a conformance suite every driver passes identically, and a generic **invoke** driver that coordinates any Logos module action); the **material** layer (a local holdings catalogue, offers that pair each requirement with your own holdings and the disclosure each choice adds, keyed contribution with a per-key F-14 binding published in-room, and a room-coordinated LEZ transfer where the recipient supplies their own address); and a Basecamp **capability-alignment** design for how those actions map to app-to-app intents.
- **What remains.** For the campaign: a live XMR payment between two machines (it needs stagenet XMR for the payer), the catalogue's first release, messaging on `logos.test` through a gifter we run so participants never hold LEZ (it needs native LEZ to fund it), and the deal-desk demo — terms, a request, a payment, a confirmation and a receipt the member chooses to share. Beyond it, the multi-party runs across two machines: the cross-host Safe settle over the live wire plus the R-4/R-6 kill-mid-collection check, the LEZ multisig propose → vote → settle between two instances, and a two-instance FROST ceremony. The LEZ multisig, FROST and LEZ FROST room surfaces are verified headless and offscreen, but nobody has clicked through them on screen against a live chain. See the [two-party Safe+FROST runbook](docs/two-party-demo-runbook.md), [`docs/two-instance-fleet-runbook.md`](docs/two-instance-fleet-runbook.md), [`docs/04-session-handoff-2026-09-25.md`](docs/04-session-handoff-2026-09-25.md) §4, and, for the Monero work, [`docs/06-session-handoff-2026-10-09.md`](docs/06-session-handoff-2026-10-09.md).

See [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) for per-phase accept criteria and ADR status.

## License

Dual MIT / Apache-2.0, matching the Logos platform repos.

## Disclaimer

This is an independent community project intended to demonstrate some of the capabilities and potential uses of the Logos technology stack. It has been developed independently by its contributor(s) and is not built for, on behalf of, or as part of the work of Logos or the Institute of Free Technology ("IFT"). It has not been reviewed, audited, approved, or endorsed by Logos or IFT. The project, including its code, documentation, views, and functionality, is the sole responsibility of its contributor(s) and should not be attributed to Logos or IFT.

<!-- rot-check: current-phase=CLAUDE.md sha256=1fe23cf515a973a2ffcf125320cb2b12d876d647acfbab95b7b12a87608cdabf -->
