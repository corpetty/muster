# The action manifest: provenance, permissions, disclosure, and dependencies as one object

**Status:** design + plan, 2026-09-15. Epic `exo-002` (pebbles). M1 (`exo-002.1`) landed 2026-09-15; M2 (`exo-002.2`) landed 2026-09-16.
**Reads with:** `driver-derivation.md` (how a module action becomes a driver), `basecamp-capability-alignment.md` (where execution and capability grants live), the PriFi intro article (the credibility axis this design grades against).

## 1. What we want, stated once

Five things were asked of muster on 2026-09-15:

1. **Provenance proofs for every action taken in a group.** Not just the signing path.
2. **Muster as the emergent security and permissions protocol for Logos.** *What am I allowing to happen, before it is allowed to happen?*
3. **A visualization of information flow and disclosure** for the actions a group takes.
4. **All of it deterministic from what a module exposes** as functionality, never hand-written.
5. **A proposal card that explains itself to every participant.** When a muster is proposed to a room, each participant should see what the action will do, what infrastructure it needs, what it will touch and alter, what will happen as an effect, and how agreement is reached; and be able to *install* a missing dependency, *authorize* what they must hold, *approve*, or *deny* participation.

These are not five features. They are one object seen from five sides. Call it the **action manifest**: a per-action record that says what an action's effect is, who must authorize it, what it discloses to whom, what it touches, and what it needs. Want 1 is the evidence that record makes checkable. Want 2 is the host honouring the record before dispatch. Want 3 is rendering the record over the log. Want 4 says the record is generated from the module's contract plus declared facts the contract cannot carry. Want 5 is the record shown on the card, crossed with each participant's readiness.

## 2. The credibility axis this grades against

The PriFi article distinguishes **imperative** credibility (the discretion to defect has been removed structurally) from **motivational** credibility (the party could defect but has a reason not to). Muster already grades on that axis in three places without naming it:

| Seam | Imperative | Motivational |
|---|---|---|
| F-10 verification grade on facts | `verified-locally` (the client re-derived it) | `attested` (trusting the named supplier) |
| ADR-012 claims registry | `protects` (requirement + passing test) | `gap` (status none / specified / partial) |
| Driver descriptor finality | `immediate` (decided in the room's fold) | `external` (decided by a system we only observe) |

Two facts shape everything below.

**Credibility is relative to an observer at a link, not a property of the commitment.** The same signed intent is imperative against the counterparty (they cannot alter the materialization, invariant 1, or replay it elsewhere, invariant 2) and motivational against the store node, which we ask not to analyse the conversation graph (FS-9). So the honest unit is a matrix: *(lifecycle step) × (observer) → imperative | motivational | not applicable*. The observers muster can name today are the room member, the store node, the RPC provider, the chain observer, and the target module of an invoke.

**Muster classifies; it never scores.** The moment a commitment is a number, the residual trust disappears from view, which is exactly the failure the article's private-order-flow example describes. The card says "four of five inputs structurally bound; residual trust: RPC provider, store node". It never says "80%".

Of the article's seven links (discovery, diligence, negotiation, contracting, ordering, settlement, enforcement) muster touches negotiation, contracting, a slice of diligence (F-14 identity binding), a slice of ordering (the RPC sees the signed transaction before the mempool), and settlement readback. Discovery and enforcement are outside the room. Any claim is over those links, not seven.

The Bybit failure is the clean example of a link flipping columns: settlement was imperative, signing was motivational (trust the interface). F-4 re-derivation moves signing into the imperative column and can prove it with a test. That sentence belongs in the article's companion material.

## 3. The object

```
ActionManifest
  declared      bool              false = the driver has not declared; the card says so, never guesses
  agreement     DriverDescriptor  how agreement is made: rounds, threshold, membership model, finality (from describe())
  requirements  seq[Requirement]  what is needed: {kind: module|environment|authority|infra|capability, name, scope: instance|contributor}
  discloses     seq[DisclosureRow] what leaves the room beyond the baseline: {field, to: Observer}
  touches       seq[Touch]        what it reads and alters: {target, mode: read|write}
```

The **baseline disclosure** is added by the core, not the driver: the effect and contributions are visible to every room member, and the timing and topic are visible to the store node. No manifest can omit the observer who sees the most.

The manifest is a function of **driver + effect**, not driver alone. The generic invoke driver carries no module; the module and method live in the effect. So `manifest(driver, effect)` is the seam, and a card renders the manifest of *this proposal*.

**The five questions on the card map one to one:**

| Card question | Manifest field | Source today |
|---|---|---|
| What will it do? | effect + schema id | the proposal (exists) |
| What is needed? | requirements × this participant's readiness | manifest (M1) + readiness (M2) |
| What will it touch? | touches | manifest (M1) |
| What will happen? | full disclosure rows, grouped by observer | manifest (M1) + baseline |
| How do we agree? | agreement | describe() (exists) |

**Readiness** is the manifest crossed with one instance: for each requirement, `met | missing | unknown` with a remedy. `unknown` is a first-class answer, never silently `met` (the null-ladder rule, `exo-1ec.5`). The plugin never installs anything and never touches the network beyond the existing seams (invariant 3); it surfaces the requirement and the host's install path.

**Deny** is a signed decline event folded into the intent view, so the room sees who is out. Under an anonymous driver it names nobody (invariant 9).

## 4. How each want is served, and by what

| Want | Exists today | Gap | Slice |
|---|---|---|---|
| 1 Provenance for all actions | Every action is a signed, hash-linked log entry with causal parents. F-20 commits an input record *inside the signed bytes* on the signing path (`intents/provenance.nim`). | Messages, admits, drops carry no input record. No exportable proof object; the record is an in-room recomputation. Epoch scoping (inv 7) makes a proof checkable by epoch holders only, which is a design constraint, not a bug. | M4 |
| 2 Permissions protocol | The lifecycle *is* the ex-ante gate: effect reviewed → materialization committed → threshold → executable → submit. Payloads commit to environment/account/slot/expiry (inv 2). `infra/access-policy.json` answers "who may call whom". | Nothing in logos-core asks muster before a module acts. The host policy must grow from allowed callers to allowed *effects*, keyed on the driver manifest's capability name, with dispatch refused unless an executable intent's materialization root matches. Upstream. | M7 |
| 3 Information-flow view | The LEZ `Disclosure{amount, payer, payee}` is a real per-action, per-rail declaration. The claims registry is per-step and static; `observer` lives only on leak claims. | Promote Disclosure to every driver action with an observer set; fold it over the log with the epoch membership at each position. | M1, M5 |
| 4 Deterministic from the contract | `lidl-gen driver` derives effect schema, dCBOR domain tag, card copy, and invoke config from the LIDL, byte-exact; curation and auth model are *declared*, not guessed. | LIDL says nothing about who sees what. Disclosure, requirements, and touches become a third declared input beside `coordinatable` and `tier1`. manifest = f(contract, declarations). | M6 |
| 5 Self-explaining card | The intent card renders effect, threshold, approvals, txhash, rounds from `reduceIntentViews`. | Requirements, readiness, touches, disclosure, and the install/authorize/deny actions. | M1, M2, M3 |
| Credibility classification | F-10, claims registry, finality (above). | Name the column on every claim and say who holds the discretion. | M8 |

## 5. Invariant guards (what this must not do)

- **Invariant 3.** A manifest is a description, never a capability grant. "Install" is a pointer to the host's install path; the plugin does not fetch, load, or execute anything.
- **Invariant 6.** Requirements, disclosure, and touches are driver-described per action. The core adds only the baseline disclosure and checks consistency; it never interprets contribution bytes to derive them.
- **Invariant 9.** Under an anonymous driver, readiness never reveals *which* member holds authority, a deny names nobody, and a provenance proof names no account.
- **Invariant 10.** Provenance for non-signing actions *extends* F-20's record; it does not create a second lineage store. The record stays a reduction over the log (invariant 4).
- **Honesty rules (00-vision).** `declared: false` and `unknown` are shown as such. A driver that lies in its manifest fails conformance (M1 consistency check), so a card can never render a truthfulness the code does not have.

## 6. Plan

Slices are pebbles issues under epic `exo-002`. Run `pb dep tree exo-002` for live status.

| Slice | Issue | Depends on | Done when |
|---|---|---|---|
| **M1** Manifest seam: `Driver.manifest(effect)` with agreement + requirements + disclosure + touches; conformance consistency check; all six drivers declare; LEZ `disclosureOf` maps to rows | `exo-002.1` | — | Conformance green with the manifest checks on every driver; a stub with `declared = false` fails. |
| **M2** Readiness: `coordinate_readiness(intent)` grades each requirement for this instance with an honest `unknown` — **landed** (`coordination/readiness.nim`, `readiness_test` 6/6) | `exo-002.2` | M1 | A Safe intent on an instance without RPC reports `infra: missing` + remedy; a non-owner reports `authority: missing`. |
| **M3** Card: five questions + per-participant readiness + install / authorize / approve / deny | `exo-002.3` | M2 | A proposer sees the peer's missing dependency on the card; the peer can deny. Launch-verified in the runner. |
| **M4** Provenance for all actions: messages/admits/drops carry an input record; epoch-scoped exportable proof | `exo-002.4` | (`exo-275`) | Proof verifies iff the log is unchanged; tamper refuses. Out-of-room proof scope decided and documented. |
| **M5** Information-flow view: fold log × disclosure × epoch membership into a per-action observer matrix | `exo-002.5` | M1, M4 | Walkthrough's static claims and the derived matrix agree on every step for a Safe intent; the derived view names the store node. |
| **M6** `lidl-gen driver` emits manifest declarations as a third declared input | `exo-002.6` | M1 | Emitted manifest `nim check`s clean and passes consistency; `metadata.json` rev bumped. (SDK repo.) |
| **M7** Host hook: allowed effects keyed on capability name; dispatch refused without a matching executable intent | `exo-002.7` | M6 | Proposal doc + policy schema drafted here; raised with Basecamp. muster's half: `coordinate_authorization(intent)`. (Upstream.) |
| **M8** Credibility column on the claims registry + discretion holder | `exo-002.8` | — | Registry validates; QML regenerated; walkthrough renders the column. |

Order of attack: M1 → M2 → M3 delivers want 5 end to end on the existing drivers and is the visible payoff. M8 is small and can go any time. M4 and M5 make want 1 and want 3 real. M6 closes want 4. M7 is the long pole and is not ours to land alone, so it is raised early and tracked, not waited on.

Relation to existing issues: `exo-1ec.4` is the driver **config** manifest (a settings seam the host reads without loading the driver); this epic is the per-**action** manifest. They share the "self-describing driver" model and the conformance-fails-a-lying-manifest rule, and should share a schema language once `exo-1ec.3` settles it. `exo-1ec.5`'s provenance rung is what M4 builds on. `exo-275` (membership transitions as log events) is a prerequisite for M4 covering admits.

## 7. Resuming across sessions

- `pb show exo-002` then `pb ready` to find the next unblocked slice.
- Code lives in `module/src/intents/disclosure.nim`, `module/src/drivers/manifest.nim` (+ the per-driver `manifest` overrides), and `module/src/coordination/readiness.nim` (the probe + `HostFacts`; the hosted handler is `musterCoordinateReadiness` in `nim-lib/muster_module.nim`, surface method `coordinate_readiness`). Tests: `module/tests/manifest_test.nim` (pure Nim), `readiness_test.nim` + `conformance_test.nim` (need the secp + libsodium closure, see `module/tests/README.md`).
- The `coordinate_readiness` payload is what M3's card renders: `{intentId, policy, effect, declared, ready, unknown, items:[{kind,name,scope,status,detail,remedy}], manifest:{agreement, requirements, discloses, touches}}`.
- The conformance suite is the gate: never merge a slice with it red.

## 8. Open questions

1. **Out-of-room proofs (M4).** An exportable proof is selective disclosure of a log slice to a non-member. Is that in scope for v0, or does "proof" mean in-room recomputation only? The epoch model answers *who can check*; it does not answer whether we build the export.
2. **Requirement scope granularity (M2).** `instance` vs `contributor` is enough for Safe and threshold. A future driver may need "at least k contributors", which is the agreement's threshold applied to an authority requirement; decide whether that is derived or declared.
3. **Deny semantics (M3).** A deny is informational until a driver says otherwise: it does not block the threshold unless the driver's membership model treats the roster as closed. Whether a deny by a required signer should *drop* the intent is driver-described, not core policy.
4. **Capability address (M6/M7).** The driver manifest already carries a Basecamp capability name (SDK #2). The host hook keys on it; confirm with the Basecamp side that the broker can consult an external module before dispatch at all.
