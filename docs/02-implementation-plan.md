# Muster — Implementation Plan

Companion to `01-furps.md`. Requirement IDs (F-x, FS-x, U-x, R-x, P-x, S-x) refer to that document. Phases are ordered so that every phase ends with something runnable and tested, and the UI arrives only after the protocol core is proven headless.

Target platform: **logos-core**. The backend is a Nim module packaged as `.lgx` and hosted by `logos_host`; the frontend is a QML module rendered inside **logos-basecamp** (and launchable standalone, following the pattern of the other platform UIs). Headless phases run on the **`logoscore`** CLI runtime. This is the same shape as the existing Storage and Chat modules, so distribution, loading, capability policy, and packaging are platform problems already solved.

---

## Stack decisions

Made so work can start; each is one veto away from changing.

| Area | Choice | Why |
|---|---|---|
| Backend language | Nim, chronos async throughout | Ecosystem-native: nwaku and the storage client are Nim; chronos is the stack's async convention. Nim compiles to C, so the liblogos module interface is a thin shim |
| Frontend | QML on Qt 6 | Basecamp is Qt 6; status-desktop proved Nim+QML at scale; design tokens from the prototype port to a QML theme singleton |
| Platform | logos-core modules (`.lgx`) | Subprocess isolation, capability-scoped inter-module calls, dependency graph, package manager distribution — for free |
| Hosts | `logoscore` (headless), logos-basecamp (GUI) | Headless CLI runtime carries P0–P3 and CI; basecamp carries P4+ |
| Build | Nix flakes; module shell per logos-cpp-sdk conventions; nix-bundle-lgx for packaging | Every platform repo already works this way |
| Module contract | LOGOS-MODULE-* specs (interface, transport, runtime, commitment model, hash profile) + cdCDDLe | The contract logos-core-poc2 implements. Building to the spec keeps the module portable across liblogos (basecamp today) and the Nim spec runtime (where the platform is going) |
| Event encoding | Logos deterministic CBOR profile (LOGOS-MODULE-INTERFACE §4.5) over vacp2p nim-cbor-serialization | CDE bytewise-lex map ordering, shortest integers, no indefinite lengths, no floats. poc2 depends on the library but defers canonicalization — that layer is ours to build and contribute back |
| Schema identity | cdCDDLe canonical schema model + LOGOS-MODULE-HASH-PROFILE structured hash inputs | Stable schema roots for effects and events; domain-separated `hash-input` records replace ad-hoc byte concatenation everywhere we hash or sign |
| Dependencies | Pinned to poc2's lockfile: Nim 2.2.10, chronos 4.4, nim-cbor-serialization 0.4.1, stew, results, unittest2, npeg | Ecosystem-proven set; npeg backs a real CDDL parser to replace poc2's line-based extractor |
| Crypto | nimcrypto, nim-secp256k1, nim-eth | Ecosystem-standard; ECIES over secp256k1 for epoch key wrap keeps identity and encryption on one curve (F-14) |
| EVM | nim-web3 + vendored Safe 1.4.1 ABI; EIP-712 implemented locally | No Safe Transaction Service anywhere — signature collection is our transport's job. EIP-712 is small and test-vectored |
| Chain harness | foundry/anvil | Deterministic Safe fixtures in CI |
| UI testing | logos-qt-mcp | Drives the running QML app (find, click, screenshot, assert) — the e2e layer, and directly usable by Claude Code against a live instance |
| Tests | Nim unittest + property-style generators for convergence; GTest only where the platform side demands it | R-2 convergence is a property, not an example |
| CRDT library | none | Signed hash-linked log with causal refs and deterministic tiebreak covers R-2; revisit only if merge semantics outgrow it |
| License | Dual MIT / Apache-2.0 | Matches every logos-core platform repo. ADR-001 resolved |

Library gaps the ecosystem choice creates, all implement-from-spec with published test vectors: the §4.5 deterministic CBOR profile (P0, small — the spec is five rules), EIP-712 hashing (P2, small), FROST (P6, real work — see phase note).

## Reuse from logos-core-poc2

`github.com/logos-co/logos-core-poc2` is a working Nim implementation of the module specs. Steal directly:

- **Module skeleton** (`src/shell.nim`): the exported symbol set (`logos_module_name`, `logos_<name>_{name,schema,version,init,destroy,dispatch,free}`), embedded CDDL string with `_module`/`_version` metadata, the generic dispatch entrypoint decoding typed Nim objects via `Cbor.decode`/`Cbor.encode`, `allocShared` responses freed by the module's own free export. This is our module's outer shell, verbatim.
- **C ABI types** (`src/logos_core/abi_types.nim`): function pointer types and error codes per LOGOS-MODULE-INTERFACE §2.6, including the publish callback (pub/sub — how our module pushes conversation updates to the UI without polling) and the call-module callback (inter-module calls, our path to the messaging module).
- **Transport framing** (`src/logos_core/transport.nim`): 4-byte big-endian length prefix, tag byte, CBOR payload; Hello/Request/Response/Subscribe/Unsubscribe/Event/ProtocolError/Cancel. The code has an acknowledged TODO on tag placement — where code and spec diverge, follow the spec.
- **`runtime_cli loop`**: a TCP host serving loaded modules. Two instances of it are the two-client integration harness for P0–P3 — no basecamp, no liblogos, just the spec contract over sockets.
- **Project mechanics**: `nimble setup -l` with local `nimbledeps/`, `nimble.lock`, `config.nims`, unittest2.

Two caveats. poc2's own tests were generated from the implementation to track behavior changes, not to encode intent — do not copy them as spec; our conformance suite stays intent-first. And poc2's CDDL handling (`schemas.nim`) is a line-based extractor the authors clearly consider provisional — we build the real parser on npeg against the cdCDDLe profile instead of inheriting it.

What the specs give the architecture beyond packaging: the **commitment model + hash profile** define schema roots (via cdCDDLe), value roots over typed values, and **verified views** — Merkle inclusion/absence proofs at typed semantic paths, with a defined envelope and verification procedure. Verified views are the fact-card proof channel (F-10) we previously left as an open design; the platform specced it for us.

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
      api/                     # liblogos module interface shim (logos-cpp-sdk conventions)
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

### P0 — Module scaffold and the log

Module skeleton lifted from poc2's `shell.nim`, loading and dispatching in poc2's `runtime_cli` TCP host (ADR-008: that's the P0–P3 dev host; basecamp packaging lands at P4). Nimble project with poc2's pinned dependency set. The §4.5 deterministic CBOR profile implemented over nim-cbor-serialization, with golden vectors that specifically catch the CDE-vs-RFC-8949 map-ordering trap (bytewise-lex of encoded keys, never length-first). CDDL parser on npeg targeting the cdCDDLe profile; cdCDDLe canonical schema model for our event and effect schemas, producing schema roots via the hash-profile `hash-input` framing — reproducing the spec's Appendix A vector (the 831-byte hash input and its BLAKE3-256 digest) as a conformance test. Signed hash-linked log: append, ingest-verify (FS-2), causal ordering with deterministic tiebreak, reducer framework (R-3), all on chronos; every hash computed as a domain-separated structured `hash-input` record with our own domain tags (`muster.event.*`), never ad-hoc concatenation.

**Accept:** the module loads, dispatches, and unloads cleanly in `runtime_cli loop`. The Appendix A schema-root vector reproduces byte-for-byte. Two in-memory logs exchanging events in adversarial orders (shuffled, duplicated, interleaved) converge to byte-identical reduced state as a generated-input property test. A tampered event and a non-member event are rejected with distinct errors.

### P1 — Intent engine, driver interface, stub driver

Effect types (transfer v0), authorization-requirement list (F-19), lifecycle reducer (F-3), expiry. Driver interface exactly per F-6, including round index (F-7), serialization domain, membership model, finality descriptor. Stub driver: in-memory 2-of-3, r=1, sequential domain. Conformance suite v0 written against the stub (S-1). Signing payloads strengthen F-5: they commit to the effect's **schema root** (cdCDDLe identity) and effect value root alongside environment, account, slot, and expiry — a collected signature cannot be reinterpreted under a different effect schema. The module exposes `propose` / `approve` / `status` as dispatch methods, so poc2's `runtime_cli` is the CLI harness as-is.

**Accept:** full lifecycle to `executable` across two `runtime_cli` TCP hosts with isolated persistence paths; conformance suite green; replay-binding unit tests prove a contribution fails verification outside its (conversation, account, slot, schema) context (FS-3).

### P2 — Safe driver (the wedge)

Anvil fixture deploying Safe 1.4.1 as 2-of-3. `canonicalize` computes the EIP-712 safeTxHash locally (implementation validated against published vectors); `verify` checks ECDSA contributions against owners; `assemble` builds `execTransaction`; `submit` via user RPC through nim-web3; `watch` maps confirmations to a finality descriptor (R-8). Sequential-domain queueing with visible queue and `intent-drop` freeing the slot (F-8).

**Accept:** two `logoscore` instances collect 2-of-3 and execute against anvil **with no Safe indexer or service in the loop**; conformance green for the Safe driver; wrong-chainid / wrong-safe / wrong-nonce contributions all rejected.

### P3 — Real transport and encryption

Resolve ADR-006 first by inspecting the platform messaging module's exposed API: if it covers per-conversation topics, live delivery, and store catchup, consume it as a module dependency under the capability policy; if not, embed nwaku behind our Transport interface and migrate later. Envelope encryption: per-conversation epoch key, ECIES-secp256k1 wrap to members, re-key on every membership change (F-16). Durable outbox with retry and idempotent ingest over store duplicates (R-1, R-2, R-4).

**Accept:** the P2 flow runs between clients on separate networks through store nodes; a member added mid-conversation provably cannot decrypt earlier epochs (test); kill a client mid-collection, restart, and the contribution still lands (R-4, R-6).

MLS is explicitly out of scope for v0; the epoch scheme is the ADR-002 default, revisited post-P6.

### P4 — QML surfaces in basecamp

`muster-ui.lgx`: theme singleton carrying the prototype v2 tokens; components (room enclosure, nameplate, pinned bar, intent card, fact card, choice, seams, sheets); home (F-18 as a live query), composer (verb → people → account), room. UI talks to the module only through the logos API. Wire the re-materialization strip to the real driver `canonicalize` (F-4) — in the prototype it was theater; here it is the check. Standalone-mode launch and basecamp-hosted mode both work, per platform convention.

**Accept:** the prototype's six-step legend is reproducible end-to-end as a logos-qt-mcp script running in CI against two `--user-dir`-isolated basecamp instances; U-1 through U-9 each have an mcp assertion or screenshot; keyboard pass (U-10).

### P5 — Plugin runtime v0

Manifest with declared capabilities and data dependencies (F-12); content-hash verification at load (FS-5); typed block emission only (F-13). First-party plugins in-process behind the manifest: transfer, signed-balance, decision (binds per F-11). The fact proof channel is **verified views** per LOGOS-MODULE-HASH-PROFILE §7.6/§8: the signed-balance plugin discloses the balance field under a committed value root with proof material, the client runs the spec's verification procedure, and F-10's `verified-locally` grade means exactly "a verified view checked out on this device." Third-party isolation is ADR-007: capability-restricted `.lgx` modules whose access policy denies everything except the Muster module's block API — the platform's subprocess + token model **is** the sandbox. Documented now, built post-v1. The plugin API freezes only when the third first-party plugin needs no core change.

**Accept:** the lying-plugin test — a plugin whose proposed materialization diverges from its displayed effect is blocked by core (FS-6), demonstrated in CI, not by review. A first-party plugin attempting network or key access dies with a capability error.

### P6 — Hardening and reach

Keycard signer backend over PC/SC (F-14). Logos Storage module as the artifact backend behind the storage interface (F-17). Threshold driver: FROST at r=2 is the round model's real test (F-7) — no Nim implementation exists, so this is implement-from-spec against the conformance suite, with a C library binding as the fallback if the from-spec path stalls. A describe-only LEZ driver spike to pressure-test membership-as-predicate against the platform's private execution direction. Log snapshotting to hit P-2/P-5. Performance pass against every P-x number.

**Accept:** conformance green across stub, Safe, and threshold drivers; anonymous slots leak nothing (FS-7 audit); cold-start and catchup benchmarks in CI.

## Decision gates (ADRs)

- **ADR-001 License** — resolved: dual MIT / Apache-2.0, matching the platform.
- **ADR-002 Encryption** — epoch scheme above for v0; MLS evaluated after P6.
- **ADR-003 Ordering anchor** — causal log with deterministic tiebreak; Logos Blockchain anchoring only if a governance-room use case demands disputable ordering.
- **ADR-004 Intent placement** — resolved: intents are conversation-log entries; home is a derived index over them.
- **ADR-005 Anonymous rooms** — nameplate names readers; slots never name signers; scope sheet carries the two-sets explanation (U-9).
- **ADR-006 Transport source** — platform messaging module vs embedded nwaku behind our Transport interface. Resolve at P3 start by API inspection; the interface makes the choice reversible.
- **ADR-007 Third-party plugin isolation** — capability-restricted `.lgx` modules under the platform's access policy. Post-v1.
- **ADR-008 Dev host** — poc2's spec-native `runtime_cli` TCP host for P0–P3 (trivial two-instance testing, no C++ toolchain in the inner loop); basecamp/liblogos packaging validated at P4 when the UI arrives. Building to the module spec is what makes both hosts reachable from one module.

## Working agreements for Claude Code

- Where poc2's code and the LOGOS-MODULE-* specs diverge (e.g. the transport tag-placement TODO), the spec wins. Spec appendix vectors become tests before the code they validate.
- Conformance before features: the suite (S-1) is written first and extended with every driver capability; no driver work merges red.
- Integration tests never mock `Driver` or `Transport` — use the stub driver and the local transport instead. Mocks hide exactly the seams this architecture exists to expose.
- Every FS requirement and F-4/F-5 has at least one test that fails if the invariant is violated. Treat those tests as append-only.
- No ad-hoc serialization where bytes get hashed or signed; dCBOR canonical encoding only.
- chronos only — never std asyncdispatch; mixing async backends in this ecosystem is how deadlocks are born.
- The module imports nothing from `ui/`; the UI reaches the module only through the logos API under capability policy; inter-module calls go through logos-core, never side channels.
- Prototype v2 (`coordination-prototype-v2.html`) is the UI reference: same tokens, same components, same copy voice. Where prototype and FURPS conflict, FURPS wins.
- Each phase's accept block becomes an integration test (Nim for P0–P3, logos-qt-mcp script for P4+) before implementation starts.
