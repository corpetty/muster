# Muster — FURPS+ Requirements

Muster is a local-first client for coordinating and executing multi-party transactions inside conversations, built on the Logos stack. Its first mission is educational: the client walks people through the entire transaction lifecycle, making visible at each step how the Logos stack maintains privacy and security — and where other stacks don't (see `00-vision.md`). The conversation is the security boundary: who is in the room determines who can read what is being done. This document is normative for v0–v1; items marked (v1) may ship after the first usable client.

Requirement IDs are stable. Reference them in commits and tests.

---

## F — Functionality

### Core objects

- **F-1** A conversation is an append-only, hash-linked log of signed events. Every event is authored by a member keypair and carries a causal reference to prior events.
- **F-2** Event types (v0): `message`, `membership-change`, `intent-propose`, `intent-contribute`, `intent-round-advance`, `intent-submit`, `intent-settle`, `intent-drop`, `fact`, `choice`, `choice-vote`, `artifact-ref`.
- **F-3** An intent consists of: an **effect** (semantic, typed, human-reviewable), a list of **authorization requirements**, **provenance references** to facts it depends on, and a **lifecycle state** derived entirely by reducing events. States: `draft → proposed → collecting(round r) → executable → submitted → settling → final`, with `dropped` and `expired` reachable from any pre-submitted state.
- **F-4** Effect/materialization split: participants review effects; clients sign materializations produced by drivers. **The client MUST independently re-derive the materialization from the displayed effect and refuse to sign on mismatch.** This check is core behavior, not plugin behavior.
- **F-5** Replay binding: every signing payload commits to (a) execution environment id, (b) account address or membership commitment, (c) serialization slot (nonce or nullifier), (d) expiry. A contribution is unusable in any other conversation, account, or slot.
- **F-6** Driver interface: `describe`, `canonicalize`, `verify`, `progress`, `assemble`, `submit`, `watch`. `describe` returns: policy shape, membership model (roster **or** predicate), round count r, serialization domain, finality descriptor type. The core never interprets contribution bytes; it routes opaque blobs and asks the driver what they mean.
- **F-7** Approval is modeled as an r-round protocol with a round index. Safe is the degenerate r=1 case. The threshold driver (v1, FROST) exercises r=2 (nonce commitments, then partial signatures).
- **F-8** Sequential serialization domains queue concurrent intents visibly; parallel domains do not. Dropping a live or queued intent is an explicit `intent-drop` event that frees its slot and advances the queue.
- **F-9** Chat membership and account membership are distinct sets with distinct lifecycles. Per-member role (`signer` / `reader`) is derived by intersecting the two and is always displayed.
- **F-10** Facts carry the supplier's signature and a verification grade: `verified-locally` (proof or local read checked by this client) or `attested` (trusting the named supplier). The grade is always displayed with the fact.
- **F-11** A choice block can bind its winning option into a proposed intent in the same thread.
- **F-12** Plugins are pure functions: `(conversation context, user input) → typed blocks + proposed effects`. Plugins never sign, never hold keys, and have no ambient network access. Declared data dependencies are satisfied by user-run bots or the user's own node. Distribution is signed, content-addressed bundles; installing one is trusting a hash, not a registry.
- **F-13** The render vocabulary is closed: `message`, `intent`, `fact`, `choice`, `artifact`, `receipt`, plus system notices. Plugins never get a canvas. Additions to the vocabulary are core releases.
- **F-14** Identity: one secp256k1 keypair is both chat author and transaction signer. Keycard is the hardware signer backend (v1).
- **F-15** Transport is Logos Messaging: one content topic per conversation, payloads end-to-end encrypted to the member set, store-node catchup for offline members.
- **F-16** Membership epochs: adding a member re-keys the conversation forward; prior epochs are not decryptable by them. Removing a member rotates the epoch immediately. The UI's seam claim depends on this being true.
- **F-17** Artifacts and plugin bundles are content-addressed in Logos Storage, behind a storage interface with a local content-addressed store as the first implementation.
- **F-18** The home surface is a query over intents: `needs-you`, `waiting-on-others`, `settled`. Composition is verb → people → account; the account list is filtered by the verb, and the room opens scoped.
- **F-19** The intent schema expresses a **list** of authorization requirements even though v0 execution handles exactly one. Multi-account intents must be a data addition, not a schema migration.

### Security (part of F)

- **FS-1** No server-side application state exists anywhere. Store nodes and RPC endpoints are untrusted and user-configurable.
- **FS-2** All events are signed; events from non-members or with invalid signatures are rejected at ingest. Log verification runs on every append and every catchup.
- **FS-3** Signing payloads are domain-separated per F-5. A test must demonstrate a contribution collected in one context fails verification in every other context.
- **FS-4** Key material lives in the OS keystore or Keycard. It never appears in the log, in exports, or in anything reachable by a plugin.
- **FS-5** Plugin bundles are verified against their content hash before load. The capability manifest is enforced at runtime: no network, no key APIs, no storage outside declared scopes.
- **FS-6** The re-materialization check (F-4) cannot be disabled by configuration, plugin, or user preference.
- **FS-7** For anonymous-membership drivers, signer identity must not leak through UI state, local logs, timing, or ordering. Slots render as count-only.
- **FS-8** No telemetry, no phone-home, no automatic update fetch. Updates are manual or an explicitly enabled signed feed.

## U — Usability

- **U-1** The boundary is drawn, not explained: the room is a visible enclosure; the nameplate lists who is inside; a scope line (how many can read, how many can't sign) is always on screen in a room.
- **U-2** Crossing the boundary is the only place the visual ground changes (in-room light, public dark). The submitted card names what became public and what stayed inside.
- **U-3** The live proposal is pinned at the top of the room with its state and a one-tap jump to the card.
- **U-4** Approvals render as presence: slots fill as contributions arrive. Anonymous drivers fill anonymous slots.
- **U-5** Provenance grade (F-10) is legible on the fact card itself without navigation.
- **U-6** Membership changes render as seams in the thread at the join/leave point.
- **U-7** Driver differences surface as copy and labels on the same components — never as different screens. (Prototype-validated across four drivers.)
- **U-8** Blocked states (mismatch, queued, expired) explain cause and remedy inline on the card.
- **U-9** In anonymous rooms the nameplate names readers and slots never name signers; the scope sheet explains that these are different sets.
- **U-10** Keyboard operable; `prefers-reduced-motion` respected; WCAG AA contrast. (Prototype tokens already pass.)
- **U-11** Key setup takes under two minutes and involves no seed-phrase ceremony in the primary flow. Recovery is documented and tested.

## R — Reliability

- **R-1** Offline-first: everything except `submit`/`watch` works without network. Outbound events persist in a durable outbox across restarts.
- **R-2** Delivery is at-least-once; reducers are idempotent. Duplicated and reordered events converge to identical state on all clients (causal order with deterministic tiebreak).
- **R-3** State is derived: `state = reduce(log)`. Cold start re-derives from the persisted log; nothing exists that cannot be rebuilt from log + keys.
- **R-4** A signature is never silently lost: contributions are acknowledged, retried, and re-sent on reconnect.
- **R-5** Conflicting intents in one sequential domain surface as a conflict; the client never resolves one by discarding the other.
- **R-6** A crash at any step leaves recoverable state (atomic log append; no partial writes).
- **R-7** Store-node unavailability degrades to live-only delivery with a visible indicator; catchup resumes automatically.
- **R-8** A chain reorg before finality returns the intent to `settling` with a notice, per the driver's finality descriptor.

## P — Performance

- **P-1** An event is visible to online peers in ≤3s p95 over Logos Messaging light protocols.
- **P-2** Cold start with a 1,000-event conversation reaches interactive in ≤2s on a mid-tier laptop.
- **P-3** Store catchup of 5,000 events completes in ≤10s p95.
- **P-4** UI interactions respond in ≤100ms; thread scrolls at 60fps; ≤300MB resident with 50 conversations.
- **P-5** Log reduction is incremental after first pass (snapshot + tail), not O(events) per interaction.
- **P-6** Client bundle ≤5MB gzipped, excluding any wasm crypto.

## S — Supportability

- **S-1** A driver conformance suite is the contract: shared fixtures covering rounds, serialization domains, membership models, and finality. Every driver passes it in CI. No driver feature merges with conformance red.
- **S-2** Deterministic replay: any conversation log file replays to identical state. Log files are the bug-report format.
- **S-3** Structured local logging with levels; secrets and signer identities (FS-7) never logged.
- **S-4** The plugin API is semver'd. Render-vocabulary additions are minor; removals are major. The capability manifest is versioned.
- **S-5** One documented config file: RPC endpoints, store nodes, key backend, storage backend.
- **S-6** Package isolation: core has zero UI dependencies; UI touches chains only through core's public API.
- **S-7** Test pyramid: unit (reducers, crypto, encoding), conformance (drivers), integration (two headless clients over memory and real transports; Safe against a forked chain), e2e (client happy path).

## + — Constraints

**Design.** No server. No plugin canvas; closed render vocabulary. Local-first. Settlement chain-agnostic; the app never becomes the settlement layer. The four driver divergence axes — rounds, serialization domain, membership model, finality — are load-bearing and must not be collapsed for convenience.

**Implementation.** Nim backend with chronos async throughout (the nwaku/nimbus convention); QML on Qt 6 for all surfaces. Delivered as logos-core modules (`.lgx`) hosted by logos-basecamp (GUI) and the `logoscore` CLI runtime (headless); Nix flakes for reproducible builds, matching the platform repos. Event encoding follows the Logos deterministic CBOR profile (LOGOS-MODULE-INTERFACE §4.5: CDE bytewise-lex map ordering, shortest integers, no indefinite lengths, no floats) with schemas defined in CDDL and schema identity via cdCDDLe — deterministic encoding is a signing-path requirement, not a style choice; the profile is implemented in Nim over nim-cbor-serialization with golden test vectors at P0. All hashes and signing payloads use domain-separated structured hash inputs per LOGOS-MODULE-HASH-PROFILE. Cryptography via nimcrypto, nim-secp256k1, and nim-eth; epoch keys wrapped with ECIES over secp256k1 so identity and encryption share one curve. EVM access via nim-web3 with the Safe v1.4.1 ABI vendored and EIP-712 hashing implemented locally against published vectors — no Safe Transaction Service dependency. License: dual MIT / Apache-2.0, matching the platform repos.

**Interface.** The LOGOS-MODULE-* specifications (interface, transport, runtime, commitment model, hash profile) and cdCDDLe; logos-core C API (`logos_core.h`) for the basecamp/liblogos host; inter-module calls under the capability module's access policy; Safe contracts ≥1.4.1; Logos Messaging (lightpush, filter, store — via the platform messaging module or embedded nwaku, ADR-006); Logos Storage module behind the storage interface; EVM JSON-RPC; Keycard (v1); OS keystore.

**Physical.** Desktop via logos-basecamp (Linux AppImage, macOS app bundle), with standalone-mode launch like the other platform UIs; parallel isolated instances via `--user-dir` for testing. Room surfaces stay legible at 390px width (prototype-validated). Mobile rides the platform's Qt mobile path after v1.
