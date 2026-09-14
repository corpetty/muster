# "Musters" and how Basecamp/logos-core want apps to communicate

**Status:** design assessment (2026-09-14). Checks muster's structuring of *musters* —
the things you can do within muster (the driver-derivation catalog, epic exo-fa4) —
against how logos-basecamp and logos-core actually route work between modules and apps.
Grounded in `logos-basecamp/README.md` §"App-to-app intents" + §"Inter-module access
enforcement" and `logos-basecamp/docs/app-to-app-intents.md`. Keeps the coming CDDL
schema-identity change (invariant 5b / ADR-009, which `logos-nim-sdk` was built around)
in view.

## 1. The two communication layers Basecamp defines

Basecamp is explicit that these are **different mechanisms, on purpose**:

1. **Core-to-core (backend → backend).** A core module calls another **directly by
   name** through `LogosAPI` / the `lp_*` ABI — no chooser, no consent step, "because
   nothing is being decided." Gated by `--access-policy enforce`: **deny-by-default**,
   the allow-list *derived from each module's `metadata.json` `dependencies`*. *"A
   backend that needs another backend should make that call, not raise an intent."*
2. **App-to-app intents (UI, user-mediated).** `logos.request("wallet.send", payload,
   cb)` — the caller names a **capability, never a provider**; the **shell** resolves it
   to a `ui_qml` app that *declared* it, asks the user which one, brings it forward, and
   routes the one result back to the caller alone. Declared via **`provides` / `uses`**
   in `metadata.json`. *"Providers are `ui_qml` apps, by design"* — intents exist for
   user-mediated actions where a human chooses the servicer.

The split matters for muster because a *muster* (a thing you can do together) touches
both layers, and they must not be conflated.

## 2. Where muster is already aligned

- **Backend calls are the sanctioned pattern.** `muster_module` (a `core` module) drives
  `delivery_module`, `lez_core`, and the Safe RPC **directly over `lp_*` by name** — not
  via intents. That is exactly what Basecamp says a backend should do.
- **The invoke gate already speaks Basecamp's capability language.** The execute gate's
  CAPABILITY half (`invoker.nim`) is precisely the **`lp_*` access-policy capability**:
  "the call must succeed under the TARGET module's own capability policy, which the
  `lp_*` layer enforces." That is the same mechanism `--access-policy enforce` arms from
  `dependencies` — muster's allowlist+capability gate sits *on top of* it, adding the
  room-agreement precondition.
- **Dependencies are declared** (`delivery_module`, `lez_core`), so the derived
  allow-list already covers muster's real backend calls.
- **Contract-first + a versioned schema id.** The surface is generated from
  `muster.lidl` (CDDL-family types), and every coordinatable action carries a
  domain-separated, versioned schema id (`muster.invoke.<module>.<method>.v1`) — the
  field the CDDL migration slots into (§5).

## 3. Where muster diverges — the gaps

1. **Muster declares no `provides`/`uses`.** `capabilities: []`, no `provides`, no
   `uses`. So muster's *musters* are an **internal catalog**, invisible to Basecamp's
   intent layer. Two consequences:
   - No other app can `logos.request` muster to *coordinate* something. Muster's core
     value — "do this **with other people**" — is not offered as a capability.
   - "Send λ" drives `lez_core` directly rather than requesting a wallet/LEZ capability,
     **re-implementing** what Basecamp already ships as a first-party **LEZ Wallet App**
     (`logos-execution-zone-wallet-ui`: init accounts, inspect balances, public/private
     transfers).
2. **Two vocabularies for the same idea.** A *muster* is named `invoke module.method`
   (`lez_core.transfer_shielded`); a Basecamp capability is `noun.verb` (`wallet.send`).
   These should share a namespace so the driver-derivation catalog and the capability
   catalog are one vocabulary.
3. **The `ui_qml`-caller access-policy trap (a live gotcha, not hypothetical).** Basecamp
   README's known limitation: under `--access-policy enforce`, `ui_qml` callers are *not*
   in the derived allow-list, so **`muster_ui → muster_module` would be denied**. Muster
   runs today because enforce is off by default; the moment a host turns it on, muster
   breaks unless `muster_ui` is named explicitly in a policy document. Muster should ship
   that policy doc (or a note) so enforce-on doesn't silently break its own UI→backend.

## 4. The alignment: musters compose *above* app-to-app intents

Muster is a **layer above** Basecamp's intents: intents are single-user, user-mediated,
one-shot; a muster is **multi-party, room-coordinated**. The clean structure:

- **Muster as a capability PROVIDER — the natural home for "musters."** `muster_ui`
  should `provides` a coordination meta-capability, e.g. **`coordinate.request`** (or a
  per-action set the driver-derivation catalog generates). Then any Basecamp app does
  `logos.request("coordinate.request", { capability: "wallet.send", payload: {…} })` →
  muster opens/uses a room, runs the k-of-n approval (**the room *is* the user-mediation,
  generalised from one chooser to many participants**), and the action settles. This
  offers muster's whole reason for existing — coordination — to the ecosystem the
  Basecamp way, without any app linking against muster.
- **Muster as a capability REQUESTER — for execution, only where it would duplicate a
  first-party app.** Two honest options for *executing* an agreed action:
  - **(a) drive the backend directly** (core-to-core, no chooser). Correct for a
    *coordinated* settle: the room already decided, and `muster_module → lez_core/safe`
    is the sanctioned backend pattern. This is what muster does now.
  - **(b) `logos.request` the underlying capability** (`wallet.send`, a LEZ capability),
    letting the user's chosen wallet app service it. Reuses first-party apps but adds a
    per-execution chooser — which fights "the room already agreed."
  Recommendation: **(a) for coordinated execution**; consider **(b) only for the *solo*
  "Send λ" path**, where delegating to the LEZ Wallet App avoids re-implementing it.
  Coordination is muster's value; a plain solo transfer is not.
- **Keep the capability NAME and the effect SCHEMA-ID separate.** The capability name is
  the routing key (Basecamp); the schema id is the signed-bytes domain (invariant 5).
  Do not fuse them — see §5.

## 5. The CDDL future — muster is already shaped for it

Basecamp validates an intent payload's shape (`bad_request` on a wrong shape), so the
**payload schema is a real interface**, today ad-hoc JSON. When cdCDDLe ratifies
(invariant **5b** / ADR-009), schema identity moves from hand-assigned ids to **cdCDDLe
schema roots** carried in the same `profile` + `schema-id` field. Muster is structured
for this and should stay that way:

- The effect's `schema-id` (`muster.invoke.<module>.<method>.v1`) is **already a
  first-class, versioned field** — the exact slot a cdCDDLe root replaces, touching only
  the signed-bytes derivation, never invariant 5's determinism (the 5b/5 firewall).
- **`logos-nim-sdk`'s `lidl-gen driver` mode (P-D5) is the generator** that emits a
  muster's effect schema + domain tag + card from a LIDL contract. It is the seam where
  a coordinatable capability's *data schema* is produced, and it is built to swap
  hand-ids for schema roots without the consumers changing. So the driver-derivation
  catalog is the CDDL-ready expression of "the things you can do."
- **Therefore:** the capability **name** (Basecamp routing) and the effect **schema-id**
  (CDDL / signed bytes) are two fields with two lifecycles. A muster manifest entry
  should carry **both** — `{ capability: "wallet.send", schemaId: "muster.invoke…v1",
  payloadSchema: <cdCDDLe root, later> }` — so the Basecamp routing key is stable while
  the schema identity migrates under it.

## 6. Concrete, low-risk next steps

1. **Declare what muster already does.** Add `uses` (the capabilities/modules muster
   calls) and, on `muster_ui`, a `provides` for the coordination capability — even before
   wiring the broker, so the catalog and the access policy see muster honestly.
2. **Ship the enforce-mode policy note** naming `muster_ui → muster_module`, so
   `--access-policy enforce` doesn't silently break muster's own UI.
3. **Make the driver-derivation manifest carry the capability name** beside the schema
   id (extend the P-D5 `genDriver` entry), so a muster is addressable *both* as a
   Basecamp capability and as a CDDL-typed effect.
4. **Solo-send delegation — DECIDED: keep the direct `lez_core` drive.** The "Send λ"
   path stays core-to-core (`muster_module → lez_core`), not an `app-to-app` intent to
   the LEZ Wallet App, because: (a) it works in the **standalone runner** (`make run`),
   where there is no Basecamp broker to dispatch an intent; (b) it is the same path a
   **coordinated** send needs (Mode B), so one mechanism serves both; and (c)
   `muster_module` calling `lez_core` is the sanctioned backend pattern (§1) — no chooser
   is wanted for an action muster already mediates (solo: the user; coordinated: the
   room). Delegating to the LEZ Wallet App via `logos.request` is recorded as a
   **Basecamp-only future refinement** — worth it only if muster runs exclusively inside
   Basecamp and wants to stop shipping its own LEZ wallet code; until then the direct
   drive is the correct call, and it is why muster_ui declares **no `uses`** for a wallet
   capability today.

**Done so far (2026-09-14):** step 1 — muster_ui declares `provides:
["coordinate.request"]` + `uses: []` (the handler is the remaining wire); step 2 —
[`docs/basecamp-access-policy.md`](../basecamp-access-policy.md) +
[`infra/access-policy.json`](../../infra/access-policy.json); step 3 — the P-D5 manifest
carries a `capability` name beside the schema id (logos-nim-sdk); step 4 — decided above.
The one piece left is the **`coordinate.request` provider handler** in muster_ui (a QML
`onIntentRequested` that opens/uses a room), which needs the Basecamp intent broker and
careful guarding so referencing `logos` doesn't break the standalone render.

Related: [[muster-driver-derivation]], `docs/design/driver-derivation.md`,
`docs/design/lez-adapter.md`, the invoke gate (`module/src/coordination/invoker.nim`).
