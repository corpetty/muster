# Material: what you hold, what an action needs, what you choose to disclose

**Status:** design, 2026-09-16. Epic `exo-45e` (pebbles; `pb dep tree exo-45e` for live status; slices `exo-45e.1`–`.7`). Nothing here is implemented yet.
**Reads with:** `action-manifest.md` (the per-action manifest this extends: requirements, readiness, the self-explaining card), `lez-adapter.md` (Mode A, the one place the pattern already exists), `basecamp-capability-alignment.md` (where the wallet shell lives), FURPS F-9 / F-14 / F-18 / F-19 / F-20 / FS-4 / FS-7 / FS-10.

## 1. What was asked

Three things, 2026-09-16:

1. When **introducing** a muster, pick only from the actions *my account has access to and can do*, across every available muster.
2. Then choose **which material** I hold (addresses, signing keys, assets) becomes part of the proposal.
3. Someone who **receives** a proposal in a room is prompted to disclose the material that is appropriate and needed to complete it, *from what they have access to*.

All three from a personal-disclosure point of view: the application manages the credentials and the backend infrastructure that facilitate the action, and the room plus the proposal's driver make it obvious which action is being facilitated.

These are one mechanism seen from three sides. Call the thing a participant holds **material**, and the mechanism the **offer**: an action's requirements crossed with one participant's holdings, each possible choice labelled with what choosing it discloses and to whom. The compose menu (1) is offers over candidate actions. The proposer's material step (2) is the offer for the proposer's slots. The recipient's prompt (3) is the offer for the contributor's and counterparty's slots. The same function, evaluated by each participant about themselves only.

## 2. What exists today, and where it falls short

| Piece | Today | Short of the ask because |
|---|---|---|
| Identity | One keystore, one secp256k1 authorization key plus one bound Ed25519/X25519 encryption identity (F-14). `myAddress()` is the only account you can act as. | There is nothing to *choose*. Every chain account is derived from the one key; a Safe you co-own is configuration, not a holding. |
| Holdings | `wallet_accounts` lists `{chain, form, id}` per adapter (EVM address, LEZ public id, LEZ shielded key node); `wallet_balances` reads them. | They are a wallet listing, not a catalogue an action can be matched against. No class (authority vs address vs asset), no grade, no link to what requires them. |
| What an action needs | `ActionManifest.requirements` with kind `module / environment / authority / infra / capability` and scope `instance / contributor` (M1). | A requirement names a *kind*, not the material class that satisfies it. There is no `counterparty` scope: an action that needs the payee's address has no way to say so. |
| Do I have it | `coordinate_readiness` grades each requirement for this instance; authority is graded about *you only* (invariant 9); `unknown` is first-class (M2). | Readiness answers yes/no per requirement. It cannot answer *with which of my holdings*, and it is evaluated on an existing intent, so it cannot filter the compose menu. |
| The compose menu | `coordinate_available_actions` lists allowlisted module actions; the composer is verb → people, the account being the one configured Safe (F-18 asks for verb → people → account). | Not filtered by what this account can do. The third step of F-18 is missing. |
| Authority to act on a Safe | `driverForKind("safe")` **adds this instance's address to the owner set** so in-app approval counts (`muster_module.nim:140`, exo-535 increment 2). | Access is *assumed*, not discovered. Readiness reports `safe-owner: met` for a key the chain does not recognize. This is a deliberate demo shim, and it is exactly the thing the ask replaces. |
| The recipient's choice | LEZ Mode A (`LezSend.qml`): the receiver picks which address form to share, and the hint says what each form discloses. The room's `address-share` card carries the result as a message body. | The right pattern, in one driver, as a message. Not bound to a proposal, not in the provenance record, not generalized to signing keys or assets. |

The gap is not a missing screen. It is a missing object between "what an action needs" (the manifest) and "who am I" (the keystore): the participant's holdings, and the act of binding one holding to one requirement.

## 3. The model

### 3.1 Material

```
Material
  class    authority | address | asset | infra | capability
  chain    "evm:31337" | "lez:testnet" | "" (room-native)
  form     public | shielded | contract | hardware | …   (adapter-described)
  handle   opaque local reference (a keystore KeyRef, an adapter account id, a settings key)
  public   what a counterparty would receive if this were disclosed (an address, a key node, a pubkey)
  grade    verified-locally | attested | declared   (F-10: how we know we hold it)
  source   keystore | adapter | configured | host
```

Classes, and what "having access" means for each:

- **authority** — a key that a driver accepts: a secp256k1 account that is an owner of Safe X (verified by reading `getOwners` from the chain, graded F-10, never by adding ourselves), an EIP-191 signer in a declared set, the Ed25519 room identity on the roster, a FROST share. Access = the keystore can sign with it *and* the target recognizes it.
- **address** — a place to receive: an EVM address, a LEZ public id, a LEZ shielded key node. Access = we can later spend what lands there. An address is above all a disclosure act; choosing the shielded form over the public one is the whole of LEZ Mode A.
- **asset** — a balance at an account: ETH at the Safe, λ at a shielded node. Access = authority over the account plus balance ≥ amount (never a zero on a failed read).
- **infra** — the ability to reach: an RPC for chain N, `lez_core` loaded, a delivery node. Already a requirement kind; it becomes a material so that *which* RPC submits is a choice with an observer.
- **capability** — a host grant. `unknown` until the Basecamp broker exists (M7).

**The catalogue** is `reduce(sources)`: keystore accounts, adapter accounts (`wallet_accounts`), configured accounts you co-own (Safes), and, once ADR-013's shell is reachable, host-provided accounts. It is a **local view, never a log entry**: it never leaves the instance, is never serialized into the conversation, and no plugin can read it (FS-4, invariant 3). Only a chosen item leaves, only on an explicit act, and every such act is a log event.

The catalogue holds handles and public material only. Signing stays behind the `Keystore` seam, which grows from one implicit key to keyed operations (`accounts(): seq[KeyRef]`, `sign(ref, hash)`, `bindingFor(ref, ctx)`), so a Keycard with several slots, or a set of keyfiles, slots in behind the same seam.

### 3.2 Requirements name a material class and a party

`Requirement` grows two fields:

```
Requirement
  kind      module | environment | authority | infra | capability | address | asset
            (address + asset added in K1 so participant-supplied material is first-class;
             the closed vocabulary grows by slice, never ad hoc)
  name      "safe-owner" | "chain:31337" | "rpc" | …               (as today)
  party     instance | proposer | contributor | counterparty         (was scope: instance | contributor)
  needs     MaterialClass + constraint  e.g. authority on safe:0x…, address on lez:* any form, asset ETH ≥ effect.value
```

`party` is who must supply it:

- **instance** — this client, whoever it is (an RPC, a loaded module). Unchanged.
- **proposer** — bound at compose time and **written into the effect**: the source account, the asset and amount, the destination. Because it is in the effect it is in the materialization, so it is signed (invariant 1) and replay-bound (invariant 2). Nothing new on the signing path.
- **contributor** — supplied by each contributor from their own holdings at contribute time: which owner key signs, which FROST share. It rides in the contribution, keyed as the driver already keys it; the driver verifies it as today.
- **counterparty** — held by a specific *other* party and needed before the effect is complete: the payee's address, the payee's chosen disclosure form. This is the new case, and the one the recipient's prompt is about.

Conformance checks a declared requirement names a class the catalogue can hold, and that a `proposer` requirement's `needs` refers to an effect field (so a driver cannot require material that has nowhere to land). An external-finality driver must declare its payee address requirement as `counterparty` when the effect has a destination field. The six drivers declare; an undeclared driver's card says so, never guesses (the M1 rule, unchanged).

### 3.3 Offers

```
Offer
  requirement   the slot being filled
  candidates    seq[{material, grade, discloses: seq[DisclosureRow]}]
  status        satisfiable | unsatisfiable | unknown
```

`offers(requirements, catalogue, manifest) → seq[Offer]` is a pure function, graded **about you only**: it says which of *your* holdings fit each slot that is yours to fill, and for each candidate the disclosure rows choosing it would add. It never says which other member holds what (invariant 9 as it already applies to readiness). `unknown` stays first-class: a Safe whose owners could not be read (no RPC) yields `unknown`, never a silent green.

The disclosure rows on a candidate come from the same vocabulary the flow view already folds (M5): choosing a public LEZ id adds `payee → chain observer`; choosing to sign with owner key A adds `controls 0xA → room` now and `signer 0xA → chain observer` at settlement; choosing RPC X adds the signed transaction → `rpc provider (X)`. **Choosing material is choosing observers, and the offer shows the rows before the pick.** This is LEZ Mode A's `shareHint` made general and derived instead of hand-written.

Three evaluations of one function:

| Who | Over which requirements | Surface |
|---|---|---|
| Composer, before choosing an action | every candidate action's `instance` + `proposer` requirements | the compose menu: an action is offered when every proposer-side slot is satisfiable, shown greyed with its unsatisfiable slot named otherwise (never hidden — you should see what you *could* do with one more holding), `unknown` shown as unknown |
| Composer, after choosing an action | that action's `proposer` slots | F-18's third step: pick the account, the asset from real balance (exo-bf9), the destination or a counterparty request |
| Recipient of a proposal | that proposal's `contributor` + `counterparty` slots that are mine to fill | the card's "What this needs" box grows a "From you" section: the slot, my candidates, what each discloses, a pick that performs the binding, or Deny |

### 3.4 Binding: how a chosen material enters the log

Each party's material enters the log through the seam that already exists for that party:

- **proposer** → the effect field. Already the case; the composer just stops assuming the one configured account.
- **contributor** → the contribution. `coordinate_contribute(intent, keyRef)` signs with the chosen key. Under a named driver the room learns which key signed, as it does today; under an anonymous one, only the count.
- **counterparty** → a **`material-share` log event** bound to a proposal or a request: `{intentId | requestId, requirement, public, form}`. This generalizes the `address-share` card from a message body into an event the fold binds. F-20 then names it in the effect's provenance record as a peer-message input at its log position, which is precisely what F-20 already demands of every input on the signing path.
- **authority as identity** → a **binding statement** (F-14, `binding.nim`). The room's name for you is your encryption identity; each secp account you choose to act as in this room is disclosed by publishing a signed link from that key to your encryption identity, epoch-scoped. Signing an approval with key A implies the binding for A. This reuses the existing binding record rather than inventing a second way to say "I control this address".

A proposal with an unfilled `counterparty` slot is **not an intent yet**. Intent ids are content-addressed from a complete effect, and invariant 1 re-derives the materialization from the effect, so a placeholder would either change the id when filled or make the materialization underivable. Instead the composer emits a **request** first (a typed block, as LEZ Mode A does today), the counterparty answers with a `material-share`, and the composer proposes the complete effect with the shared material bound in. The lifecycle stays `draft → proposed → …` with nothing added; the request is the `draft` made visible to the person whose material it needs. Mode B for the LEZ (a room-coordinated private transfer) falls out of this rather than needing its own path.

### 3.5 The room's view (F-9 made live)

F-9 derives each member's role by intersecting chat membership with account membership. With offers, that intersection is per proposal: for the live intent, each member is *needed* (a slot is theirs), *supplied* (their `material-share` or contribution is in the log), *declined* (`coordinate_decline`), or *not needed*. The scope panel shows this; under an anonymous driver, slots count and never name (U-4, U-9). No member ever sees another's catalogue or candidates: the log carries what was supplied, never what could have been.

## 4. Disclosure rules this commits to

These are the invariant-shaped claims a typed spec should carry (a `derived-exo-*` spec with acceptance oracles is the next artefact; see §6).

1. **The catalogue never leaves the instance.** No log event, export, proof, or plugin-reachable surface carries a participant's holdings. Only a chosen material appears, in the event that binds it. (FS-4, invariant 3.)
2. **Nothing is disclosed without an act.** Compose, contribute, and share are the only paths by which material enters the log, each an explicit user action on a surface that showed the disclosure rows first. Entering a room discloses the encryption identity and nothing else (exo-080 kept).
3. **Offers are graded about you only.** The function that computes them takes your catalogue and the room's public facts; it never takes, and can never reveal, another member's holdings. (Invariant 9, as readiness already applies it.)
4. **No fabricated access.** An authority is offered only when the target system, or the driver's declared set, recognizes it: Safe owners are read from the chain and graded F-10; the room roster from the membership fold. The self-injection in `driverForKind("safe")` goes. An approval that could not settle is never shown as one that counts.
5. **Unknown is unknown.** An owner set that could not be read, a balance that failed, a capability with no broker: `unknown`, shown as such, never greyed to `missing` or greened to `met`.
6. **Choosing material is choosing observers.** Every candidate carries the disclosure rows it would add, derived from the manifest's vocabulary, and the flow view renders the rows a binding actually added, from the log, so the promise and the record are the same computation.
7. **Material is material, not a score.** The card classifies (this key is a verified owner; this address is shielded; this RPC will see the transaction). It never ranks candidates for you.

## 5. Where it lives

| Seam | Change |
|---|---|
| `module/src/crypto/keystore.nim` | `KeyRef`; `accounts()`, `sign(ref, …)`, `edSign(ref, …)`, `bindingFor(ref, ctx)`; `FileKeystore` becomes a keyfile set; the in-memory backend takes several. Keycard: several slots behind the same methods. |
| `module/src/wallet/material.nim` (new) | **Landed (K2a):** `Material{class,chain,form,handle,public,grade,source}`, `Disclosable` (the only projection that leaves — public + class, no handle/source), `MaterialSource` seam + `KeystoreSource`/`AdapterSource`/`ConfiguredSafeSource`/`StaticSource`, `catalogue()`, `forClass()`. `material_test` + `probes/probe_catalogue_no_leak.nim` (s1, 0/11 handles cross) green. |
| `module/src/drivers/manifest.nim` | **Landed (K1):** `Requirement.party` (replaced `scope`), `Requirement.needs` (`MaterialClass` + target + effect field), `rqAddress`/`rqAsset` kinds; `consistencyFailures(m, effect)` checks class↔kind alignment + that proposer/counterparty material names an effect field the effect carries; the drivers declare parties + classes; Safe declares the payee as counterparty address bound to `to`. `manifest_test` + `conformance_test` + `readiness_test` green. |
| `module/src/drivers/safe_rpc.nim` | **Landed (K3):** `getOwners(url, safe)` reads the owner set from the chain (`eth_call getOwners()`, `decodeAddressArray`), `known:false` on failure; readiness grades `safe-owner` against the CHAIN set — `unknown` without a chain read, `missing` for a key the chain does not recognize, `met` only when the chain says so; the owner self-injection in `driverForKind("safe")` is removed. `safe_owners_test` + `readiness_test` green; the live-anvil e2e (`safe_anvil_e2e`, in-app approval only for real owners) remains, needs a running chain. |
| `module/src/coordination/offers.nim` (new) | **Landed (K4 core):** `offersFor(reqs, catalogue, manifest, parties)` (pure) + `proposerOffers`/`recipientOffers`/`satisfiable`; each candidate is a `Disclosable` (public only) + grade + the manifest rows its choice would add; capability → `unknown`. Graded about me only (takes only MY catalogue). `offers_test` + `probes/probe_offers_about_me_only.nim` (s3, 200 trials) green. Surface wiring (`compose_offers`/`coordinate_offers` lidl) rides K6. |
| `module/src/coordination/intents.nim` | **Landed (K5 core):** `materialShareEvent` + `reduceShares` (folds one per requirement×sharer, inv 4; only the public face + class travel, s1/s2); `logProvenance` classes a share `peer-message` (F-20) — named under a named driver, a nonce under anonymous (inv 9); `reduceFlow` discloses the shared field to the room, outside rows waiting for submit (s6). `materialshare_test` green. Keyed contribute + per-key F-14 binding ride K2b. |
| `module/src/api/muster.lidl` | **Landed (K6 surface):** `coordinate_offers(intent_id)` (this proposal's slots that are mine), `compose_offers(effect_json)` (a draft's proposer slots), `coordinate_share_material(intent_id, requirement, public)` (share a chosen PUBLIC face, s1). Handlers + `moduleCatalogue()` in `muster_module.nim`. **Needs `tools/regen.sh` + a host build to wire the generated dispatch (muster_gen.nim) — not run in-sandbox.** `coordinate_contribute` gaining a key handle rides the QML wiring. |
| `ui/src/qml/Composer.qml` | **K6 UI (host-build):** the F-18 third step, fed by `compose_offers`; the menu greys rather than hides. |
| `ui/src/qml/MusterCard.qml` | **K6 UI (host-build):** "From you" in the needs box — Room.qml loads `coordinate_offers` into `card.offers` (mirroring `needs()`→`card.readiness`), the card renders slot → candidates (public + grade + rows) → pick, and a pick calls `coordinate_share_material`. |
| `ui/src/qml/LezSend.qml` | Mode A's share half becomes the general counterparty answer; Mode B is a room proposal with a `counterparty` address slot. |
| `contracts/specs/` | `derived-exo-45e.spec.json` — the typed spec for §4, one span-bound oracle per rule (**landed, K0**). |

Out of scope, and why: the wallet management shell (add, import, name accounts) stays Basecamp's per ADR-013; muster consumes accounts as material and does not rebuild the shell. A Keycard backend is a `Keystore` implementation, not part of this epic. Plugins still never see any of it.

## 6. Plan

Slices are pebbles issues under the epic. Order: K1 and K2 are independent; K3 is the honesty fix and can land early; K4 needs K1 + K2; K5 needs K4; K6 needs K4 and K5; K0 (the spec) first, because the accept criteria become the tests (working agreement).

| Slice | Done when |
|---|---|
| **K0 — landed 2026-09-16** Typed spec for §4 with acceptance oracles, via `discuss-issue` (`contracts/specs/derived-exo-45e.spec.json`, intake `exo-a8e`) | Done: 7 span-bound oracles (s1 metamorphic/conservation, s2–s7 trace property_tests), criticality `catastrophic`, passes `validate_spec` + the entrypoint-provenance gate. Each rule → a probe a K1–K6 test implements. |
| **K1 — landed 2026-09-16** Requirement vocabulary: `party` + `needs`; conformance checks; drivers declare | Done: `party` (instance/proposer/contributor/counterparty) + `needs` (material class + target + effect field), `rqAddress`/`rqAsset`; a proposer/counterparty requirement naming no (or an absent) effect field fails, and class↔kind drift fails; the Safe driver declares a counterparty payee address bound to `to`; readiness grades only the instance's own slots (proposer/counterparty deferred to offers). `conformance_test` 9/9 green. The LEZ counterparty is deferred to K6 (Mode B); it is a wallet adapter, not a coordination `Driver`, so it declares no `Driver.manifest`. |
| **K2a — landed 2026-09-16** Holdings catalogue read-model | Done: `catalogue()` folds keystore + adapter + configured + host-static sources into a local view with F-10 grades; the disclosure boundary (`disclosable()` = public + class only) enforces rule s1 at the type level (a `Material` has no whole-object serializer); `material_test` + the s1 conservation probe green. |
| **K2b — landed 2026-09-16** Keyed keystore | Done (additive, keyfile-set-first per open Q1): `KeyRef` + `keyRefs`/`hasKey`/`signWith`/`edSignWith`/`bindingForKey`; the single-key methods act on the primary so no existing caller changed; `signWith` refuses an unknown ref (never a silent fall-through); `FileKeystore.loadKeyfile` adds a keyfile to the set, `InMemoryKeystore.addKey` adds an in-memory key; `KeystoreSource` enumerates all keys into the catalogue. `keystore_test` 9/9 + `material_test` + the s1 probe green, no regression (`binding_test`, `in_app_signing_test`). |
| **K3** Verified authority: Safe owners from chain; self-injection removed | `readiness` reports `safe-owner: missing` for a non-owner key against live anvil and `unknown` with no RPC; `safe_anvil_e2e` still green with anvil-seeded owners; the in-app approval path proves it only counts for real owners. |
| **K4 core — landed 2026-09-16** Offers logic + s3 probe | Done: `offersFor` crosses a manifest's participant slots with MY catalogue → candidates (public projection + grade + the rows each choice discloses), `satisfiable`/`unknown` statuses; graded about me only. `offers_test` (owner/payee fill, s6 rows, s3 invariance, unsatisfiable + capability-unknown, proposer vs recipient parties) + the s3 probe (200 trials, offers invariant to others, nothing leaked) green. |
| **K4 surface** `compose_offers()` + `coordinate_offers(intent_id)` lidl + handlers (build the catalogue from real sources, per-intent slots) | Rides K6 (needs the regen + host build the UI slice also needs). |
| **K5** Binding events: `material-share`, keyed contribute, per-key binding in-room | A counterparty share folds onto the request, the composed effect's provenance names it at its position, `coordinate_flow` shows the rows it added, and the proof (`coordinate_proof`) covers it. Under an anonymous driver, nothing names the sharer. |
| **K6 surface + wiring — landed 2026-09-16, build-verified** | Done and BUILT: `coordinate_offers`/`compose_offers`/`coordinate_share_material` in muster.lidl + handlers + `moduleCatalogue()`; regen'd (`tools/regen.sh`) so the dispatch is wired; the module `.lgx` builds (nix `.#lgx-portable`). Backend: `muster_ui.rep` + `.cpp` (`offersJson`/`loadOffers`/`shareMaterial`); the UI `.lgx` builds (nix `.#lgx`). QML: Room.qml folds `offersJson`→`card.offers`; MusterCard renders the "From you" picker → `coordinate_share_material` (shares the PUBLIC face only, s1). `offers_test` green for the payload. The share param is `public_face` (`public` is a C++ keyword — caught by the UI build). Remaining: the on-screen RENDER (nix does not eval QML, ADR-013) — the offscreen self-test, and the composer's third step + LEZ Mode B. |

## 7. Open questions

1. **Where does the second account come from first? — settled 2026-09-16: keyfile set.** K2 ships the keyfile set so the model is testable without the host shell; the host source is a stub reporting `unknown` until ADR-013's wallet shell is reachable, on the same footing as `capability`. Basecamp's shell remains the eventual source, consumed, not rebuilt.
2. **Counterparty slots and content addressing — settled 2026-09-16: request-first.** A proposal with an unfilled counterparty slot is a request (a typed block), not an intent; the counterparty answers with a `material-share`, and the complete effect is then proposed content-addressed as usual (§3.4). The effect-with-a-hole alternative is rejected: it would break the "the id is the effect" property every host relies on.
3. **Anonymous drivers and counterparty material.** A `material-share` from a named member is a disclosure; under an anonymous driver the share must be unlinkable to the member (a nonce-keyed event, as `coordinate_decline` already does) while still binding to the request. Whether an anonymous room can have a *named payee* at all is driver-described; the conformance check should refuse a driver that declares both an anonymous membership model and a counterparty requirement whose material names a person.
4. **Infra as material.** Offering "which RPC submits" per proposal is honest but may be noise. Proposal: it is a candidate in the offer only when more than one is configured; otherwise the settings default is shown as the single candidate with its observer row, so the disclosure is stated without a choice being forced.
