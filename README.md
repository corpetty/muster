# Muster

**Do things together, privately.** Muster is a local-first client for coordinating multi-party transactions inside conversations, built on the [Logos](https://logos.co) stack. The conversation is the security boundary: who is in the room determines who can read what is being done.

Muster's first mission is education — it walks people through the entire transaction lifecycle, showing at every step how the Logos stack maintains privacy and security, and where conventional stacks leak. The teaching client and the real client are the same client: everything demonstrated is enforced by running code, and the end goal is a usable application for coordinating with people securely and privately.

## Documents

| Doc | What it is |
|---|---|
| [docs/00-vision.md](docs/00-vision.md) | Why Muster exists; the lifecycle-as-curriculum framing and honesty rules |
| [docs/01-furps.md](docs/01-furps.md) | Normative FURPS+ requirements (stable IDs, referenced in commits and tests) |
| [docs/02-implementation-plan.md](docs/02-implementation-plan.md) | Stack decisions, reuse from logos-core-poc2, phases P0–P6, ADR gates |
| [CLAUDE.md](CLAUDE.md) | Invariants, working agreements, commands |
| [ui/prototype/coordination-prototype-v2.html](ui/prototype/coordination-prototype-v2.html) | Standalone HTML/JS simulation the FURPS were written against — tokens, components, copy voice, the six-step legend. No real crypto; not the app. |

## Shape

Two logos-core modules from one repo: a Nim backend (`muster-module.lgx`, chronos async, deterministic CBOR on every signing path) and a QML frontend (`muster-ui.lgx`), hosted by logos-basecamp (GUI) or the `logoscore` CLI runtime (headless). No server, no telemetry; store nodes and RPC endpoints are untrusted, user-configurable infrastructure.

## Status

Pre-P0. The current phase is the module scaffold: loading cleanly in `logoscore`, CDDL/dCBOR schemas with golden vectors, and the signed hash-linked log. See the [implementation plan](docs/02-implementation-plan.md) for accept criteria.

## License

Dual MIT / Apache-2.0, matching the Logos platform repos.
