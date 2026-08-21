# Muster — Implementation Plan

Companion to `01-furps.md`. Requirement IDs (F-x, FS-x, U-x, R-x, P-x, S-x) refer to that document. Phases are ordered so that every phase ends with something runnable and tested, and the UI arrives only after the protocol core is proven headless.

Target platform: **logos-core**. The backend is a Nim core behind a published LIDL contract, wrapped as a module and packaged as `.lgx`; the frontend is a QML module rendered inside **logos-basecamp** (and launchable standalone, following the pattern of the other platform UIs). Headless phases run on the **`logoscore`** CLI runtime. This is the same shape as the existing Storage and Chat modules — both are non-C++ engines behind a generated module surface — so distribution, loading, capability policy, and packaging are platform problems already solved.

---

## Stack decisions

Made so work can start; each is one veto away from changing.

**Re-validated 2026-08-04** against the current HEADs of logos-liblogos, logos-module-builder, logos-cpp-sdk, logos-rust-sdk, logos-protocol, logos-storage-module, logos-storage-nim, logos-delivery-module, logos-chat-module, logos-design-system, logos-package-manager, logos-core-poc2, and logos-lips. Rows that changed carry the reason. Re-run this validation at the start of every phase — liblogos moved 85 commits and split into a dozen repos in the four months before this pass.

| Area | Choice | Why |
|---|---|---|
| Backend language | Nim, chronos async throughout | Ecosystem-native, and now directly precedented: `logos-storage-nim` is a shipping Nim engine in the platform — 131 files on chronos, zero on std asyncdispatch |
| Module authoring | Contract-first: publish `muster.lidl`, generate the module surface, Nim core behind it | LIDL is the platform's language-neutral module contract (`logos-co/logos-lidl`). Contract-first is the path C++ and Rust modules already take; the missing piece is a Nim backend, which is a bounded contribution rather than a fork. See ADR-008 |
| LIDL backend | Nim codegen over the `lidl_c.h` JSON bridge, modelled on `logos-rust-sdk/lidl-gen` | The frontend (lexer, parser, AST, serializer, validator) is done and dependency-free; `lidl_c.h` exposes parse/serialize/validate as four C functions exchanging JSON. Rust's bridge to it is ~106 lines; the rest is language-specific emission |
| Frontend | QML on Qt 6, over `Logos.Theme` / `Logos.Controls` from logos-design-system | Basecamp is Qt 6. The platform now ships a design system; prototype v2 tokens map onto it rather than replacing it. See ADR-011 |
| Platform | logos-core modules (`.lgx`) | Subprocess isolation, capability-scoped inter-module calls, dependency graph, package manager distribution — for free. `lgpm`/`lgpd`/`logoscore` and `nix-bundle-lgx` all confirmed real |
| Hosts | `logoscore` (headless), logos-basecamp (GUI) | Headless CLI runtime carries P0–P3 and CI; basecamp carries P4+ |
| Build | Nix flakes via **logos-module-builder** (`metadata.json` + ~70-line flake, glue generated); nix-bundle-lgx for packaging | Changed: the platform convention is no longer a hand-rolled cpp-sdk module shell. The builder has no first-class Nim authoring path, which is why our Nim rides the external-lib route behind the generated contract surface |
| Module contract | Production: `metadata.json` + a published `.lidl` contract on the `cdylib` path. LOGOS-MODULE-* is tracked, not targeted | Changed: the LOGOS-MODULE-* specs are still unmerged draft (`logos-lips` branch `draft/logos-core-module-specs`, last commit 2026-07-13, 13 ahead of master). Building to them today produces a module the shipping host cannot load. LIDL is the contract layer that actually ships |
| Event encoding | Logos deterministic CBOR profile (draft LOGOS-MODULE-INTERFACE §4.5) over vacp2p nim-cbor-serialization — **as Muster's own signing-path encoding**, not as platform conformance | Changed in framing. Nothing in the platform requires determinism: `logos-protocol`'s CBOR is `nlohmann::json::to_cbor`, interchangeable with JSON per-connection via `--client-codec`. We need determinism because we sign; we cannot inherit it. poc2 defers canonicalization (`cbor_stuff.nim:14` — "P1/P2: Full canonicalization"), so that layer is ours regardless |
| Schema identity | v0: hand-assigned stable ids (`muster.event.*.v1`) carried in a versioned `profile` + `schema-id` field. cdCDDLe schema roots slot into the same field later | Changed: cdCDDLe and the hash profile are draft-only. The security property in F-5 — a signature cannot be reinterpreted under a different effect schema — holds under either derivation. See ADR-009 |
| Dependencies | Pinned to poc2's lockfile: Nim 2.2.10, chronos 4.4.0, cbor_serialization 0.4.1, stew 0.5.0, results 0.5.1, unittest2 0.2.5, npeg 1.3.0 | Verified verbatim against `nimble.lock` at HEAD. Caveat: poc2 is a single squashed commit ("Initial version", 2026-07-28) — treat it as a snapshot, not a maintained upstream |
| Crypto | nimcrypto, nim-secp256k1, nim-eth | Ecosystem-standard; ECIES over secp256k1 for epoch key wrap keeps identity and encryption on one curve (F-14) |
| EVM | nim-web3 + vendored Safe 1.4.1 ABI; EIP-712 implemented locally | No Safe Transaction Service anywhere — signature collection is our transport's job. EIP-712 is small and test-vectored |
| Chain harness | foundry/anvil | Deterministic Safe fixtures in CI |
| UI testing | logos-qt-mcp; evaluate logos-test-framework at P4 | qt-mcp drives the running QML app (find, click, screenshot, assert) and is directly usable by Claude Code. `logos-test-framework` is now a module-builder input and may be the newer path — decide at P4, not before |
| Tests | Nim unittest + property-style generators for convergence; GTest only where the platform side demands it | R-2 convergence is a property, not an example |
| CRDT library | none | Signed hash-linked log with causal refs and deterministic tiebreak covers R-2; revisit only if merge semantics outgrow it |
| License | Dual MIT / Apache-2.0 | Matches every logos-core platform repo — every repo pulled in the re-validation carries both files. ADR-001 resolved |

Library gaps the ecosystem choice creates, all implement-from-spec with published test vectors: the §4.5 deterministic CBOR profile (P0, small — the spec is five rules), EIP-712 hashing (P2, small), FROST (P6, real work — see phase note). The npeg-backed CDDL parser and the cdCDDLe canonical schema model are **no longer P0 gaps** — deferred per ADR-009.

## What we build on, and what we only read

Two different things got conflated in the first draft of this plan: the runtime the platform *ships*, and the runtime the specs *describe*. They are not the same runtime, and Muster targets the first.

### The contract layer: LIDL

`logos-co/logos-lidl` is the platform's **language-neutral module contract**: a lexer, parser, AST, serializer and validator for the Logos Interface Definition Language, in dependency-free standard C++. A `.lidl` artifact declares one module's callable surface — metadata, `depends`, record types, `method`s with parameters and return types, and fire-and-forget `event`s. Each SDK supplies a codegen backend over that shared frontend, so a module can be called from any other language without building, linking, or sharing source with it.

**Muster is contract-first: `muster.lidl` is the module's public surface**, and the Nim core sits behind what it generates. This replaces the hand-written bespoke C API the previous draft of this plan assumed — a bespoke header would have been a private convention where the platform already has a published one.

Two properties make this land well for us:

- **Its type vocabulary is CDDL's** — `tstr`, `bstr`, `int`, `uint`, `float64`, `bool`, `any`, `?` for optional, `;` comments — plus `result` (structured success/value/error), which CDDL lacks. The spec's own "Why not just use CDDL?" section is the cleanest statement of the split we arrived at independently: *CDDL describes data, not interfaces*. It has no notion of a method, an event, or a module. So CDDL-family types describe our log, LIDL describes our API, and they are complementary rather than competing.
- **Wire serialization is explicitly out of LIDL's scope.** It says nothing about encoding, which means ADR-009 is untouched by adopting it: our deterministic signing-path encoding remains entirely ours.

Also worth designing around: `logos-rust-sdk`'s cross-language doctest shows a consumer binding an **interface dependency** — coding against a contract's *shape*, then binding it to a concrete provider at runtime (`GreeterClient::bind("cpp_greeter_module")`) with no build-time coupling. That is a better shape than a hard dependency for both ADR-006 and ADR-010: Muster codes against a delivery contract and a chat contract, and which module satisfies them stays a runtime decision.

### The Nim gap, and what fills it

There is no Nim SDK. The frontend is done and the bridge exists: `include/lidl/lidl_c.h` exposes `lidl_parse_to_json`, `lidl_serialize_from_json`, `lidl_validate_json`, and `lidl_free_string` — four C functions exchanging the AST as JSON, expressly so non-C++ SDKs reach the canonical parser without reimplementing the grammar. `logos-rust-sdk/lidl-gen/src/lidl_ffi.rs` binds it in ~106 lines; the remaining ~3.2k is Rust-specific emission.

So the work is a Nim backend, not a parser. Two cautions the C header states outright: strings are malloc'd and must be freed with `lidl_free_string`, and optionality must be read from the derived `isOptional` / `valueType` keys — never from the raw `optional` / `type` spelling, which exists only so the wire form round-trips.

For the Nim-behind-FFI half, `logos-storage/logos-storage-nim` → `logos-storage-module` is the worked example: a Nim engine behind a C API (`library/libstorage.h`, `libstorage.nim`, `ffi_types.nim`, `alloc.nim`, thread-request plumbing) with generated module glue. Copy from it:

- **The external-lib build path** — `mkExternalLib` + `logos-module-builder`, driven by one `metadata.json`.
- **The contract-is-the-API discipline** — storage's `CLAUDE.md` insists method signatures, `metadata.json` events, and emitted event strings stay in sync. Contract-first makes this structural rather than a rule to remember: `muster.lidl` is the single source, everything else is generated from it.
- **Async-over-FFI** — storage's split between fire-and-forget event-emitting callbacks and blocking sync getters, including the `abandoned` flag that prevents use-after-free when a caller times out. We need exactly this seam between chronos and the host thread.

### logos-core-poc2: reference, not skeleton

`logos-core-poc2` implements the *draft* module specs. It is a useful Nim reading of them, and its dependency lockfile is our pinned set (verified verbatim). But its exported symbol set and CBOR dispatch target the spec runtime, **not** the host basecamp loads today — so lifting `shell.nim` verbatim would produce a module the platform cannot run. Read it for:

- **Project mechanics**: `nimble setup -l` with local `nimbledeps/`, `nimble.lock`, `config.nims`, unittest2. Take these directly.
- **`runtime_cli loop`**: still useful as a throwaway two-instance harness if it saves time, but ADR-008 no longer makes it the P0–P3 dev host.
- **What not to inherit**: `schemas.nim` is a line-based CDDL extractor (`splitLines`, `line.contains("=")`) the authors treat as provisional. `cbor_stuff.nim:14` marks canonicalization as future work — "P1/P2: Full canonicalization (sorted keys, shortest integers, no tags)". Deterministic encoding is ours to build either way.
- Its tests were generated from the implementation to track behavior, not to encode intent — never copy them as spec.

### The draft specs: tracked, not targeted

The LOGOS-MODULE-* specs and cdCDDLe live on `logos-lips` branch `draft/logos-core-module-specs` (`docs/logos-core/spec-{module-interface,module-transport,module-runtime,module-commitment-model,module-hash-profile,cdcddle}.md`). Actively worked through mid-2026, still unmerged. We read them for design, and we adopt the parts that cost little and pay off immediately — deterministic encoding rules, domain-separated hash inputs. We do not adopt schema roots or verified views until they ratify (ADR-009).

The one thing worth watching: the commitment model's **verified views** — Merkle inclusion/absence proofs at typed semantic paths — are the natural fact-card proof channel for F-10. Until they ratify, F-10's `verified-locally` grade must be earned some other way (P5 note).


## Repository layout

One repo, two `.lgx` outputs. Split into module/ui repos later only if the platform's conventions demand it.

```
muster/
  CLAUDE.md                    # invariants + commands (repo root)
  flake.nix                    # builds module, ui, tests; dev shell
  docs/
    00-vision.md
    01-furps.md
    02-implementation-plan.md
    adr/                       # one file per decision gate below
  module/                      # Nim backend → muster-module.lgx
    src/
      api/                     # muster.lidl (normative contract) + generated surface — the only outward seam
      schemas/                 # CDDL sources + generated Nim types + golden vectors
      dcbor/                   # deterministic CBOR encode/decode
      crypto/                  # keys, sign/verify, envelope + epochs
      log/                     # hash-linked signed log, causal order, reducers, persistence
      intents/                 # effect types, lifecycle reducer, expiry
      drivers/                 # interface, conformance suite, stub, safe
      transport/               # interface, local/memory, messaging impl (ADR-006)
      plugins/                 # runtime, manifest enforcement, first-party
    tests/
  ui/                          # QML → muster-ui.lgx
    qml/                       # theme singleton (prototype tokens), components, home, composer, room
    tests/                     # logos-qt-mcp scripts (the six-step legend, U-1..U-9)
  infra/
    anvil/                     # Safe 1.4.1 deployment fixtures
```

## Phases

> **Status (2026-08-21):** P0 ✅ · P1 ✅ · P2 ✅ · P4 🚧 (UI spike; blocked on an SDK-rev skew, `exo-c6a`) · P3 deferred past the P4 spike · P5–P6 not started. The 11 invariant pebbles are all closed and the 42-probe suite is green; the `module/`+`ui/` build landed across 2026-08-19/20. Per-phase status lines below.

### P0 — Module scaffold and the log

**Status: ✅ done (2026-08-19).** Loading spike passed (Nim-native module loads + dispatches in `logoscore`, Route B — a `codegen.nim` path added to `logos-module-builder`, PR #202 open upstream). dCBOR CDE encoder, domain-separated hash-input records, and the signed hash-linked log all landed with probes green (`exo-d7c`/`449`/`548`). No CDDL parser / cdCDDLe, per ADR-009.

**Step zero is a loading spike, before any Muster code.** Write a two-method `muster.lidl`, generate its Nim surface over the `lidl_c.h` JSON bridge, and get the resulting module loading and answering one call in `logoscore`. Everything downstream rests on this working; the storage-nim and rust-sdk precedents say it does, but we confirm it in days rather than discovering it at P4. The spike deliberately exercises the part with no precedent — the Nim backend — not the part with two. If the backend stalls, hand-write the generated surface for this one contract and keep going (ADR-008 fallback); either way `muster.lidl` stays normative and we know which world we are in before P0 proper.

Then: Nimble project with poc2's pinned dependency set. The §4.5 deterministic CBOR profile implemented over nim-cbor-serialization, with golden vectors that specifically catch the CDE-vs-RFC-8949 map-ordering trap (bytewise-lex of encoded keys, never length-first). Domain-separated structured `hash-input` records with our own domain tags (`muster.event.*`) everywhere we hash or sign — never ad-hoc concatenation. Schema identity per ADR-009: hand-assigned stable ids in a versioned `profile` + `schema-id` field, no CDDL parser and no cdCDDLe. Signed hash-linked log: append, ingest-verify (FS-2), causal ordering with deterministic tiebreak, reducer framework (R-3), all on chronos.

**Accept:** the module loads, dispatches, and unloads cleanly in `logoscore`. dCBOR golden vectors pass, including the map-ordering trap. Re-encoding any signed payload reproduces its bytes exactly, and every hash in the log is a domain-separated `hash-input` record — a test asserts no signing path uses raw concatenation. Two in-memory logs exchanging events in adversarial orders (shuffled, duplicated, interleaved) converge to byte-identical reduced state as a generated-input property test. A tampered event and a non-member event are rejected with distinct errors.

### P1 — Intent engine, driver interface, stub driver

**Status: ✅ done (2026-08-19).** Intent lifecycle engine (F-3), driver interface + opaque core (inv 6), re-derive-or-refuse materialization (inv 1), replay-bound signing payload (inv 2), plus anonymity (inv 9), epochs (inv 7), provenance (inv 10), plugin sandbox (inv 3), no-server (inv 8). B4 (`tools/lidl_gen.nim`) generates the surface from `muster.lidl`. `propose`/`approve`/`status` run through the hosted `logoscore` module over the stub driver.

Effect types (transfer v0), authorization-requirement list (F-19), lifecycle reducer (F-3), expiry. Driver interface exactly per F-6, including round index (F-7), serialization domain, membership model, finality descriptor. Stub driver: in-memory 2-of-3, r=1, sequential domain. Conformance suite v0 written against the stub (S-1). Signing payloads strengthen F-5: they commit to the effect's **schema identity** and effect value root alongside environment, account, slot, and expiry — a collected signature cannot be reinterpreted under a different effect schema. Per ADR-009 the identity is a hand-assigned stable id in v0; the field is shaped so a cdCDDLe schema root replaces it without a format migration. `muster.lidl` grows `propose` / `approve` / `status` methods and the lifecycle-change event, so `logoscore` is the CLI harness as-is and the UI's typed client at P4 is generated, not hand-written.

**Accept:** full lifecycle to `executable` across two `logoscore` instances with isolated persistence paths; conformance suite green; replay-binding unit tests prove a contribution fails verification outside its (conversation, account, slot, schema) context (FS-3). Changing only the `schema-id` on an otherwise identical payload invalidates the signature.

### P2 — Safe driver (the wedge)

**Status: ✅ done (2026-08-19).** EIP-712 `safeTxHash` (validated against published Safe 1.4.1 constants), secp256k1 ECDSA owner verification, collect-2-of-3, `assemble`/`submit`/`watch` via JSON-RPC (no web3 dep), and on-chain `execTransaction` against an anvil `MiniSafe` fixture (`infra/anvil/src/MiniSafe.sol`, a faithful Safe-1.4.1 subset) — **no indexer in the loop**. Wired into the hosted module (`txhash` exposed; `approve` verifies each owner sig before it counts). Fixture-swap to the real Safe 1.4.1 singleton remains. *Nuance vs. the accept criterion:* the two-`logoscore`-instance run was exercised through the hosted single-module surface + direct Nim e2e, not yet two isolated hosts over transport (that lands with P3).

Anvil fixture deploying Safe 1.4.1 as 2-of-3. `canonicalize` computes the EIP-712 safeTxHash locally (implementation validated against published vectors); `verify` checks ECDSA contributions against owners; `assemble` builds `execTransaction`; `submit` via user RPC through nim-web3; `watch` maps confirmations to a finality descriptor (R-8). Sequential-domain queueing with visible queue and `intent-drop` freeing the slot (F-8).

**Accept:** two `logoscore` instances collect 2-of-3 and execute against anvil **with no Safe indexer or service in the loop**; conformance green for the Safe driver; wrong-chainid / wrong-safe / wrong-nonce contributions all rejected.

### P3 — Real transport and encryption

**Status: ⏸ deferred past the P4 UI spike, not started.** The hosted flow still runs on the stub/local transport. ADR-010 (chat-module build-vs-consume) is still open and must be resolved at the start of this phase — the curve conflict noted below (chat-module identity is Ed25519, Muster signs secp256k1) is the blocking question.

ADR-006 is resolved: consume `logos-delivery-module` as a module dependency under the capability policy, behind our Transport interface. It wraps `liblogosdelivery`, and its API covers what F-15 needs — content topics, publish with delivery/propagation events, subscribe, store queries, and channels. The Transport interface stays, so embedding nwaku remains reachable if the module's guarantees turn out thinner than advertised.

Resolve **ADR-010** at the start of this phase: `logos-chat-module` already provides e2e-encrypted 1:1 and group conversations over `delivery_module`. Decide build-vs-consume against F-16 and FS-7 before writing epoch code — the deciding question is whether its membership model re-keys forward provably, and whether we can verify that claim rather than trust it. If it does, F-16 becomes a dependency; if it doesn't, we build epochs ourselves and say so in the ADR.

If we build: envelope encryption with a per-conversation epoch key, ECIES-secp256k1 wrap to members, re-key on every membership change (F-16). Either way: durable outbox with retry and idempotent ingest over store duplicates (R-1, R-2, R-4).

**Accept:** the P2 flow runs between clients on separate networks through store nodes; a member added mid-conversation provably cannot decrypt earlier epochs (test — this test exists and must pass whether the epochs are ours or the chat module's); kill a client mid-collection, restart, and the contribution still lands (R-4, R-6).

MLS is explicitly out of scope for v0; the epoch scheme is the ADR-002 default, revisited post-P6.

### P4 — QML surfaces in basecamp

**Status: 🚧 in progress, blocked (`exo-c6a`).** ADR-011 resolved: the UI is restyled onto `Logos.Theme`/`Logos.Controls`. `muster-ui` builds, calls `muster_module` through the logos API, and the re-materialization strip is wired to the real driver `canonicalize` (F-4) — no longer prototype theater. **Blocked short of acceptance** by an SDK-rev skew between `logos-module-builder`'s Nim-cdylib codegen and `logos-basecamp`'s ui-host (`logos-view-module-runtime` 1fde7d43 vs 3c3735c2; `logos-cpp-sdk` 4b66dac0 vs e3744fb8): pinning view-runtime fixes a `std::bad_alloc`, but aligning cpp-sdk regresses to it because the codegen's view-glue targets the older rev. **Fix is upstream** — update the module-builder's Nim-cdylib codegen to cpp-sdk 4b66dac0 (keep view-runtime 1fde7d43), then run the logos-qt-mcp acceptance flow (enable `muster_ui` in basecamp's Package Manager, click its icon, assert `health() -> ok`). `logos-standalone-app` renders no `ui_qml` view on this box (its own template blanks); `logos-basecamp` is the working host. The full room/composer/home surfaces and the six-step legend are still ahead — this increment proves the module↔ui↔host chain, not the whole UI.

Resolve **ADR-011** first: build on `Logos.Theme` / `Logos.Controls` from logos-design-system, mapping the prototype v2 tokens onto its palette/spacing/typography singletons, and reach for a bespoke component only where the room surfaces genuinely have no design-system equivalent (the enclosure, the seam, the slot row). Muster looking like the rest of the platform is worth more than pixel-fidelity to the prototype, and U-10's contrast and reduced-motion obligations are easier to inherit than to re-prove.

`muster-ui.lgx`: components (room enclosure, nameplate, pinned bar, intent card, fact card, choice, seams, sheets); home (F-18 as a live query), composer (verb → people → account), room. UI talks to the module only through the logos API. Wire the re-materialization strip to the real driver `canonicalize` (F-4) — in the prototype it was theater; here it is the check. Standalone-mode launch (via logos-standalone-app) and basecamp-hosted mode both work, per platform convention.

The walkthrough's four questions (`00-vision.md`) become real surfaces here, including the fourth — what is still open at this step and what would close it. Per ADR-012 the claims are data, not prose baked into QML: each carries its requirement ID, its evidence, and, for a gap, the fix and that fix's real status.

**Accept:** the prototype's six-step legend is reproducible end-to-end as a UI test running in CI against two `--user-dir`-isolated basecamp instances; U-1 through U-9 each have an assertion or screenshot; keyboard pass (U-10). The claims registry validates in CI: every protection claim resolves to a requirement ID that exists and to a test that exists, and every gap claim carries a fix with a status from the closed set (ADR-012). Pick logos-qt-mcp or logos-test-framework at the start of this phase on which one CI can drive two isolated instances more cleanly — the assertions are the deliverable, not the harness.

### P5 — Plugin runtime v0

**Status: not started.** Only the plugin sandbox *type* exists (`src/plugins/plugin.nim`, inv 3 — emits typed blocks only, no signing/keys/network); the manifest, content-hash load verification, and first-party plugins are P5 work.

Manifest with declared capabilities and data dependencies (F-12); content-hash verification at load (FS-5); typed block emission only (F-13). First-party plugins in-process behind the manifest: transfer, signed-balance, decision (binds per F-11). The fact proof channel: if LOGOS-MODULE-HASH-PROFILE has ratified by this phase, use **verified views** (§7.6/§8) — the signed-balance plugin discloses the balance field under a committed value root with proof material, the client runs the spec's verification procedure. If it is still draft, F-10's `verified-locally` grade is earned the narrower way: the client performs the read itself against a user-configured RPC endpoint and checks the result, and any fact it could not check itself renders as `attested`. Either way the grade means exactly what it says on the card — the honesty rule in `00-vision.md` does not bend to a missing spec, it just shrinks what we are allowed to claim. Third-party isolation is ADR-007: capability-restricted `.lgx` modules whose access policy denies everything except the Muster module's block API — the platform's subprocess + token model **is** the sandbox. Documented now, built post-v1. The plugin API freezes only when the third first-party plugin needs no core change.

**Accept:** the lying-plugin test — a plugin whose proposed materialization diverges from its displayed effect is blocked by core (FS-6), demonstrated in CI, not by review. A first-party plugin attempting network or key access dies with a capability error.

### P6 — Hardening and reach

**Status: not started.**

Keycard signer backend over PC/SC (F-14). Logos Storage module as the artifact backend behind the storage interface (F-17). Threshold driver: FROST at r=2 is the round model's real test (F-7) — no Nim implementation exists, so this is implement-from-spec against the conformance suite, with a C library binding as the fallback if the from-spec path stalls. A describe-only LEZ driver spike to pressure-test membership-as-predicate against the platform's private execution direction. Log snapshotting to hit P-2/P-5. Performance pass against every P-x number.

**Accept:** conformance green across stub, Safe, and threshold drivers; anonymous slots leak nothing (FS-7 audit); cold-start and catchup benchmarks in CI.

## Decision gates (ADRs)

- **ADR-001 License** — resolved: dual MIT / Apache-2.0, matching the platform.
- **ADR-002 Encryption** — epoch scheme above for v0; MLS evaluated after P6.
- **ADR-003 Ordering anchor** — causal log with deterministic tiebreak; Logos Blockchain anchoring only if a governance-room use case demands disputable ordering.
- **ADR-004 Intent placement** — resolved: intents are conversation-log entries; home is a derived index over them.
- **ADR-005 Anonymous rooms** — nameplate names readers; slots never name signers; scope sheet carries the two-sets explanation (U-9).
- **ADR-006 Transport source** — resolved: consume `logos-delivery-module` under the capability policy, behind our own Transport interface. Its API covers content topics, publish/subscribe with delivery events, and store queries. The interface keeps embedded nwaku reachable if those guarantees prove thinner than documented.
- **ADR-007 Third-party plugin isolation** — capability-restricted `.lgx` modules under the platform's access policy. Post-v1.
- **ADR-008 Module shape and dev host** — resolved, replacing the earlier `runtime_cli` decision. Muster is **contract-first**: `muster.lidl` is the module's public surface, the Nim core sits behind what it generates, and the module is built via `mkExternalLib` + logos-module-builder. The dev host is `logoscore` from P0, not poc2's `runtime_cli`. Rationale: the LOGOS-MODULE-* specs are unmerged draft and a spec-native module does not load in the host basecamp uses, so "build to the spec and both hosts are reachable" was false; meanwhile LIDL is the contract layer that actually ships, and it is deliberately language-neutral. Cost: there is no Nim SDK, so we write a codegen backend over `lidl_c.h`'s JSON bridge (`logos-rust-sdk/lidl-gen` is the worked example — ~106 lines of FFI, the rest language-specific emission). We take that cost because the alternative is a private convention where the platform has a published one, and because the backend is a clean contribution back. Fallback if the backend stalls: hand-write the generated surface for our own contract, keeping `muster.lidl` normative. Validated by the P0 loading spike.
- **ADR-009 Encoding and schema identity** — resolved. Split the encoding requirement in two. *Determinism and domain separation* (same bytes in, same bytes out; every hash a domain-separated `hash-input` record) is a hard invariant from P0 — cheap now, and retrofitting it later would invalidate every signature already made. *Which profile derives schema identity* is versioned and swappable: v0 uses hand-assigned stable ids carried in a `profile` + `schema-id` field committed inside every signing payload, and cdCDDLe schema roots slot into that field later without a format migration. Rationale: nothing in the platform requires deterministic encoding — `logos-protocol`'s CBOR is non-canonical and interchangeable with JSON per-connection — so conformance to the draft profile buys future portability, not present correctness, while implementing a draft spec on a signing path risks both rework *and* a corpus of signatures under a superseded profile. Re-evaluate when the specs ratify, or the first time a second module must parse Muster events.
- **ADR-010 Chat module build-vs-consume** — open, resolve at P3 start. `logos-chat-module` already does e2e-encrypted 1:1 and group chat over `delivery_module` (verified: it embeds no Logos Messaging node and calls delivery over the rust-sdk bus, which is the composition ADR-006 chose). Deciding questions: does its membership model re-key forward provably (F-16), can we verify that rather than trust it, does it leak signer identity in ways FS-7 forbids, and does it wire a *persistent* identity — `logos_chat::open()` mints an unpersisted account, and `chat-sqlite` has an `IdentityStore` the public facade does not use.

  **The curve conflict is the blocking issue, and it is confirmed at `logos-messaging/libchat` HEAD (2026-08-04).** `core/account/src/account.rs` holds `Ed25519SigningKey`/`Ed25519VerifyingKey` and derives `address()` as `hex::encode(verifying_key)`; `core/account/src/directory.rs` states it outright — "An Account (AccountAddress, an Ed25519 key) endorses a set of device keys." `core/crypto` is X25519 for DH and XEdDSA/Ed25519 for signatures. `secp256k1`/`k256` appear in the lockfile only as transitive `alloy` dependencies of `core/conversations`, never in the identity path.

  So libchat and F-14 hold the *same principle* — one curve serving both identity and encryption — on **different curves**. Consuming the chat/account layer therefore gives Muster two identities: a Curve25519 chat identity and the secp256k1 key that signs transactions. F-9 derives per-member role by intersecting chat membership with account membership, and that intersection needs an authenticated binding between the two keys which libchat does not provide. Resolve this before P3 writes any code: either F-14 changes, or the binding is designed and tested, or we build our own epoch layer and consume delivery only. Do not defer it into implementation.
- **ADR-011 Design system** — resolved (P4 start, 2026-08-20). Build `muster-ui` on `Logos.Theme` / `Logos.Controls` from logos-design-system and map prototype v2 tokens onto it, reaching for a bespoke component only where the room surfaces have no design-system equivalent (the enclosure, the seam, the slot row). Platform-consistent beats prototype-faithful; U-10's contrast and reduced-motion obligations are cheaper to inherit than to re-prove — and being platform-native is arguably the more honest look for an app whose whole argument is that it is composed from Logos modules. Three operational facts, learned from `demo/muster-ui` which already runs on this design system: (1) the `ui_qml` host supplies `Logos.Theme` / `Logos.Controls` on the QML import path, so neither is a `metadata.json` dependency — but that resolution is a *launch-time* fact, not a build-time one; (2) the authoritative token list is the design-system source (`Logos/Theme/*.qml` palette/spacing/typography keys, `Logos/Controls/qmldir` for the component set), never guessed — the traps are real (`Theme.palette.text` not `textPrimary`, `Theme.palette.error` not `danger`, `LogosButton.variant` not `flat`, and `private` is a reserved word in QML); (3) `nix build` does not evaluate QML, so a green build proves nothing — every QML increment is gated on `qmllint` against the import path *and* a launch, per `docs/labbook/qml-errors-are-invisible-to-nix-build.md`.
- **ADR-012 Claims registry** — resolved: walkthrough claims are structured data checked in CI, not prose in QML. The vision's honesty rules and FS-9 are the only requirements whose failure mode is *copy* — nothing breaks when a caveat quietly disappears, which is exactly how honest documentation rots. So each claim is a record: the lifecycle step, the claim text, a `kind` (`protects` | `others-leak` | `gap`), and evidence. A `protects` claim carries a requirement ID and a test name, both of which must resolve — a claim whose test is deleted fails the build. An `others-leak` claim carries the named system, step, and observer. A `gap` claim carries the fix and its status from a closed set: `shipped` | `specified` | `partial` | `none`, where `specified` also carries the spec's own lifecycle stage (a `raw` LIP is not a draft and neither is a promise). CI validates resolution and vocabulary; it cannot validate that a claim is *true*, which is why the rules in `00-vision.md` still bind the author. Built at P4 with the surfaces it describes.

## Working agreements for Claude Code

- Re-validate the stack decisions table against current upstream HEADs at the start of every phase. The platform moves faster than this document; a stale assumption found at P0 is cheap, the same one found at P4 is not.
- poc2 and the LOGOS-MODULE-* specs are reading material, not build targets (ADR-008). Where they diverge from each other the spec is the better read; where either diverges from what `logoscore` actually loads, the shipping host wins.
- Conformance before features: the suite (S-1) is written first and extended with every driver capability; no driver work merges red.
- Integration tests never mock `Driver` or `Transport` — use the stub driver and the local transport instead. Mocks hide exactly the seams this architecture exists to expose.
- Every FS requirement and F-4/F-5 has at least one test that fails if the invariant is violated. Treat those tests as append-only.
- No ad-hoc serialization where bytes get hashed or signed; dCBOR canonical encoding only.
- chronos only — never std asyncdispatch; mixing async backends in this ecosystem is how deadlocks are born.
- The module imports nothing from `ui/`; the UI reaches the module only through the logos API under capability policy; inter-module calls go through logos-core, never side channels.
- Prototype v2 (`coordination-prototype-v2.html`) is the UI reference: same tokens, same components, same copy voice. Where prototype and FURPS conflict, FURPS wins.
- Each phase's accept block becomes an integration test (Nim for P0–P3, logos-qt-mcp script for P4+) before implementation starts.
