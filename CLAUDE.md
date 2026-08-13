# CLAUDE.md

**Muster** — a local-first client for coordinating multi-party transactions inside conversations, on the Logos stack. The conversation is the security boundary. The first mission is education: walk people through the entire transaction lifecycle, showing at each step how Logos maintains privacy and security and where other stacks leak (`docs/00-vision.md`). The end state is a usable client for doing things together, securely and privately.

Built as logos-core modules: a Nim backend (`muster-module.lgx`) and a QML frontend (`muster-ui.lgx`), hosted by logos-basecamp (GUI) and `logoscore` (headless). Full requirements: `docs/01-furps.md`. Phase plan: `docs/02-implementation-plan.md`. UI reference: `ui/prototype/coordination-prototype-v2.html` (tokens, components, copy voice) — a self-contained, no-crypto HTML/JS simulation of the six-step legend. It is not the app; it drives the QML build in P4 and should keep pace with the FURPS/plan as they evolve, but where prototype and FURPS conflict, FURPS wins.

## Invariants — violating any of these is a bug, whatever the tests say

1. **Effects are reviewed; materializations are signed; the client re-derives the materialization and refuses on mismatch.** This check lives in the module core and cannot be disabled (F-4, FS-6).
2. **Every signing payload commits to environment, account, slot, and expiry.** A signature must be worthless anywhere else (F-5, FS-3).
3. **Plugins never sign, never hold keys, never touch the network.** They emit typed blocks only; there is no plugin canvas (F-12, F-13, FS-5).
4. **State = reduce(log).** Nothing exists that can't be rebuilt from log + keys. Reducers are idempotent; convergence under reorder/duplication is a property test (R-2, R-3).
5. **Deterministic bytes on signing paths.** The same value always encodes to the same bytes: CDE bytewise-lex map ordering (never length-first), shortest integers, no indefinite lengths, no floats. Every hash is a domain-separated `hash-input` record; no ad-hoc concatenation. This is ours to enforce — the platform's own transport encoding is non-canonical, so determinism cannot be inherited.

   5b is **not** an invariant: *which profile derives schema identity* is versioned and swappable. Every signing payload carries `profile` + `schema-id`; v0 uses hand-assigned ids (`muster.event.*.v1`), cdCDDLe schema roots slot into the same field when those specs ratify (ADR-009). Do not let 5b's flexibility leak into 5 — changing the derivation must never weaken F-5.
6. **The core never interprets contribution bytes** — drivers do. Rounds, serialization domain, membership model, and finality are driver-described, never hardcoded (F-6, F-7).
7. **Membership epochs are real:** adding a member re-keys forward; they cannot read earlier epochs (F-16). The UI seam depends on this.
8. **No server, no telemetry.** Store nodes and RPC are untrusted, user-configurable infrastructure (FS-1, FS-8).
9. **Anonymous drivers stay anonymous** end to end: no signer identity in UI state, logs, or ordering (FS-7).
10. **Nothing is signed whose inputs can't be accounted for.** Every signing payload commits to a provenance record naming, for each input that reached the signed bytes, its class (plugin block, driver-interpreted contribution, external read, peer message) and its log position — and signing is *refused* when any input's origin is unaccountable. Invariant 1 proves a materialization is consistent with its effect; it says nothing about where the effect's inputs came from, so correctly-derived data of unknown origin passes it. Class and position only, never identity — 9 must survive the trail — and the record is a reduction over the log, never a side-car store (4). Spec `derived-exo-3a1`.

## Pattern sources

**The contract is `muster.lidl`** — LIDL (`logos-co/logos-lidl`) is the platform's language-neutral module contract, and Muster is contract-first: methods, events, and record types are declared there and the callable surface is generated from it. Its type vocabulary is CDDL's (`tstr`, `bstr`, `int`, `uint`, `?`, `;`) plus `result`; its spec is explicit that CDDL describes data and LIDL describes interfaces — so CDDL-family types describe our log, LIDL describes our API, and wire encoding is out of LIDL's scope entirely. Never hand-write what the contract should generate.

**The Nim gap** is a codegen backend over `lidl_c.h`'s JSON bridge (`lidl_parse_to_json` / `lidl_serialize_from_json` / `lidl_validate_json` / `lidl_free_string`); `logos-rust-sdk/lidl-gen/src/lidl_ffi.rs` is the worked example at ~106 lines. Two rules the header states: free every returned string with `lidl_free_string`, and read optionality from the derived `isOptional` / `valueType` keys, never from the raw `optional` / `type` spelling.

**The Nim-behind-FFI half** is `logos-storage/logos-storage-nim` → `logos-co/logos-storage-module`: a Nim engine behind a C API (`library/libstorage.h`) with generated module glue. Copy its FFI shape and its async-callback seam, including the `abandoned` flag that prevents use-after-free on caller timeout. Built with `mkExternalLib` + `logos-module-builder` from one `metadata.json` (ADR-008).

**Read, don't copy:**

- `logos-co/logos-core-poc2` — a Nim reading of the draft specs. Take its `nimble.lock` pin set and project mechanics; do **not** lift `shell.nim` — its symbol set targets a runtime `logoscore` does not load. Its `schemas.nim` is a line-based CDDL extractor and `cbor_stuff.nim` defers canonicalization; both are ours to build properly. Its tests track behavior, not intent — never copy them as spec.
- `logos-co/logos-lips` branch `draft/logos-core-module-specs` — the LOGOS-MODULE-* specs and cdCDDLe. **Unmerged draft**, tracked not targeted. Adopt the cheap invariant-critical parts (deterministic encoding, domain-separated hash inputs); defer schema roots and verified views until ratification. Where any of it diverges from what `logoscore` actually loads, the shipping host wins.

Re-validate the stack decisions table in `docs/02-implementation-plan.md` against upstream HEADs at the start of every phase. The platform moves faster than these docs.

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
module/   Nim core behind a LIDL contract → wrapped as muster-module.lgx
  src/    api (muster.lidl + generated surface — the only outward seam) · schemas · dcbor · crypto · log · intents · drivers · transport · plugins
ui/       QML frontend → muster-ui.lgx (Logos.Theme + prototype tokens, ADR-011; logos-qt-mcp tests)
  prototype/  coordination-prototype-v2.html — the standalone HTML reference build
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
lgpm install --file ./result/*.lgx && logoscore    # load the module in the headless host
# UI e2e: basecamp --user-dir per instance + logos-qt-mcp scripts in ui/tests/
```

## Current phase

P0 — **first, the loading spike**: a two-method `muster.lidl`, its Nim surface generated over the `lidl_c.h` bridge, loading and answering one call in `logoscore`. It exercises the one part with no precedent (the Nim backend), not the two parts that have one. Everything downstream assumes this works; confirm it in days, not at P4. Then dCBOR golden vectors, domain-separated hash inputs, and the signed hash-linked log. No CDDL parser and no cdCDDLe in P0 (ADR-009). See `docs/02-implementation-plan.md` for accept criteria.
