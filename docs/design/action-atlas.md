# The action atlas: every action a person can take in Muster, in full detail

**Status:** landed, 2026-09-28. Epic `exo-661` (A1–A5 below), closed. Served at
<https://corpetty.github.io/muster/atlas/>: the multisig family registry and, for each
family, room and wallet, its actions (#162, #163; the corrections in §8).

## 1. What was asked

A corpus of **every action a person can and will be able to take in Muster**, with its
full detail, shareable by link. Scope, as chosen on 2026-09-27:

- **every coordination family**, expanded into its actions — not just "a Safe", but
  "send ETH from a Safe", "call a contract from a Safe", each with its own effect,
  requirements and disclosure;
- **the room actions that are not a family** — chat, decline, share a material,
  disclose an account, run a FROST key ceremony, admit a member, invite, export an
  audit trail;
- **wallet sends** — EVM (ETH and ERC-20), the LEZ's four rails (public / shield /
  deshield / private), and the room-coordinated LEZ transfer;
- **full detail for built and candidate families.** Watch and reject families keep
  their family-level registry entry and its reason; they get no actions.

## 2. What an action is

An action is one thing a person does in Muster whose consequence someone else can see.
It has an **area**:

| area | unit | example |
|---|---|---|
| `family` | a coordination family × one effect kind | `evm.safe/transfer` — send ETH from a Safe |
| `room` | a room operation no driver governs | `room/decline` — the card's Deny |
| `wallet` | a send from this member's own wallet | `wallet/lez-shield` — public → private on the LEZ |

A family action is the whole lifecycle of one proposal under one family: propose,
approve (in-app, outside, a vote, or FROST rounds), settle, final. Its approval and
settlement steps come from the family; its effect, requirements and disclosure come
from the (driver, effect) pair — the same pair `Driver.manifest(effect)` is computed
for (`docs/design/action-manifest.md`).

## 3. The fields, and where each one's truth comes from

The rule: **nothing is hand-typed that the code can say.** A built action's machine
facts are generated from the running code; its narrative is authored and must cite the
test that proves it. A declared (not built) action is authored in the same closed
vocabulary and must cite a primary source.

| field | meaning | built: from | declared: from |
|---|---|---|---|
| `id`, `name`, `area`, `family`, `kind` | identity; `family` is a registry id, `kind` a driver kind | authored, checked against the registry and `kinds.nim` | authored, checked against the registry |
| `status` | `built` · `partial` · `declared` | authored, must agree with the family's registry status | `declared` |
| `summary` | what it does, in plain words | authored | authored |
| `effect` | schema id + each field and what it means | schema id **generated**; field meanings authored | authored |
| `agreement` | rounds, threshold, finality, signing domain | **generated** — `describe()` | declared |
| `profile` | the family's facts on this instance (locus, binding, ordering, expiry, reveals, bypasses…) | **generated** — `profile()` | the registry entry |
| `requirements` | what each party must hold (kind · party · material class · target · field) | **generated** — `manifest(effect)` | declared, closed vocabulary |
| `touches` | what it reads / writes outside the room | **generated** | declared |
| `disclosure` | which field reaches which observer, and when | **generated** — the manifest plus the core's baseline (the store node, FS-9) | declared, closed vocabulary |
| `steps` | per lifecycle step: who acts, what they do, what bytes they sign, what becomes visible to whom | authored, each step citing evidence | authored |
| `refusals` | what Muster refuses in this action, and why | authored, each citing the test that proves it | authored (what the family's rules imply) |
| `hosted`, `ui` | the `muster.lidl` methods and the UI surface that drive it | authored, checked: each method exists in `muster.lidl` | — |
| `invariants` | which of the ten it leans on | authored | authored |
| `credibility` | per claim: imperative / motivational / exposed (the claims registry's axis) | authored | authored |
| `evidence` | tests and probes (paths must exist) | authored, checked | primary sources (URLs), required |

The closed vocabularies are the code's: requirement kinds, parties and material classes
from `drivers/manifest.nim`; observers from `intents/disclosure.nim` (`room-member`,
`store-node`, `rpc-provider`, `chain-observer`, `target-module`); family fields from
`contracts/families/registry.json`. A value outside them fails the checker.

### 3a. The files

```
contracts/actions/
  generated.json          machine facts for every built (kind, effect variant) — never edited by hand
  family/<family-id>.json one file per built or candidate family: its actions (authored)
  room.json               the room actions (authored)
  wallet.json             the wallet sends (authored)
```

A **generated entry** (`generated.json` → `entries["<kind>/<variant>"]`):

```json
{ "kind": "safe", "variant": "transfer", "family": "evm.safe",
  "effectExample": { "schema": "muster.effect.transfer.v1", "fields": { "to": "0x…", "value": 1, "nonce": 0 } },
  "describe":   { "rounds": 1, "threshold": 2, "finality": "…", "domain": "…" },
  "environment": "eip155:31337",
  "profile":    { …drivers/profile.nim toJson… },
  "manifest":   { …coordination/readiness.nim toJson(ActionManifest)… },
  "signRefusal": "" }
```

An **action**. Each authored file is `{ "actions": [ … ] }`:

```json
{
  "id": "evm.safe/transfer",
  "name": "Send ETH from a Safe",
  "area": "family",
  "family": "evm.safe",
  "kind": "safe",
  "status": "built",
  "summary": "Two of three owners send ETH from their Safe; each approves in the room, and one submits.",
  "generated": "safe/transfer",
  "effect": { "schema": "muster.effect.transfer.v1",
              "fields": [ { "name": "to", "means": "the payee's address" } ] },
  "agreement":    { "rounds": 1, "threshold": "2 of 3", "finality": "…", "domain": "…" },
  "requirements": [ { "kind": "authority", "name": "safe-owner", "party": "contributor",
                      "class": "authority", "target": "safe:0x…", "field": "" } ],
  "touches":      [ { "target": "safe:0x…", "mode": "write" } ],
  "disclosure":   [ { "field": "to", "observer": "chain-observer", "when": "settle" } ],
  "steps": [ { "step": "propose", "who": "proposer",
               "does": "composes the effect; the room re-derives its safeTxHash",
               "signs": "", "reveals": [ { "field": "effect", "observer": "room-member" } ],
               "evidence": [ "module/tests/coordination_surface_test.nim" ] } ],
  "refusals": [ { "what": "an approval over a hash that is not the re-derived one",
                  "why": "invariant 1 — refuse on mismatch",
                  "evidence": [ "module/tests/probes/probe_materialization_mismatch_refused.nim" ] } ],
  "hosted": [ "coordinate_propose", "coordinate_contribute", "coordinate_submit" ],
  "ui": "Room → Propose → Safe transfer",
  "invariants": [ 1, 2, 4, 10 ],
  "claims": [ { "claim": "the owners sign exactly what the Safe checks", "credibility": "imperative" } ],
  "evidence": [ { "kind": "test", "path": "module/tests/safe_real_anvil_e2e.nim" },
                { "kind": "source", "url": "https://…", "what": "…" } ]
}
```

- **Machine fields.** `agreement`, `requirements`, `touches` and `disclosure` are omitted on
  a built family action: they come from its generated entry. A declared action carries
  them. So does a room or wallet action, whose facts no single driver manifest holds;
  there each value cites evidence.
- **Setup actions.** A built family action that is not a proposal has no generated entry
  and carries its machine fields as a room action does. Creating a LEZ multisig on chain
  is one; a family's key ceremony is another.
- **`unverified`** is an optional list of claims not yet confirmed against a primary
  source. The atlas shows them, as the registry's are shown.
- **Generated keys.** The variants are fixed:
  - `safe/transfer`, `safe/contract-call`, `safe/delegatecall`;
  - `threshold/statement`, `threshold/add-driver`, `unanimous/statement`;
  - `frost/statement`, `eip191/statement`;
  - `invoke/module-call`, `invoke/lez-transfer`;
  - `btc-p2wsh/spend`, `btc-tapscript/spend`, `btc-frost/spend`;
  - `lez-multisig/transfer`, `lez-multisig/vault-init`, `lez-frost/transfer`.
- **`step`** is one of `propose` · `approve` · `ceremony` · `vote` · `settle` · `final` ·
  `act`. `act` is a one-step action: a room or wallet operation.
- **`when`** is one of `propose` · `approve` · `settle` · `final` · `act` · `always`. The
  step at which the field reaches that observer.
- **`credibility`** is `imperative` · `motivational` · `exposed` · `not-applicable`, the
  claims registry's axis.

## 4. The pieces and the gates

- **`module/tools/action_corpus.nim`** builds every registry kind from the same fixtures
  `profile_test` uses, and for each (kind, effect) it accepts emits `describe()`,
  `profile()`, `environment()` and `manifest(effect)` as JSON:
  **`contracts/actions/generated.json`**.
- **`action_corpus_test`** (in `run-suite.sh`) regenerates it and fails when the committed
  file differs, so a change to a driver's manifest cannot leave the atlas behind.
- **`contracts/actions/{family/*,room,wallet}.json`** is the authored corpus. A built
  family action names its generated entry (`"generated": "safe/transfer"`) and never
  restates what that entry holds.
- **`scripts/check-action-corpus.py`**, in pre-commit, fails on:
  - a value outside a vocabulary;
  - a built action whose generated entry is missing;
  - a declared action with no primary source;
  - an evidence path that is not on disk;
  - a hosted method not in `muster.lidl`;
  - a family action whose status disagrees with its family's registry status;
  - a built or candidate family with no action;
  - the atlas's embedded copy being stale (`--write` refreshes it, as
    `check-family-registry.py --write-table` does for the registry).
- **The atlas** embeds the family registry and the merged corpus: authored, plus
  generated for the built actions. The Pages workflow publishes only when both
  checkers pass.

## 5. What the atlas shows

The URL stays `/atlas/`; the page becomes the **Muster action atlas**. The family
explorer stays as it is, and each family gains its actions. New views:

- **by area** — family, room, wallet;
- **by observer** — everything a store node, an RPC provider or a chain observer can
  learn, across every action;
- **by requirement** — what you must hold, per party;
- **one action** — every field of §3, its steps as a timeline, and its refusals with
  the tests that prove them.

`built`, `partial` and `declared` are shown on every action's face, as the figures'
status pills are, so a screenshot cannot lose the caveat.

## 6. What this must not do

- **Claim more than the code guarantees.** The educational layer explains what the code
  already guarantees (CLAUDE.md, working agreements). A declared action is never drawn
  as built, and an undeclared manifest shows as undeclared — never guessed.
- **Drift.** Machine facts are generated, never copied. The narrative cites tests, and a
  test path that disappears fails the checker.
- **Invent vocabulary.** Every enumerated value is the code's or the registry's.

## 7. Plan

All five slices landed. The pebbles were renamed under the epic (the earlier ids are in
parentheses).

| slice | pebble | what |
|---|---|---|
| A1 | `exo-661.1` (`exo-dc7`) | this document |
| A2 | `exo-661.2` (`exo-3b8`) | the generator + `generated.json` + the golden test |
| A3 | `exo-661.3` (`exo-009`) | `family/*.json` for every built family, `room.json`, `wallet.json`; the checker |
| A4 | `exo-661.4` (`exo-6bd`) | the atlas shows actions (the new views; embedded corpus; the Pages gate) |
| A5 | `exo-661.5` (`exo-889`) | declared actions for the 13 candidate families, each with primary sources |

## 8. What writing it found

Authoring the corpus against the code and the primary sources surfaced defects the atlas
would otherwise have taught as fact:

- **`exo-661.6`** (closed) — built manifests were imprecise: a Safe call asked a
  counterparty for a payee; chains and accounts had several names; LEZ actions left out
  the accounts and program they touch. Now a chain is CAIP-2, an account CAIP-10, and
  `manifest_precision_test` holds every generated (kind, variant) to it.
- **`exo-661.8`** (closed) — the family registry kept values the A5 research contradicted.
  Each was re-verified against a pinned primary source or a live chain read, then
  corrected in the registry and the declared actions (among them a new declared action,
  `sui.multisig/rekey-by-alias`, for the in-place route the registry now declares).
- **`exo-661.7`** (open, P1, moved out of this epic) — the store node sees more than
  topic and timing.
