# Muster

**Do things together, privately.** Muster is a local-first client for coordinating multi-party transactions inside conversations, built on the [Logos](https://logos.co) stack. The conversation is the security boundary: who is in the room determines who can read what is being done.

Muster's first mission is education — it walks people through the entire transaction lifecycle, showing at every step how the Logos stack maintains privacy and security, and where conventional stacks leak. The teaching client and the real client are the same client: everything demonstrated is enforced by running code, and the end goal is a usable application for coordinating with people securely and privately.

## What is actually here

The specified client now exists and runs. The Nim core (`module/`) and the QML UI (`ui/`) were built P0→P4: the whole transaction lifecycle runs in the UI against a real 2-of-3 Safe, and the invariant-probe suite is green. Read the table before drawing conclusions from anything below it.

| | What it is | State |
|---|---|---|
| **[`module/`](module/) + [`ui/`](ui/)** | The specified client — a Nim core behind the `muster.lidl` contract (`muster-module.lgx`) and a QML frontend (`muster-ui.lgx`), hosted on logos-core | **Runs.** P0–P2 and P4 landed; the full lifecycle (describe → propose → approve → submit) runs in `logos-basecamp` against a real Safe. Invariant probes green |
| **[`demo/`](demo/)** | A one-week speed build of the simplest complete journey — one person pays another, coordinated inside a private conversation — composing Logos modules that ship today | **Runs.** Two peers, real payments on the LEZ testnet. Deliberately violates most invariants |
| **[`docs/`](docs/) + [`contracts/specs/`](contracts/specs/)** | The specification for the real client: vision, normative requirements, phase plan, and the ten invariants as twelve typed specs with acceptance oracles | Written, and now substantially implemented and probe-checked |
| **[`docs/diagrams/`](docs/diagrams/)** | The figure programme — mechanics, architecture, and where each stage of a transaction leaks | Published at **<https://corpetty.github.io/muster/>** |

The demo and the specified client are different codebases. The demo violates most of the invariants the real client holds, which is why it could exist in a week. It says so on itself, at length, in [`demo/README.md`](demo/README.md). Do not cite it as how Muster works — for that, read `module/`.

**Ten invariants, twelve specs — the mismatch is deliberate.** `CLAUDE.md` numbers the invariants 1–10 (5b is explicitly *not* an invariant). Invariant 5 (deterministic bytes on signing paths) is carried by two specs — the dCBOR encoder and the domain-separated hash-input records — and one further spec pins the P4 loading-spike accept criterion, which is a phase gate rather than an invariant. Ten plus one, plus one, is twelve.

## Start here

| If you want to… | Go to |
|---|---|
| **Run the specified client** | [`module/README.md`](module/README.md) — build `muster-module.lgx`, load it headless, run the probes |
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
nim r -d:release module/tests/probes/probe_materialization_mismatch_refused.nim   # no host needed
```

> **Runs on a contributor's machine today, not yet from a fresh clone.** `module/` and `ui/` pin `logos-module-builder` to a **local** checkout of its `nim-cdylib-authoring` branch (the `nim.packages` hook + a RUNPATH fix, [PR #202](https://github.com/logos-co/logos-module-builder/pull/202)), and `ui/flake.nix` references `muster_module` by absolute path — both machine-specific until those land upstream. Until then, other people run it from a prebuilt release, not `make run` on a clone. See [`module/README.md`](module/README.md) and [`module/tests/README.md`](module/tests/README.md) for build/test details.

## Run the demo

The demo is the low-friction path: no local builder checkout, just Nix with flakes and an internet connection. Each peer joins the public `logos.test` delivery network and talks to the LEZ testnet sequencer. There is no chain to sync.

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
  src/log/       signed hash-linked log, reduce(log) (inv 4)
  src/intents/   lifecycle · materialization · signing payload · provenance
  src/drivers/   driver interface (inv 6) · safe · threshold · conformance
  src/crypto/    two bound identities (secp256k1 auth + Ed25519/X25519 enc), keystore, epochs
  src/transport/ Transport interface + local/delivery transports (inv 8)
  src/coordination/ multi-party session · intent lifecycle = reduce(log)
  src/wallet/    chain-agnostic wallet: EVM + mock shielded adapters, verified reads
  tests/probes/  invariant probes
ui/              QML view + C++ backend → muster-ui.lgx
demo/            the speed build — runnable, and not the specified client
  RUNBOOK.md     how to run two peers · GAPS.md what it does not protect
docs/            00-vision · 01-furps · 02-implementation-plan
  diagrams/      the figure programme, its manifest, and the rot checker
  labbook/       traps found the expensive way · posts/ the campaign write-ups
contracts/specs/ typed specs with acceptance oracles, derived from the invariants
infra/anvil/     MiniSafe.sol fixture (faithful Safe-1.4.1 subset) + foundry
ui/prototype/    coordination-prototype-v2.html — the standalone HTML reference build
```

[`CLAUDE.md`](CLAUDE.md) carries the authoritative layout and the invariants.

## Status

**P0–P2 and P4 landed; P3 is functionally complete against a local transport.** The signing-path core (deterministic dCBOR, domain-separated hash-input records, a signed hash-linked log), the intent lifecycle engine and driver interface, and all ten invariants landed by hand — the invariant-probe suite is green. The Safe driver re-derives the EIP-712 `safeTxHash`, verifies secp256k1 owner signatures, collects 2-of-3, and executes a real on-chain `execTransaction` against an anvil `MiniSafe`. **P4** put the whole lifecycle through the real UI in `logos-basecamp` (ADR-013); its acceptance harness is 6/6. The UI has since grown from that spike to the **product surfaces** — a home → compose → room shell with chat, the closed card vocabulary (intent-propose with a status rail + approval slots, receipts), and a scope/membership panel — folding over a new conversation layer in the module (`coordinate_post_message` / `coordinate_messages` / `coordinate_members`). It reproduces the demo's experience in the spec-first client and runs standalone via `make run`. The room's proposal cards are now wired to the **verified** path — they render the `coordinate_intents` fold (effect + threshold + distinct-owner approvals), Propose calls `coordinate_propose`, and Approve feeds an owner signature to `coordinate_contribute`, which the driver refuses unless it recovers to a configured owner. The real transport is now stood up too: `delivery_module` rides the standalone runner's module set and the host loads + initializes it, so `coordinate_join` boots a real node and connects to the public Logos fleet — **two instances converge over it (join → ask → admit → both at two members)**; the cross-host Safe-transaction half (which needs owner-seeded peers) and latency polish remain. Room-side submit is next; the shielded LEZ journey waits on the deferred LEZ adapter.

**P3** — real transport, encryption, and multi-party coordination — is built and tested: two bound identities (a secp256k1 authorization identity and an Ed25519/X25519 encryption identity, joined by a signed binding the core verifies on ingest), an ECIES epoch layer with forward secrecy verified (a mid-conversation joiner cannot open earlier epochs, F-16), a persistent keystore behind an operation seam, the hosted coordination surface, and a membership/grant handshake. **Two instances now converge over the live Logos fleet — the membership handshake works end to end (join → ask → admit → both at two members).** What remains is the cross-host **Safe-transaction** half (propose → sign → settle over the wire needs the two peers seeded with Safe owner keys) and latency polish (cross-host delivery rides an ~8s store-catchup poll). See [`docs/two-instance-fleet-runbook.md`](docs/two-instance-fleet-runbook.md) for the operator flow and [`docs/labbook/two-instance-live-wire-blockers.md`](docs/labbook/two-instance-live-wire-blockers.md) for the six fixes it took.

**Beyond the phase plan:** a chain-agnostic wallet (a `ChainAdapter` seam with an EVM adapter and a mock shielded chain, verified reads via `eth_getProof` reusing the Nimbus verified-proxy core in-process), and a driver standard (a registry, a conformance suite, and a threshold k-of-n driver proving the driver seam is generic).

See [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) for per-phase accept criteria and ADR status.

## License

Dual MIT / Apache-2.0, matching the Logos platform repos.

## Disclaimer

This is an independent community project intended to demonstrate some of the capabilities and potential uses of the Logos technology stack. It has been developed independently by its contributor(s) and is not built for, on behalf of, or as part of the work of Logos or the Institute of Free Technology ("IFT"). It has not been reviewed, audited, approved, or endorsed by Logos or IFT. The project, including its code, documentation, views, and functionality, is the sole responsibility of its contributor(s) and should not be attributed to Logos or IFT.

<!-- rot-check: current-phase=CLAUDE.md sha256=2b06eeafcaf9594eb96000ac9d5afeed892eddbce130130f15f362f9c8420556 -->
