# `demo/` — the speed build

> **Demonstrative only. Do not put value you care about through this.**
>
> This is something to watch and argue with, not something to use. It carries none of the guarantees the real client is specified to have — no signed log, no re-derivation of what you sign, no replay binding — and it is currently **working around an upstream bug by adding up private accounts it finds by scanning**, because a payment does not arrive at the address you published. That workaround is disclosed on screen and in `GAPS.md`. It is not a design, and it comes out when the zone fixes the underlying issue.
>
> Honest status of the payment journey today: you can propose it, agree it and send it, and the money reaches the recipient's *wallet* — but not the account they advertised, and a balance shown here may be larger than any single payment can spend. Finding exactly this class of problem is what a prototype is for.

**This directory deliberately violates the invariants in the repo root `CLAUDE.md`.** That is its purpose. Read this before reading anything else in here, and before citing any of it as how Muster works.

## What this is

A working prototype of the simplest complete transaction journey — *one person sends a token to another, coordinated entirely inside a private conversation* — built on the Logos stack as it actually ships in August 2026. It exists to back the testnet v03 campaign's week-one **Discovery** article: something real people can run, that is honest about what it does and does not protect, and that names the specific thing which would close each gap.

It is not Muster. Muster is the Nim/LIDL client specified in `docs/01-furps.md` and `docs/02-implementation-plan.md`, and it is being built spec-first with acceptance oracles. This is the fast, disposable cousin that ships this week.

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
| `muster-wallet` | ours | ETH (anvil) and λ (LEZ localnet) sends, keys, balances |

Structured cards (address request, address share, send receipt) ride as JSON inside `chat_module`'s `send_message(convo_id, content)`, so they inherit its encryption. **We write no cryptography.**

Neither chain needs a custom on-chain program: λ uses the builtin `authenticated_transfer`, ETH is a native value transfer. No risc0 guest builds, no Solidity.

## Attribution

`muster-ui/` is a fork of [`logos-co/logos-chat-ui`](https://github.com/logos-co/logos-chat-ui) at v0.2.2 (dual MIT / Apache-2.0, same as this repo). Upstream authored the conversation UI, the QtRO backend pattern, and the models; this fork adds the wallet journey and the visibility panel. Bug fixes that aren't Muster-specific belong upstream.

## Refactor path

When the campaign article is out, this becomes input to the spec-hardening work rather than a codebase to maintain: the journey it proves gets re-authored as typed specs via `discuss-issue`, and the real client implements them. Findings that belong in the record — platform gaps, upstream issues, things the prototype taught us — go to `docs/labbook/`.
