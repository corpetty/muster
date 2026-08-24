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
10. **Nothing is signed whose inputs can't be accounted for.** Every signing payload commits to a provenance record naming, for each input that reached the signed bytes, its class (plugin block, driver-interpreted contribution, external read, peer message) and its log position — and signing is *refused* when any input's origin is unaccountable. Invariant 1 proves a materialization is consistent with its effect; it says nothing about where the effect's inputs came from, so correctly-derived data of unknown origin passes it. Whether the record *also* names the contributing account is driver-described (6), following the declared membership model: silent under an anonymous driver, so 9 survives the trail; naming under a named one, where every participant could disclose the same fact anyway. The boundary that matters is the conversation, not the participant — the record is a reduction over the log rather than a side-car store (4), and is scoped to the membership epoch of the entries it describes, so a later joiner cannot read earlier lineage (7) — the boundary is the room, not the participant, who can always disclose what they legitimately hold (F-20, FS-10). Spec `derived-exo-3a1`.

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
- Conformance suite (`module/src/drivers/conformance.nim`, run by `tests/conformance_test.nim`) before driver features; never merge with it red. A driver is a complete unit behind the `Driver` seam — `describe` (coordination policy), `canonicalize` (effect→signable bytes, a driver method since 2026-08-23), `verifyContribution` — and `checkConformance` grades stub, Safe, and any new driver identically.
- Integration tests use the stub driver and local transport — never mock `Driver` or `Transport`.
- Invariant tests are append-only. Extend, don't weaken.
- Each phase's accept criteria become an integration test (Nim headless, or a logos-qt-mcp script for UI phases) before implementation.
- The module imports nothing from `ui/`. The UI reaches the module only through the logos API under capability policy. Inter-module calls go through logos-core.
- The educational layer explains what the code already guarantees — it never adds a code path the invariants don't cover. If a lifecycle step can't be shown truthfully, that's a product bug, not a copy problem.

## Layout

**What exists today** (the real `module/`+`ui/` build landed P0→P2 and the P4 UI spike across 2026-08-19/20):

```
module/          Nim core behind the muster.lidl contract → muster-module.lgx
  src/api/       muster.lidl (the only outward seam) + generated surface
  src/dcbor/     deterministic CDE encoder (inv 5)
  src/hashing/   sha256 · keccak256 · domain-separated hash-input records (inv 5)
  src/log/       signed hash-linked log, reduce(log) (inv 4)
  src/intents/   lifecycle (F-3) · materialization · signing_payload · anon_state · provenance
  src/drivers/   driver interface (inv 6) · safe · safe_rpc (P2 wedge)
  src/crypto/    secp256k1 (authorization identity) · curve25519 (Ed25519/X25519 encryption identity, F-14) · binding (secp↔enc link statement, F-14/F-9) · conversation (ConversationCrypto seam) · epoch_crypto (ECIES-via-sealed-box stopgap, F-16) · sodium (libsodium AEAD + Argon2id) · keystore (two-identity seam, FS-4: file stopgap + in-memory)
  src/transport/ transport (F-15 interface + LocalTransport) · lp_ffi (lp_* C-ABI binding) · delivery (DeliveryTransport) · inbound_queue (foreign-thread seam) · infra (inv 8)
  src/coordination/ session (multi-instance flow) · intents (intent lifecycle = reduce(log))
  src/wallet/    chain-agnostic wallet (F-Design): types (Account/AssetId/Amount over stint UInt256) · adapter (ChainAdapter seam + Wallet aggregate) · evm_adapter (ETH + ERC-20 · verifiedBalance via eth_getProof · client-side signing) · evm_rpc (typed eth_* over nim-web3, sync via waitFor) · evm_sign (nim-eth EIP-155 tx signing via the keystore seam) · mock_chain (non-EVM: shielded accounts, delayed finality) · verify (nim-eth verifyMptProof — Nimbus verified-proxy core, in-process, F-10)
  src/plugins/   plugin sandbox (inv 3)
  nim-lib/       muster_gen.nim (generated) + muster_module.nim (hosted surface)
  tools/         lidl_gen.nim — Nim LIDL codegen over lidl_c.h (B4)
  tests/         lifecycle/safe/crypto/transport/coordination tests + tests/probes/ (42 invariant probes)
ui/              QML view + C++ backend → muster-ui.lgx (Logos.Theme, ADR-011)
  src/qml/       Main.qml · src/muster_ui_backend.{cpp,h} · muster_ui.rep
infra/anvil/     MiniSafe.sol fixture (faithful Safe-1.4.1 subset) + foundry
demo/            the speed build — runnable, and deliberately not the specified client
  muster-ui/     fork of logos-co/logos-chat-ui: QML + QtRO C++ backend, wallet journey
  poc/           LEZ private-transfer POCs + upstream bug write-ups
docs/            00-vision · 01-furps · 02-implementation-plan
  diagrams/      the figure programme, its manifest, and the rot checker
  labbook/       traps found the expensive way
  posts/         campaign write-ups
contracts/specs/ typed specs with acceptance oracles, one per invariant (derived-exo-*)
ui/prototype/    coordination-prototype-v2.html — the standalone HTML reference build
scripts/         git hooks
```

**Not yet present** — do not cite as though these resolve: `module/src/schemas/` (no CDDL parser / cdCDDLe in v0, ADR-009); cross-host coordination over a live delivery node (the room's verified propose/contribute path landed 2026-08-24 — cards render from the `coordinate_intents` fold, propose → `coordinate_propose`, approve → an owner signature the driver verifies via `coordinate_contribute` — but it is exercised single-instance; the two-instance wire needs a running delivery node); room-side submit (the executable → on-chain `submit` still lives in the Safe dashboard); multi-room (the coordination session is single-room), and the shielded LEZ journey (needs the deferred LEZ adapter); real transport + encryption (P3, still stub/local); the plugin runtime beyond the sandbox type (P5). The `module/` and `ui/` flakes pin `logos-module-builder` as a **local path-input on the `nim-cdylib-authoring` branch** — not upstream yet ([logos-co/logos-module-builder#202](https://github.com/logos-co/logos-module-builder/pull/202), open).

ADRs are **not** in `docs/adr/`; they are a section of `docs/02-implementation-plan.md`.

## Commands

**These run today.** There is no root `flake.nix`; every working target lives under `demo/`.

```
cd demo && make app              # build the standalone runner (the slow one)
make alice                       # launch a peer; `make bob` for the second
make run PEER=carol              # any further peer
make clean-peer PEER=alice       # wipe one peer's chat identity and wallet
make help                        # every target
cd demo/muster-ui && nix build   # the muster_ui module itself
python3 docs/diagrams/tools/check-manifest.py   # figure-provenance gate (--update, --stamp)
python3 scripts/check-readme-rot.py             # entry-point README staleness gate vs the Current-phase section (--stamp)
python3 scripts/check-claims-registry.py        # ADR-012 claims registry: every protects→requirement+test, every gap→fix+status
python3 ui/tools/gen-claims-qml.py [--check]    # regen ui/src/qml/ClaimsRegistry.qml from the registry (CI checks drift)
python3 scripts/check-run-targets.py            # run instructions resolve (make run / nix runner / README agree)
make run                                        # launch the real UI standalone (logos-standalone-app); make build first
```

**The real `module/`+`ui/` build** (needs the local `logos-module-builder@nim-cdylib-authoring` checkout the flakes pin; build via `cache.nix.logos.co` as a substituter — the user is not a trusted nix user, so pass `--extra-substituters` explicitly):

```
cd module && nix build .#lgx            # muster-module.lgx (dev, keyed linux-amd64-dev)
cd module && nix build .#lgx-portable   # portable variant (keyed linux-amd64; logoscore's default resolver wants this one)
cd ui     && nix build .#lgx            # muster-ui.lgx (follows module's builder pins)
nim r -d:release module/tests/probes/probe_*.nim   # pure-Nim invariant probes (no host)
# P2 crypto/Safe tests need libsecp256k1 linked — see module/tests/README.md
# Load headless: lgpm install --file ./result*/*.lgx --modules-dir <dir>; logoscore -m <dir> -l muster_module -c 'muster_module.health()' --quit-on-finish
```

**Not yet wired as one-shot targets** (listed as the intent, not something to run):

```
nix build '.#tests'              # unified unit + property + conformance runner
nix run  '.#integration'         # two isolated logoscore instances, stub + safe drivers
nix run  '.#anvil'               # local chain with Safe fixture (infra/anvil exists; no flake app yet)
# UI e2e (P4 acceptance): logos-basecamp --user-dir per instance + logos-qt-mcp scripts — BLOCKED on the SDK-rev skew, see Current phase
```

## Current phase

**P3 — real transport + encryption, functionally complete against a local transport; hosted surface + live-node test remain.** P0–P2 and all 11 invariant pebbles landed by hand (42-probe suite green); **P4 shipped** and P3's core is done. The whole transaction lifecycle runs in the UI, and multi-party coordination of real intents works end to end.

Done:
- **P0–P2** — loading spike + signing-path core (dCBOR, hash-input records, signed log); intent lifecycle engine + driver interface + all 11 invariants; Safe driver (EIP-712 `safeTxHash`, secp256k1 owner verification, collect-2-of-3, on-chain `execTransaction` vs the anvil `MiniSafe`, no indexer). B4: `tools/lidl_gen.nim` generates the surface from `muster.lidl`. Route B `codegen.nim` path added to `logos-module-builder` (PR #202, open upstream).
- **P4 — complete (ADR-013).** The `exo-c6a` SDK-rev render blocker was **routed around** without the upstream fix: build `muster-ui` on basecamp's coherent builder instead of `muster_module`'s Nim-cdylib builder (ADR-013). The full lifecycle runs through the real UI in `logos-basecamp` — `describe()` → the real 2-of-3 Safe, `propose()` → real re-derived `safeTxHash` (F-4), `approve()` → collect owner signatures → executable, `submit()` → a real on-chain `execTransaction` → final. Acceptance harness `ui/tests/muster-ui-test.mjs` is **6/6** (render, health, propose, lifecycle, reject+reset, submit). exo-c6a remains open only for the eventual upstream codegen bump.
- **P4 product surfaces — the demo experience reproduced in the spec-first client (2026-08-24).** Beyond the lifecycle spike: the room/home/composer/card surfaces, driven by `demo/muster-ui` as reference and the prototype as spec. **(1) A conversation layer in `muster_module`** — four new lidl methods (`coordinate_post_message`/`coordinate_messages`/`coordinate_members`/`coordinate_conversations`) folding a new `message/<id>` event kind over the existing sealed coordination log; the demo borrowed chat from `chat_module`, but the spec-first client talks only to `muster_module`, so it builds its own (`coordination_messages_test` green, regression green). **(2) The UI** — a home → compose → room shell: `Home.qml` (F-18 action list), `Composer.qml` (verb → people → account), `Room.qml` (the thread rendering `MusterCard` for card-bodied messages — the closed vocabulary: address-share, intent-propose with a status rail + approval slots + the honesty caveat, receipt), `ScopePanel.qml` (roster + scope line, U-1/U-9/F-16). Built contract-first, the UI surfaces fanned out in parallel, each **launch-verified in the standalone runner** — which now works (`make run`; the runner was always in `mkLogosQmlModule`'s `apps.default`, now exposed as `ui/flake.nix#runner`), retiring the "standalone renders no ui_qml" claim (that predated ADR-014's coherent builder). The ADR-012 claims registry + `Walkthrough.qml` also shipped. **Update (2026-08-24):** the room's intent cards are now wired to the *verified* path — `coordinate_intents` returns a render-ready projection (`reduceIntentViews`: effect + driver threshold + distinct-owner approvals), `Room.qml` draws its proposal cards from that fold (not posted JSON), Propose calls `coordinate_propose` (content-addressed), and Approve reveals an honest signature field feeding `coordinate_contribute` (the driver refuses a non-owner). Verified headless (`coordination_surface_test` step 6) + the module `.lgx` compiles; the on-display render is parse-clean (`qmllint`) but the qt-mcp launch gate stays the same UI-e2e blocker. **Still ahead:** cross-host over a live delivery node, room-side submit, wallet-in-room, multi-room, a committed CI acceptance harness, and the shielded LEZ journey (deferred, infra-bound adapter).
- **P3 — transport + encryption + multi-party coordination.** ADR-010 resolved then **amended** to the persistent, room-scoped identity model (FS-7 reframed; the platform mixnet closes FS-9): build a thin ECIES stopgap behind a `ConversationCrypto` interface, native `logos-chat-module` the target once it ships persistence + removal. Consume `logos-delivery-module` behind a `Transport` interface. Built + tested (against `LocalTransport`): the `lp_*` C-ABI Nim binding + `DeliveryTransport`; ECIES-secp256k1 `EpochCrypto` with **F-16 verified** (a mid-conversation joiner cannot open earlier epochs); the multi-instance coordination flow; the foreign-thread GC seam + async send; and — the payoff — **the intent lifecycle as `reduce(log)`**, so two owners coordinate a real Safe intent over encrypted transport and converge on it reaching executable. The full P3 stack links in the shipping plugin (secp256k1 + libsodium).

Remaining in P3:
- **Persistent identity (FS-4) — the prerequisite, now landed.** A `Keystore` operation seam (`address`/`sign`/`encIdentity`/`sealOpen`/`bindingFor` — never a key getter, so a Keycard backend slots behind it) with a file stopgap (`FileKeystore`: an Argon2id-encrypted keyfile) and an in-memory backend. The secret never enters the coordination layer (unwrap goes through `sealOpen`). The `identity()` lidl method is wired and the module opens its keystore under the host-provided instance path. `keystore_test` 6/6.
- **Two bound identities (F-14, ADR-010 revisit 2026-08-23) — landed.** A revisit relaxed F-14 from one curve to **two bound keypairs**: a secp256k1 authorization identity (Safe/Keycard) and an Ed25519/X25519 encryption identity (`curve25519.nim`), joined by a signed link statement the core verifies on ingest (`binding.nim`, F-9). `Member` is now the encryption identity; epoch keys wrap with libsodium **sealed boxes** (ECIES over X25519). Fixes the ECDSA+ECDH key-reuse the one-curve model hid, and builds the exact binding native chat's Ed25519/X25519 layer needs. `curve25519_test`/`binding_test`/`keystore_test` + all epoch/coordination/handshake tests green through the refactor.
- **Hosted coordination surface — landed.** `coordinate_join`/`coordinate_propose`/`coordinate_contribute`/`coordinate_intents` lidl methods drive a conversation from a host over `CoordinationSession` + `reduceIntents` (the multi-party `state = reduce(log)` path), keyed by a content-addressed intent id so hosts agree without a round-trip. This compiles `coordination/intents.nim` into the plugin — the `musterP3LinkCheck` stub is gone. Verified in-process (`tests/coordination_surface_test.nim`: two owners converge on a real Safe intent → executable, non-owner refused, duplicate folds once) + the portable `.lgx` builds clean with it. **Not yet driven cross-host** — that needs a running delivery node and a membership/grant handshake (below).
- **Membership/grant handshake — landed.** A join-request/admit protocol over the coordination session: a joiner announces its key (`coordinate_request_join`, no authority), an existing member decides to `coordinate_admit` it, and the epoch key travels as an opaque ECIES control frame on the same topic (a 1-byte kind tag separates data/join-request/control frames). Admission re-keys forward, so **F-16 holds over the wire** — the newly admitted member reads from its epoch on, nothing before its seam. The mechanism lives behind the `ConversationCrypto` seam (`identity`/`admit`/`ingestControl`), so native chat swaps in as a binding change. Verified in `tests/membership_handshake_test.nim`. Still needs a running delivery node for the cross-host wire (below).
- **Live two-instance test over a real delivery node** — delivery embeds its own Waku node; two hosts on separate networks through store nodes; kill mid-collection, restart, contribution still lands (R-4/R-6). Needs a running node.

**Chain-agnostic wallet (F-Design) — landed 2026-08-23.** A `ChainAdapter` seam + `Wallet` aggregate (`module/src/wallet/`) with two impls proving genericity: an EVM adapter (ETH + ERC-20 over the user's RPC, inv 8 / F-10) and a mock shielded chain modelled on the LEZ (dual public/shielded accounts, delayed finality, sentinel-failure defense). Amounts are arbitrary-precision (wei > uint64). Failure is always a raise — a failed read never reads as a zero balance. Hosted methods: `wallet_accounts`/`wallet_balances`/`wallet_estimate_fee`/`wallet_send`/`wallet_finality`/`wallet_verified_balance`. Diagram: `docs/diagrams/mech-wallet-seam.svg`.

**Nimbus/Status Nim reuse (ADR-014) — landed 2026-08-23.** The wallet's Ethereum layer runs on the org's Nim stack, unblocked by a `nim.packages` hook added to `logos-module-builder`: **stint** (amounts), **nim-secp256k1** (one secp source — the hand FFI + system lib dropped), **nim-eth** (EIP-155 tx signing + `verifyMptProof` for verified reads — the Nimbus verified-proxy core reused in-process, `wallet_verified_balance`, F-10; diagram `docs/diagrams/mech-verified-reads.svg`), **nim-web3** (typed RPC over chronos), **nimcrypto**. Kept ours: dcbor (inv 5), curve25519/libsodium (F-14). All 42 probes green on nim-secp256k1; `safe_anvil_e2e` green on live anvil.

**Wallet UI — wired, render unverified.** `ui/` gained a WALLET card (balances across chains, each with a green *verified* / amber *attested* F-10 badge). The `.lgx` builds (client regenerated from `muster.lidl`, `.rep`+backend compile), but `nix build` does not evaluate QML — the card *rendering* is the remaining ADR-013 logos-qt-mcp harness assertion.

**Experience-smoothing round.** Client caching in `evm_rpc` (no reconnect per call); `module/tools/regen.sh` (one-command surface regen); `infra/anvil/devnet.sh` (one-command anvil + MiniSafe fixture, documents the delivery-node + verified-proxy sidecars).

Deferred, both infra-bound: the real LEZ adapter (zone proving stack); client-side EVM signing on a non-anvil node; the beacon light-client sidecar that makes `verified-locally` trustless end to end.

Two supporting fixes live **outside** this repo (local, uncommitted, worth upstreaming): the `logos-module-builder` RUNPATH fix (carries secp256k1 + libsodium into the plugin RUNPATH) and the `logos-basecamp` bake-in scaffolding (for the P4 UI render harness). See `docs/02-implementation-plan.md` for per-phase accept criteria and ADR status.
