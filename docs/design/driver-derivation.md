# Deriving Muster drivers and cards from Logos modules

**Status:** design note / plan (not yet implemented). Author: 2026-09-11.
**Thesis:** every Logos module that lets a user *do something* should become a Muster
driver, so the module is *infrastructure for doing that thing with other people,
securely and privately*. This note works out how to think about that and a phased
plan to get there.

---

## 1. What we already have to build on

Muster's coordination surface is already driver-generic. The pieces a "module → driver"
story must fit into:

- **The `Driver` interface** ([module/src/drivers/driver.nim](../../module/src/drivers/driver.nim)) is tiny and coordination-only:
  - `describe() -> DriverDescriptor` — `{rounds, serializationDomain, membership, finality, threshold}`. The core routes purely on this (invariant 6): it never reads contribution bytes.
  - `canonicalize(effect) -> Materialization` — the effect's deterministic **signable bytes** ([materialization.nim](../../module/src/intents/materialization.nim), Safe's is EIP-712 `safeTxHash`).
  - `verifyContribution(c, round) -> bool` — the driver alone reads the bytes.
- **Drivers register by kind** ([registry.nim](../../module/src/drivers/registry.nim)): `newDriver("safe"|"threshold"|"frost"|"stub", config)`. Adding a coordination policy is one `case` arm + passing conformance.
- **Execution is the core's job, not the driver's.** The Safe driver canonicalizes to a hash; `coordinate_submit` in [muster_module.nim](../../module/nim-lib/muster_module.nim) gathers the folded signatures, re-derives the hash (invariant 1), assembles `execTransaction`, and submits over `lp_*`. The driver describes *what* to sign; the core does the *doing*.
- **The card vocabulary** ([ui/src/qml/MusterCard.qml](../../ui/src/qml/MusterCard.qml)) is closed: address-share, **intent-propose** (status rail: proposed → collecting → executable → submitted → final; approval slots; the honesty caveat), receipt. A proposal card renders from the verified `coordinate_intents` fold, never from posted JSON.
- **The SDK already parses LIDL** ([logos-nim-sdk](https://github.com/corpetty/logos-nim-sdk)): `lidl-gen` turns a `.lidl` contract into a provider surface **and a typed consumer client** per dependency, and `PluginProxy` calls any module by name over `lp_*`.

So the raw materials exist. The question is the *mapping*.

## 2. The mapping: a module action → a coordinated intent

A Logos module method is `method verb(args...) -> result`. Coordinating it means the
same lifecycle Safe already runs, generalized:

```
module method  ──►  EFFECT           the typed intent to call verb(args)
   (LIDL)           {module, method, args}
                       │
                       ▼  driver.canonicalize (dCBOR, domain-separated)   ── inv 5
                    MATERIALIZATION   the exact bytes the room signs
                       │
                       ▼  coordinate_propose → fold → k-of-n endorsements  ── inv 4,6
                    EXECUTABLE        the room agreed
                       │
                       ▼  core re-derives (inv 1) + lp_invoke module.verb(args)
                    EXECUTED          the module did the thing
                       │
                       ▼  finality from a named completion event / receipt  ── inv R-8
                    FINAL
```

The **card** is the render of that intent: the action verb + args (human-readable,
using the LIDL `@brief`/`@param` descriptions), the approval slots (threshold), the
status rail, and the honesty caveat / provenance. It's the existing intent-propose
card, parameterized by the effect's schema instead of hardcoded to a Safe transfer.

## 3. What LIDL gives you for free — and the three things it can't

Reading the real delivery contract (`delivery_module.lidl`) makes the boundary concrete.

**Mechanical (derivable from the contract):**
- The **effect schema** — the method's typed params (`send(contentTopic: tstr, payload: bstr)` → effect `{contentTopic, payload}`).
- A **generic canonicalization** — dCBOR over `{module, method, args}` with a domain tag `muster.invoke.<module>.<method>.v1` (invariant 5, deterministic).
- The **card copy** — the `@brief` becomes the action label, each `@param` labels a field. LIDL descriptions are rich (doxygen-style) — real UX text, free.
- The **call itself** — the SDK's `genClient` already emits `proxy.callSync("verb", args(...))`; execution reuses it.

**Not mechanical (LIDL is an API description, not a coordination spec) — three gaps:**

1. **Which methods are coordinatable actions.** Most methods are reads or infrastructure — `version()`, `getNodeInfo()`, `getAvailableConfigs()`, `collectOpenMetricsText()` are queries; `createNode`/`start`/`stop` are node lifecycle. Delivery is *the pipe*, not a "do something with others" module at all. The interesting ones are actions others must co-authorize or want to do together (a transfer, a vote, a shared-fund spend, a group grant). LIDL doesn't mark side-effects; the signal is **semantic** (the `@brief` mentioning funds/ownership/approval/state-change) and **curatorial** (a human, or an annotation, says "this one is coordinatable"). Naming heuristics (`get*`/`version` = read) prune the obvious reads.
2. **The authorization model** — who may endorse and how many. LIDL is silent. Default: **the room roster is the authority** (k-of-n over the conversation's members, exactly like the threshold/frost drivers — the conversation is the security boundary). Some modules carry their own authority (a Safe's owners, a DAO's members); those override the default and need module-native verification.
3. **What "done" means.** `send` returns a `requestId` and completion arrives on a `messageSent`/`messageError` **event** — that's `finExternal` finality tied to a named event. An on-chain call is a receipt. An in-module state change may be `finImmediate`. The completion signal is declared, not inferred.

## 4. The design: two tiers + one generic driver

### Tier 0 — the generic `invoke` driver (no codegen, runtime config)

The bulk of modules need **no new Nim code at all**. Add one driver kind, `invoke`,
parameterized by config discovered from the module:

```
newDriver("invoke", {
  "module": "<name>", "method": "<verb>",
  "argSchema": [...],                         # from LIDL, for canonicalize + card
  "domain": "muster.invoke.<module>.<method>.v1",
  "roster": <room members' Ed25519 keys>,     # default authority
  "threshold": <k>,
  "finality": {"kind": "event", "event": "messageSent"}  # or "immediate"/"receipt"
})
```

- `describe` → `{rounds: 1, threshold: k, membership: anonymous, finality, domain}`.
- `canonicalize` → dCBOR over `{module, method, args}` under the domain (invariant 5).
- `verifyContribution` → an Ed25519 roster endorsement — **reuse the threshold driver's verify verbatim**. "We, the room, agree to make this call."
- Execution → a `coordinate_submit`-style path: on executable, the core re-derives (invariant 1), `lp_invoke`s `module.method(args)` (the SDK client), and observes the declared finality signal.

This makes **any** module action coordinatable the moment the module is loaded,
authorized by the room, with zero per-module code. It is a `threshold` driver whose
materialization is a call intent and whose completion is an `lp_invoke`.

### Tier 1 — module-native authorization / signing

When a module has its own signing or authority model — Safe (EIP-712 + secp owners),
a chain tx, a module that itself checks a signature set — the generic dCBOR
materialization is wrong: the bytes must match *that module's* expected signed form.
This is exactly today's Safe driver, and it stays hand-written. The derivation tool
generates the **effect schema + card + a driver skeleton** and flags `canonicalize` /
`verifyContribution` as "implement against the module's format" (with the LIDL
description and the Safe driver as the worked example).

### The derivation tool (extend `lidl-gen` with a `driver` mode)

`lidl-gen driver <contract.lidl>` emits, per curated coordinatable method:
- the **effect schema** (params) and its dCBOR domain tag,
- a **card descriptor** (label + fields from `@brief`/`@param`) the UI renders,
- for Tier 0: an `invoke`-driver registration recipe (config, not code),
- for Tier 1: a driver skeleton to complete.

Curation is an **annotation on the contract** (a `@coordinatable` marker, or a sidecar
list) plus the read-pruning heuristic — never a silent guess.

### Discovery (the UX payoff)

Muster enumerates the user's loaded modules (`lp_get_methods` via the SDK's
`methodsOf`, or the host module registry), filters to coordinatable actions, and lists
them: *"your modules let you do these things with others."* Picking one opens the
composer for that effect → propose → the room approves → the core invokes the module.
The module is now infrastructure for doing that thing together.

## 5. Why this keeps the invariants (the part that matters)

- **Inv 3 (plugins never sign / touch network).** The *driver* never invokes anything — it describes and verifies. The *core* (`muster_module`, which already calls delivery and the Safe RPC) does the `lp_invoke`, exactly as `coordinate_submit` submits `execTransaction` today. No new network surface in the sandbox.
- **Inv 1 (re-derive, refuse on mismatch).** Execution re-derives `canonicalize(effect)` and checks it against the signed materialization before invoking. Generic dCBOR is deterministic, so re-derivation is exact.
- **Inv 5 (deterministic bytes).** The generic canonicalize is dCBOR (muster's existing encoder) under a per-`(module, method)` domain-separated `hash-input`. No ad-hoc concatenation.
- **Inv 6 (core never interprets contributions).** The `invoke` driver reads the endorsement bytes; the core routes on the boolean + descriptor. A derived driver is just another `Driver`.
- **Inv 10 (provenance).** The effect's args are proposer inputs (composer blocks); the provenance record accounts for them exactly as for a Safe transfer.
- **Conformance.** Every derived/registered driver must pass `checkConformance` ([conformance.nim](../../module/src/drivers/conformance.nim)) — the `invoke` driver passes as a threshold-shaped driver; Tier-1 skeletons must be completed to pass. **A driver that doesn't pass conformance doesn't ship.**

The one genuinely new mechanism is the **generic execution path** — a driver-described
`lp_invoke` after threshold, with finality from a named event. It generalizes the Safe
submit path; it does not weaken any invariant, because "the core invokes a module after
the room agreed and the client re-derived" is precisely what Safe settle already is.

## 6. Plan

Each phase is independently useful and shippable.

- **P-D1 — the generic `invoke` driver + conformance.** Add the `invoke` kind to the registry: describe/canonicalize (dCBOR call-intent)/verify (roster Ed25519). Pass `checkConformance`. Unit + property tests (convergence under reorder/dup, invariant 5 determinism). *No UI yet.* This is the foundational abstraction.
- **P-D2 — the generic execution path.** A `coordinate_submit`-style route for `invoke` intents: re-derive → `lp_invoke module.method(args)` (SDK client) → observe finality (event/immediate). Headless test against a stub module + the local transport (never mock `Driver`/`Transport`).
- **P-D3 — discovery + curation.** Enumerate loaded modules (`methodsOf`/registry), prune reads by heuristic, honor a `@coordinatable` annotation, and expose the coordinatable-actions list through a `coordinate_available_actions` lidl method.
- **P-D4 — the generic action card.** Generalize the intent-propose card to render an arbitrary effect schema (label + fields from LIDL descriptions), fed by the fold. qmllint + the render harness.
- **P-D5 — `lidl-gen driver` mode.** Extend the SDK generator to emit effect schema + card descriptor + Tier-1 skeletons from a contract. (Upstream to logos-nim-sdk.)
- **P-D6 — a second real driver end-to-end** (a non-Safe module — a vote or a shared-fund action) proving Tier 0, and one Tier-1 module-native case beyond Safe, to validate the skeleton path.

**First step:** P-D1 — it's self-contained, invariant-critical, and everything else builds on it. It answers the load-bearing question (can a generic call-intent be a conformant driver?) before any UI or codegen investment.

## 7. Open questions to settle before P-D1

- **The `@coordinatable` annotation vs pure curation.** Do we propose a LIDL convention (upstream) so modules self-describe their coordinatable actions, or keep a muster-side sidecar list? (Leaning: sidecar first, propose the convention once we have 2-3 real drivers to generalize from.)
- **Roster authority vs module authority.** For Tier 0 the room is the authority — but the module then executes on the room's say-so. Which modules is that *safe* for? (A message send: fine. A fund movement with no on-chain owner check: the room is the only gate — is that the intended trust model, or does Tier 0 need an allowlist of "room-authorizable" actions?) This is the sharpest design question and should be answered with real modules, not in the abstract.
- **Finality declaration.** Where does "completion = event X" live — annotation, discovery-time heuristic from the `@return` text, or config? (Leaning: config at registration, defaulted from the description.)
