# `demo/` — the speed build

> **Demonstrative only. Do not put value you care about through this.**
>
> This is something to watch and argue with, not something to use. It carries none of the guarantees the real client is specified to have — no signed log, no re-derivation of what you sign, no replay binding.
>
> Honest status of the payment journey today: you can propose it, agree it and send it, and the money reaches the recipient. A shielded balance here is a **sum over accounts found by scanning**, because what you publish is a key pair rather than an address and every payment to you mints a new account under it. That is the design, not a workaround — and its one real cost, that a single send can only draw on one of those accounts, is disclosed on screen and in `GAPS.md`.
>
> For two days this notice said the opposite: that the money did not reach the account you advertised, and that the scan was a workaround for an upstream bug. That was our misreading of a defaulted field in the wallet API, corrected by the zone's team on 2026-08-13. The full story, including the harm the wrong fix did, is in `GAPS.md` §4b — kept at length rather than deleted, because it is the most instructive thing in this directory.

**This directory deliberately violates the invariants in the repo root `CLAUDE.md`.** That is its purpose. Read this before reading anything else in here, and before citing any of it as how Muster works.

## What this is

A working prototype of the simplest complete transaction journey — *one person sends a token to another, coordinated entirely inside a private conversation* — built on the Logos stack as it actually ships in August 2026. It exists to back the testnet v03 campaign's week-one **Discovery** article: something real people can run, that is honest about what it does and does not protect, and that names the specific thing which would close each gap.

It is not Muster. Muster is the Nim/LIDL client specified in `docs/01-furps.md` and `docs/02-implementation-plan.md`, and it is being built spec-first with acceptance oracles. This is the fast, disposable cousin that ships this week.

## Run it

Needs [Nix](https://nixos.org/download) with flakes, and an internet connection — each peer joins the public `logos.test` delivery network and talks to the LEZ testnet sequencer. There is no Basecamp, no package manager and no chain to sync.

```bash
make app
```

Then a terminal each:

```bash
make alice
```

```bash
make bob
```

**Budget tens of minutes for the first `make alice` on a cold store**, and use `NIX_CONFIG='max-jobs = 8' make alice` to get the parallelism back — nix defaults to one job at a time, which measured 41 derivations/min against 110 with eight. The runner pulls the RISC Zero proving stack from source, and `make app` does not pre-build it despite saying so: it builds `packages.default` (the `.lgx`) while `make run` launches `apps.default`, a different derivation. Tracked as `exo-d6d`; the Makefile's own help text is the thing that is wrong, so do not trust it over this paragraph until that lands.

Both account cards read **Online** a couple of seconds after launch, and nothing works before that — the app says so rather than failing on the first action. Open and fund each wallet, then copy Alice's address into Bob's **New chat** and the conversation opens on both sides. That step is the argument in miniature: no directory, no lookup, no server that learns they met.

A peer is just a `--user-dir`. Its chat identity and its wallet share one directory under `.run/<name>/`, deliberately — two peers sharing a directory would share an identity, which would make any recording a lie. `make clean-peer PEER=alice` resets both together, and `make run PEER=carol` adds a third.

| Read this | For |
|---|---|
| `RUNBOOK.md` | The journey step by step, and what each step is demonstrating |
| `WALKTHROUGH.md` | The annotated version, with what to look at on screen |
| `GAPS.md` | The honest scorecard: what is protected, what is not, and what would close each gap |
| `make help` | Every target |

## How it differs from the real thing

| Root invariant | What `demo/` does instead |
|---|---|
| Nim core behind a published `muster.lidl`, on chronos | Rust + a forked C++/QML app; contract surface is `logos-chat-module`'s, not ours |
| State = reduce(log); nothing exists that can't be rebuilt from log + keys | No log. Conversation state is whatever `chat_module` holds |
| Deterministic bytes on signing paths; domain-separated `hash-input` records | No signing paths of our own; we send JSON strings |
| Effects reviewed, materializations signed, client re-derives and refuses on mismatch | No effect/materialization split; a send is a send |
| Every signing payload commits to environment, account, slot, expiry | Not applicable — no multi-party authorization here |
| Membership epochs re-key forward | Whatever `chat_module`'s MLS does; we neither verify nor claim it |
| Conformance suite before driver features | No drivers, no conformance suite |

What it *does* keep is the honesty rule from `docs/00-vision.md`, because that rule is the whole point: **every claim this app makes on screen must be true of the code that is running.** Where the stack leaks, the app says so, at the step where it leaks, with the fix and that fix's real status (`shipped` / `specified` / `partial` / `none`). A demo that overstates its protections would be worse than no demo.

## What it composes

| Piece | Source | Role |
|---|---|---|
| `chat_module` v0.2.2 | upstream `logos-co/logos-chat-module` | e2e-encrypted 1:1 conversations, identity, address-based discovery |
| `delivery_module` v0.2.0 | re-exported by `chat_module`'s flake | transport |
| `muster-ui` | **fork of `logos-co/logos-chat-ui` v0.2.2** | the app: conversation + address cards + send flow + visibility panel |
| `muster-wallet` | ours | λ on the LEZ testnet: keys, balances, and all four transfer directions |

Structured cards (address request, address share, send receipt) ride as JSON inside `chat_module`'s `send_message(convo_id, content)`, so they inherit its encryption. **We write no cryptography.**

No custom on-chain program is needed: every rail is a builtin zone transfer. No risc0 guest builds, no Solidity.

**Earlier drafts of this file claimed ETH sends against a local anvil.** There were none, and there is no EVM module in the runtime set — adding one would mean either a new module or writing our own secp256k1 signing, which would break the "we write no cryptography" claim above. The line is corrected rather than quietly dropped, because a README that overstates what a demo does is the same failure the app is built to avoid.

### The four rails

The zone supports every combination of shielded and public at each end, and the app offers all four. They are the same payment differing in exactly one thing — what the chain learns — which is the demo's whole argument, made operable rather than asserted:

| Rail | Amount | Payer | Payee | Speed |
|---|---|---|---|---|
| private → private | hidden | hidden | hidden | ~7 min (proves) |
| public → private | public | public | hidden | proves |
| private → public | public | hidden | public | proves |
| public → public | public | public | public | seconds |

Nothing hides *that* a transfer happened, or when. That is the floor on every rail, and the app says so on every receipt.

Adding an asset or a rail is one entry in `muster-ui/src/ChatBackendAssets.cpp` plus its visibility claim; a rail with no claim is refused by the backend rather than shipped unexplained.

## Attribution

`muster-ui/` is a fork of [`logos-co/logos-chat-ui`](https://github.com/logos-co/logos-chat-ui) at v0.2.2 (dual MIT / Apache-2.0, same as this repo). Upstream authored the conversation UI, the QtRO backend pattern, and the models; this fork adds the wallet journey and the visibility panel. Bug fixes that aren't Muster-specific belong upstream.

## Refactor path

When the campaign article is out, this becomes input to the spec-hardening work rather than a codebase to maintain: the journey it proves gets re-authored as typed specs via `discuss-issue`, and the real client implements them. Findings that belong in the record — platform gaps, upstream issues, things the prototype taught us — go to `docs/labbook/`.
