# Ask: the LEZ Wallet App declares a provisioning capability

**To:** the LEZ Wallet App team (`lez_wallet_ui`, `logos-blockchain/logos-execution-zone-wallet-ui`).
**From:** the Muster team (`corpetty/muster`).
**Date:** 2026-09-17. **Status:** request for comment — nothing here is built on your side; this is to start the conversation.
**Contact / details:** `docs/design/lez-wallet-delegation.md` in the Muster repo.

## One line

We would like the LEZ Wallet App to declare a **`provides` capability** for LEZ account provisioning, so that other Basecamp apps — Muster first — can hand a user off to it (`logos.request(...)`) to create, activate, and fund a LEZ account, instead of re-implementing the wallet.

## Why we're asking

Muster coordinates multi-party actions inside a conversation. One of those actions is a LEZ transfer — sometimes solo, sometimes a room-agreed (k-of-n) send. Before any LEZ transfer, the user needs a set-up, funded LEZ account (the CLI flow is `account new public → auth-transfer init → pinata claim`, per `docs.logos.co/lez/get-started/run-lez-wallet-via-cli`).

Muster's design position (`docs/design/basecamp-capability-alignment.md`, `docs/design/lez-wallet-delegation.md`) is deliberate: **we do not want to rebuild wallet setup and funding.** Your app already does it well, and Basecamp's own guidance is that a user-mediated action like this belongs to a `ui_qml` provider the shell brings forward. So Muster wants to **detect** that a user lacks a funded account and **delegate** provisioning to your app — not ship a second faucet/shield UI.

## The blocker we hit

We read `lez_wallet_ui/metadata.json` (v1.1.1, `master`). It declares:

```json
{ "name": "lez_wallet_ui", "type": "ui_qml", "dependencies": ["lez_core"], … }
```

There is **no `provides` array** — the app exposes no app-to-app capability. So today there is no capability for Muster (or any app) to `logos.request`. The delegation cannot be wired, however the shell's broker matures.

## What we're proposing

Add a `provides` entry to `lez_wallet_ui/metadata.json` for account provisioning. The exact name and shape are yours to decide; a concrete starting point, mirroring how Muster declares its own `coordinate.request`:

```json
"provides": [
  {
    "intent": "lez.wallet.setup",
    "params": [
      { "name": "purpose",  "type": "string", "required": false },
      { "name": "minAmount","type": "string", "required": false },
      { "name": "form",     "type": "string", "required": false }
    ]
  }
]
```

- **`lez.wallet.setup`** — bring the wallet forward so the user can create/activate/fund a LEZ account. `purpose` is a human string the app can show ("Muster needs a funded LEZ account to send"); `minAmount` is the base-units the caller would like available (advisory); `form` is `public` / `shielded` when the caller knows which rail it needs.
- **Return:** Muster needs **no secret** back — not keys, not a seed. The account and its keys stay in your app and in `lez_core`. A minimal success/cancel result is enough; Muster re-reads the public state (`lez_core.list_accounts` / `get_balance`) itself to confirm the account now exists and is funded. If you want to return the public account id or a shielded receiving key, that is useful but not required.

A second, narrower capability would also help the room case:

- **`lez.wallet.receiveAddress`** — reply with a receiving address (a public id, or a shielded key node) the user chooses to be paid at. Muster already carries this as "counterparty material" a recipient shares into a room; sourcing it from your app keeps the wallet the single home for keys.

## What this gets you

- Your app becomes the **canonical LEZ wallet** other Basecamp apps route to for setup/funding, rather than each app reinventing it.
- The account keys and the faucet proof-of-work stay entirely in your app + `lez_core`. Callers never see a secret; they get "provisioning happened," then read public state.

## What Muster does today, without this

We detect and prompt. A LEZ action's card shows whether the user has a funded account (read via `lez_core.list_accounts` / `get_balance`), and when not, it renders an honest prompt — "Open the LEZ Wallet App to set up a funded account." It is informational until a capability exists to hand off to. That work is already shipped (Muster epic `exo-44b`, slices L1–L2); this ask unblocks the automatic hand-off (L4).

## The other half

The hand-off also needs the Basecamp shell's **app-to-app intent dispatch** to be routing `logos.request` to providers. That is a separate ask to the Basecamp/logos-core side — see `docs/upstream/app-to-app-intent-broker.md`. Your `provides` declaration and the shell's dispatch are independent prerequisites; either can land first.

## Questions for you

1. Is a provisioning `provides` capability something you'd take, and what would you name it?
2. What result shape can the wallet return through an app-to-app intent — success/cancel only, or the public account id / receiving key too?
3. Should setup be one capability or split (create+activate vs. faucet/shield), so a caller can ask for exactly the state it needs per rail?
