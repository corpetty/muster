# Muster

**Do things together, privately.** Muster is a local-first client for coordinating multi-party transactions inside conversations, built on the [Logos](https://logos.co) stack. The conversation is the security boundary: who is in the room determines who can read what is being done.

Muster's first mission is education — it walks people through the entire transaction lifecycle, showing at every step how the Logos stack maintains privacy and security, and where conventional stacks leak. The teaching client and the real client are the same client: everything demonstrated is enforced by running code, and the end goal is a usable application for coordinating with people securely and privately.

## What is actually here

The specified client now exists and runs. The Nim core (`module/`) and the QML UI (`ui/`) were built P0→P4: the whole transaction lifecycle runs in the UI against a real 2-of-3 Safe, the room coordinates Bitcoin, LEZ and FROST multisigs too, and the unit tests and invariant probes are green. Read the table before drawing conclusions from anything below it.

| | What it is | State |
|---|---|---|
| **[`module/`](module/) + [`ui/`](ui/)** | The specified client — a Nim core behind the `muster.lidl` contract (`muster-module.lgx`) and a QML frontend (`muster-ui.lgx`), hosted on logos-core | **Runs.** P0–P4 landed, plus the multisig families (Safe, Bitcoin PSBT, the LEZ multisig program, FROST); the full lifecycle (describe → propose → approve → submit) runs in the UI. Unit tests and invariant probes green (`module/tests/run-suite.sh`) |
| **[`demo/`](demo/)** | A one-week speed build of the simplest complete journey — one person pays another, coordinated inside a private conversation — composing Logos modules that ship today | **Runs.** Two peers, real payments on the LEZ testnet. Deliberately violates most invariants |
| **[`docs/`](docs/) + [`contracts/specs/`](contracts/specs/)** | The specification for the real client: vision, normative requirements, phase plan, and the ten invariants as fourteen typed specs with acceptance oracles | Written, and now substantially implemented and probe-checked |
| **[`docs/diagrams/`](docs/diagrams/)** | The figure programme — mechanics, architecture, and where each stage of a transaction leaks | Published at **<https://corpetty.github.io/muster/>** |

The demo and the specified client are different codebases. The demo violates most of the invariants the real client holds, which is why it could exist in a week. It says so on itself, at length, in [`demo/README.md`](demo/README.md). Do not cite it as how Muster works — for that, read `module/`.

**Ten invariants, fourteen specs — the mismatch is deliberate.** `CLAUDE.md` numbers the invariants 1–10 (5b is explicitly *not* an invariant). Two invariants carry more than one spec. Invariant 5 (deterministic bytes on signing paths) is the dCBOR encoder and the domain-separated hash-input records. Invariant 10 (provenance) is the record itself, its wiring into the live room, and the audit file a member can download. One further spec pins the P4 host-return gate, which is a phase gate rather than an invariant. Ten, plus one, plus two, plus one, is fourteen. A retired spec — anonymous membership, ADR-015 — stays in [`contracts/specs/retired/`](contracts/specs/retired/) as the record of why.

## Start here

| If you want to… | Go to |
|---|---|
| **Run the specified client** | [Below](#run-the-specified-client) — `make build`, then `make run`; [`module/README.md`](module/README.md) for the module alone |
| **Run the tests** | `module/tests/run-suite.sh` — every unit test and invariant probe in one command; [`module/tests/README.md`](module/tests/README.md) for the chain-bound ones |
| **Run the demo instead** | [`demo/RUNBOOK.md`](demo/RUNBOOK.md) — two peers on one machine, and the journey end to end |
| **Understand the argument** | [`docs/posts/01-the-pipeline-and-discovery.md`](docs/posts/01-the-pipeline-and-discovery.md), then the [diagram site](https://corpetty.github.io/muster/) |
| **Know why Muster exists** | [`docs/00-vision.md`](docs/00-vision.md) — the lifecycle-as-curriculum framing, and the honesty rules that bind every surface |
| **Read what is being built** | [`docs/01-furps.md`](docs/01-furps.md) (normative, stable ids) and [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) (phases P0–P6, ADRs) |
| **See how a claim is held to account** | The ten invariants in [`CLAUDE.md`](CLAUDE.md), and their typed specs in [`contracts/specs/`](contracts/specs/) |
| **Read what went wrong** | [`docs/labbook/`](docs/labbook/) — traps found the expensive way, kept rather than tidied |

## Run the specified client

Needs [Nix](https://nixos.org/download) with flakes. There are three ways in; all build through `cache.nix.logos.co` (the Makefile passes it for you).

**Standalone app — the easy path.** `logos-standalone-app` hosts the muster UI and `muster_module` directly; no basecamp, no package manager.

```bash
make build   # the slow first build — pre-builds the runner (minutes); do this once
make run     # launch: the lifecycle dashboard (propose → approve → submit) + the walkthrough
```

**In logos-basecamp** — if you already run basecamp, load `muster-ui.lgx` there as a module instead. See [`ui/tests/README.md`](ui/tests/README.md) § "Producing the app-under-test".

**Headless / module only** — the core with no UI, plus the invariant probes:

```bash
cd module && nix build .#lgx-portable
lgpm install --file ./result*/*.lgx --modules-dir <dir>
logoscore -m <dir> -l muster_module -c 'muster_module.health()' --quit-on-finish
module/tests/run-suite.sh      # every unit test + invariant probe, in parallel — no host, no chain
```

**A fresh clone builds.** Every flake input is a GitHub ref. `module/` pins `logos-module-builder` to the `corpetty` fork (the `nim.packages` hook + a RUNPATH fix, upstream-pending in [logos-module-builder#226](https://github.com/logos-co/logos-module-builder/pull/226)), and `ui/` reaches `muster_module` inside the clone. See [`module/README.md`](module/README.md) and [`module/tests/README.md`](module/tests/README.md) for build and test details.

## Run the demo

**The easiest path is the released AppImage** — a self-contained Linux download, no Nix, no clone: **[`v0.1.0-demo`](https://github.com/corpetty/muster/releases/tag/v0.1.0-demo)** (`Muster-demo-linux-x86_64.AppImage`). For the two-participant Safe + FROST walkthrough (seeding peers as anvil owners, running both coordination tracks), follow [`docs/two-party-demo-runbook.md`](docs/two-party-demo-runbook.md) with [`scripts/demo-peer.sh`](scripts/demo-peer.sh). The build recipe for the AppImage is in [`RELEASING.md`](RELEASING.md).

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
  src/wallet/    chain-agnostic wallet: EVM + Bitcoin Core + mock + real LEZ adapters, verified reads
  src/settlement/ the settlement seam: Safe · Bitcoin (multisig + FROST) · LEZ multisig · LEZ FROST, by the driver's profile
  src/bitcoin/   Bitcoin primitives + PSBT, pinned to the BIP vectors
  src/frost/     FROST (BIP-445) + ChillDKG, held to every draft vector
  src/lez/       the LEZ multisig program model + LEZ public transactions
  tests/         unit tests · probes/ the invariant probes · run-suite.sh runs them all
ui/              QML view + C++ backend → muster-ui.lgx
demo/            the speed build — runnable, and not the specified client
  RUNBOOK.md     how to run two peers · GAPS.md what it does not protect
docs/            00-vision · 01-furps · 02-implementation-plan
  diagrams/      the figure programme, its manifest, and the rot checker
  labbook/       traps found the expensive way · posts/ the campaign write-ups
contracts/specs/ typed specs with acceptance oracles, derived from the invariants
contracts/families/ the multisig family registry · claims/ the walkthrough's claims registry
infra/anvil/     devnet.sh: anvil + the REAL Safe v1.4.1 (singleton, factory, fallback handler, a 2-of-3 proxy) + foundry
infra/bitcoind/  regtest.sh: a fresh Bitcoin Core regtest · lez/ localnet.sh: a LEZ v0.2.4 sequencer
infra/fleets/    the Logos delivery fleets the peers join
ui/prototype/    coordination-prototype-v2.html — the standalone HTML reference build
```

[`CLAUDE.md`](CLAUDE.md) carries the authoritative layout and the invariants.

## Status

**P0–P4 landed; two instances converge over the live Logos fleet; the multisig families (Phases A–D) landed 2026-09-24/25. What remains is the multi-party runs across two machines.**

- **Core and lifecycle.** The signing-path core (deterministic dCBOR, domain-separated hash-input records, a content-addressed hash-linked log whose author-bearing events — chat, declines, material shares, account disclosures — are signed by their author and dropped from every view when they are not), the intent lifecycle and driver interface, and all ten invariants. 93 unit tests and 55 invariant probes run green in one command (`module/tests/run-suite.sh`); eight more need a local chain. P4 put the whole lifecycle through the real UI (ADR-013; its acceptance harness is 6/6), and the room has since grown into the product: home → compose → room, chat, the closed card vocabulary, a scope panel, and on every card the **action manifest** — what an action does, needs, touches and discloses, and how the room agrees — with per-instance readiness, an information-flow view, and a downloadable, self-verifying audit file.
- **Transport and encryption (P3).** Two bound identities (a secp256k1 authorization identity and an Ed25519/X25519 encryption identity, joined by a signed binding the core verifies on ingest), forward-secret membership epochs (a mid-conversation joiner cannot open earlier epochs, F-16), a persistent keystore behind an operation seam, and the membership handshake. **Two instances converge over the public Logos fleet** (join → ask → admit → both at two members; `scripts/two-instance-proof.sh`), with ~1s cross-host receive.
- **Multisig families (epic exo-a50).** Each family is a driver with a declared profile, held to [`contracts/families/registry.json`](contracts/families/registry.json). **Safe v1.4.1** on EVM: every SafeTx field reaches the signed hash, and the room settles on the real contract (anvil) at the Safe's live nonce. **Bitcoin** P2WSH sortedmulti and tapscript multi_a through PSBT, including signers outside muster (exit test on regtest). The **LEZ multisig program**, voted from the room, rebuilt for LEZ v0.2.4 and deployed on the public LEZ testnet. **FROST** (BIP-445 signing and the ChillDKG ceremony, held to every draft vector): the ceremony and both signing rounds run over the room's log, and settle as one 64-byte signature on Bitcoin or from an untweaked LEZ public account.
- **Wallet.** A chain-agnostic `ChainAdapter` seam: EVM (verified reads via `eth_getProof`, reusing the Nimbus verified-proxy core in-process), Bitcoin Core, and the real **LEZ** adapter on the zone's four rails (public / shield / deshield / private) with a per-rail disclosure of what reaches the public record.
- **Also beyond the phase plan.** A driver standard (a registry, a conformance suite every driver passes identically, and a generic **invoke** driver that coordinates any Logos module action); the **material** layer (a local holdings catalogue, offers that pair each requirement with your own holdings and the disclosure each choice adds, keyed contribution with a per-key F-14 binding published in-room, and a room-coordinated LEZ transfer where the recipient supplies their own address); and a Basecamp **capability-alignment** design for how those actions map to app-to-app intents.
- **What remains.** The multi-party runs across two machines: the cross-host Safe settle over the live wire plus the R-4/R-6 kill-mid-collection check, the LEZ multisig propose → vote → settle between two instances, and a two-instance FROST ceremony. The LEZ multisig, FROST and LEZ FROST room surfaces are verified headless and offscreen, but nobody has clicked through them on screen against a live chain. See the [two-party Safe+FROST runbook](docs/two-party-demo-runbook.md), [`docs/two-instance-fleet-runbook.md`](docs/two-instance-fleet-runbook.md), and [`docs/04-session-handoff-2026-09-25.md`](docs/04-session-handoff-2026-09-25.md) §4.

See [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) for per-phase accept criteria and ADR status.

## License

Dual MIT / Apache-2.0, matching the Logos platform repos.

## Disclaimer

This is an independent community project intended to demonstrate some of the capabilities and potential uses of the Logos technology stack. It has been developed independently by its contributor(s) and is not built for, on behalf of, or as part of the work of Logos or the Institute of Free Technology ("IFT"). It has not been reviewed, audited, approved, or endorsed by Logos or IFT. The project, including its code, documentation, views, and functionality, is the sole responsibility of its contributor(s) and should not be attributed to Logos or IFT.

<!-- rot-check: current-phase=CLAUDE.md sha256=4869cf24ab98183b8d931013bbd718db9f9c6b971d7ea042f9b6d897c40e8f5e -->
