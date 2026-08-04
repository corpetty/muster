# CLAUDE.md

**Muster** — a local-first client for coordinating multi-party transactions inside conversations, on the Logos stack. The conversation is the security boundary. The first mission is education: walk people through the entire transaction lifecycle, showing at each step how Logos maintains privacy and security and where other stacks leak (`docs/00-vision.md`). The end state is a usable client for doing things together, securely and privately.

Built as logos-core modules: a Nim backend (`muster-module.lgx`) and a QML frontend (`muster-ui.lgx`), hosted by logos-basecamp (GUI) and `logoscore` (headless). Full requirements: `docs/01-furps.md`. Phase plan: `docs/02-implementation-plan.md`. UI reference: the v2 HTML prototype (tokens, components, copy voice).

## Invariants — violating any of these is a bug, whatever the tests say

1. **Effects are reviewed; materializations are signed; the client re-derives the materialization and refuses on mismatch.** This check lives in the module core and cannot be disabled (F-4, FS-6).
2. **Every signing payload commits to environment, account, slot, and expiry.** A signature must be worthless anywhere else (F-5, FS-3).
3. **Plugins never sign, never hold keys, never touch the network.** They emit typed blocks only; there is no plugin canvas (F-12, F-13, FS-5).
4. **State = reduce(log).** Nothing exists that can't be rebuilt from log + keys. Reducers are idempotent; convergence under reorder/duplication is a property test (R-2, R-3).
5. **Deterministic bytes on signing paths.** Logos deterministic CBOR profile only (LOGOS-MODULE-INTERFACE §4.5) — CDE bytewise-lex map ordering (never length-first), shortest integers, no indefinite lengths. Every hash is a domain-separated `hash-input` record per LOGOS-MODULE-HASH-PROFILE; no ad-hoc concatenation.
6. **The core never interprets contribution bytes** — drivers do. Rounds, serialization domain, membership model, and finality are driver-described, never hardcoded (F-6, F-7).
7. **Membership epochs are real:** adding a member re-keys forward; they cannot read earlier epochs (F-16). The UI seam depends on this.
8. **No server, no telemetry.** Store nodes and RPC are untrusted, user-configurable infrastructure (FS-1, FS-8).
9. **Anonymous drivers stay anonymous** end to end: no signer identity in UI state, logs, or ordering (FS-7).

## Pattern sources

- `logos-co/logos-core-poc2` — module skeleton (`src/shell.nim`), C ABI (`abi_types.nim`), transport framing, `runtime_cli loop` TCP host (the P0–P3 integration harness). Its tests track behavior, not intent — never copy them as spec.
- `logos-co/logos-lips` branch `draft/logos-core-module-specs` — the normative LOGOS-MODULE-* specs and cdCDDLe. Where poc2 code and spec diverge, the spec wins; spec appendix vectors become tests.

## Working agreements

- chronos only; never std asyncdispatch.
- Conformance suite (`module/src/drivers/conformance`) before driver features; never merge with it red.
- Integration tests use the stub driver and local transport — never mock `Driver` or `Transport`.
- Invariant tests are append-only. Extend, don't weaken.
- Each phase's accept criteria become an integration test (Nim headless, or a logos-qt-mcp script for UI phases) before implementation.
- The module imports nothing from `ui/`. The UI reaches the module only through the logos API under capability policy. Inter-module calls go through logos-core.
- The educational layer explains what the code already guarantees — it never adds a code path the invariants don't cover. If a lifecycle step can't be shown truthfully, that's a product bug, not a copy problem.

## Layout

```
module/   Nim backend → muster-module.lgx
  src/    api · schemas · dcbor · crypto · log · intents · drivers · transport · plugins
ui/       QML frontend → muster-ui.lgx (theme from prototype tokens; logos-qt-mcp tests)
infra/    anvil fixtures (Safe 1.4.1)
docs/     vision · furps · plan · adr/
```

## Commands

```
nix develop                      # dev shell (Nim toolchain, Qt6, deps)
nix build '.#module'             # muster-module.lgx (dev variant)
nix build '.#ui'                 # muster-ui.lgx
nix build '.#tests'              # unit + property + conformance
nix run  '.#integration'         # two isolated logoscore instances, stub + safe drivers
nix run  '.#anvil'               # local chain with Safe fixture
./runtime_cli loop 8543 "load libmuster.so"   # poc2-style TCP host (P0–P3 harness)
# UI e2e: basecamp --user-dir per instance + logos-qt-mcp scripts in ui/tests/
```

## Current phase

P0 — module scaffold loading cleanly in `logoscore`, CDDL/dCBOR schemas with golden vectors, signed hash-linked log. See `docs/02-implementation-plan.md` for accept criteria.
