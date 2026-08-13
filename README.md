# Muster

**Do things together, privately.** Muster is a local-first client for coordinating multi-party transactions inside conversations, built on the [Logos](https://logos.co) stack. The conversation is the security boundary: who is in the room determines who can read what is being done.

Muster's first mission is education — it walks people through the entire transaction lifecycle, showing at every step how the Logos stack maintains privacy and security, and where conventional stacks leak. The teaching client and the real client are the same client: everything demonstrated is enforced by running code, and the end goal is a usable application for coordinating with people securely and privately.

## What is actually here

Three things, and **the specified client is not yet one of them.** No Nim core has been written; `module/` does not exist and the P0 loading spike is still ahead. Read the table before drawing conclusions from anything below it.

| | What it is | State |
|---|---|---|
| **[`demo/`](demo/)** | A one-week speed build of the simplest complete journey — one person pays another, coordinated inside a private conversation — composing Logos modules that ship today | **Runs.** Two peers, real payments on the LEZ testnet |
| **[`docs/`](docs/) + [`contracts/specs/`](contracts/specs/)** | The specification for the real client: vision, normative requirements, phase plan, and eleven typed specs with acceptance oracles derived from the invariants | Written. Nothing implements it yet |
| **[`docs/diagrams/`](docs/diagrams/)** | The figure programme — mechanics, architecture, and where each stage of a transaction leaks | Published at **<https://corpetty.github.io/muster/>** |

The demo deliberately violates most of the invariants the real client is specified to hold, which is why it can exist in a week. It says so on itself, at length, in [`demo/README.md`](demo/README.md). Do not cite it as how Muster works.

## Start here

| If you want to… | Go to |
|---|---|
| **Run something** | [`demo/RUNBOOK.md`](demo/RUNBOOK.md) — two peers on one machine, and the journey end to end |
| **Understand the argument** | [`docs/posts/01-the-pipeline-and-discovery.md`](docs/posts/01-the-pipeline-and-discovery.md), then the [diagram site](https://corpetty.github.io/muster/) |
| **Know why Muster exists** | [`docs/00-vision.md`](docs/00-vision.md) — the lifecycle-as-curriculum framing, and the honesty rules that bind every surface |
| **Read what is being built** | [`docs/01-furps.md`](docs/01-furps.md) (normative, stable ids) and [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) (phases P0–P6) |
| **See how a claim is held to account** | The ten invariants in [`CLAUDE.md`](CLAUDE.md), and their typed specs in [`contracts/specs/`](contracts/specs/) |
| **Read what went wrong** | [`docs/labbook/`](docs/labbook/) — traps found the expensive way, kept rather than tidied |

## Run the demo

Needs [Nix](https://nixos.org/download) with flakes, and an internet connection: each peer joins the public `logos.test` delivery network and talks to the LEZ testnet sequencer. There is no chain to sync and nothing to install beyond this.

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

**The first `make alice` on a cold store is the slow one — tens of minutes.** It builds the standalone runner, which pulls the RISC Zero proving stack from source, and nix defaults to one job at a time. `make app` is *supposed* to pre-build that and does not; it builds the packaged module instead and returns in seconds. Tracked as `exo-d6d`. Until it is fixed, get the parallelism back with:

```bash
NIX_CONFIG='max-jobs = 8' make alice
```

Wait for both account cards to read **Online**, open and fund each wallet, then copy Alice's address into Bob's **New chat**. [`demo/RUNBOOK.md`](demo/RUNBOOK.md) walks the whole journey; [`demo/WALKTHROUGH.md`](demo/WALKTHROUGH.md) is the annotated version, and [`demo/GAPS.md`](demo/GAPS.md) is the honest scorecard of what it does and does not protect.

## Repo map

```
demo/            the speed build — runnable today, and not the specified client
  muster-ui/     fork of logos-co/logos-chat-ui: QML + QtRO C++ backend, wallet journey
  RUNBOOK.md     how to run two peers
  GAPS.md        what it does not protect, and what would close each gap
docs/            00-vision · 01-furps · 02-implementation-plan
  diagrams/      the figure programme, its manifest, and the rot checker
  labbook/       traps found the expensive way
  posts/         the campaign write-ups
contracts/specs/ typed specs with acceptance oracles, one per invariant
ui/prototype/    coordination-prototype-v2.html — the standalone HTML reference build
```

`module/` (the Nim core behind `muster.lidl`) and `ui/` proper arrive at P0 and P4. The layout above is what exists; [`CLAUDE.md`](CLAUDE.md) describes the target.

## Status

**P0, at its first step.** The phase opens with a loading spike — a two-method `muster.lidl`, its Nim surface generated over the `lidl_c.h` JSON bridge, loading and answering one call in `logoscore` — chosen deliberately because it exercises the one part of the stack with no precedent. That spike has not been done, so the commands in `CLAUDE.md` describe a tree that does not exist yet.

What has been done is the specification work the spike will be measured against: the requirements, the phase plan, ten invariants, and eleven typed specs that passed a gate rejecting a spec whose oracles are vacuous, untraceable to the request, or too weak for the severity of what they guard. Those specs are authored, not discharged — most of their probes are unwritten, so an invariant here is currently asserted more often than it is checked. See [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) for accept criteria.

## License

Dual MIT / Apache-2.0, matching the Logos platform repos.
