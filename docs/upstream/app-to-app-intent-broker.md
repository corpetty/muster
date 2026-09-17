# Ask: the Basecamp shell dispatches app-to-app intents (`logos.request`)

**To:** the Basecamp / logos-core team (`logos-co/logos-basecamp`, the shell).
**From:** the Muster team (`corpetty/muster`).
**Date:** 2026-09-17. **Status:** request for comment.
**Reads with:** `docs/design/basecamp-capability-alignment.md` (our analysis of the two comms layers), `docs/design/host-effect-policy.md` (the *separate* effect-authorization ask, below).

## One line

We'd like to confirm the status of the shell's **app-to-app intent broker** — the piece that resolves `logos.request("<capability>", payload, cb)` to a `ui_qml` provider, brings it forward, and routes the one result back — and to state precisely what Muster needs from it, as both a **provider** and a **consumer** of capabilities.

## Why this matters to Muster

Basecamp defines two communication layers (`logos-basecamp/README.md` §"App-to-app intents"), and Muster sits across both:

- **Core-to-core** (backend → backend, by name, no chooser). Muster already uses this: `muster_module` drives `delivery_module`, `lez_core`, and the Safe RPC directly over `lp_*`. Working, and the sanctioned pattern.
- **App-to-app intents** (UI, user-mediated). This is the one we're asking about. It is where Muster's value — *coordinate this with other people* — is offered to the ecosystem, and where Muster consumes first-party apps (a wallet) instead of re-implementing them.

## What Muster provides (declared, awaiting dispatch)

`muster_ui/metadata.json` already declares:

```json
"provides": [
  { "intent": "coordinate.request",
    "params": [
      { "name": "capability", "type": "string", "required": true },
      { "name": "payload",    "type": "string", "required": true },
      { "name": "room",       "type": "string", "required": false } ] }
]
```

The intent: any Basecamp app does `logos.request("coordinate.request", { capability: "wallet.send", payload: {…} })`, and Muster opens/uses a room, runs the k-of-n agreement (**the room is the user-mediation, generalised from one chooser to many**), and the agreed action settles. This offers coordination to the ecosystem the Basecamp way, with no app linking against Muster.

**What we need:** the shell to route a `logos.request("coordinate.request", …)` from any app to `muster_ui`, and to deliver the single result back to the caller. Today that handler is declared but, as far as we can tell, not dispatched.

## What Muster consumes (blocked on this + a provider)

For LEZ wallet setup, Muster wants to `logos.request` a **provisioning capability** so the user's LEZ Wallet App comes forward to create/activate/fund an account — rather than Muster shipping a faucet/shield UI (`docs/design/lez-wallet-delegation.md`). This needs two things, both currently missing:

1. **the shell's app-to-app dispatch** (this ask), and
2. **a provider that declares the capability** — the LEZ Wallet App currently declares no `provides` (a separate ask, `docs/upstream/lez-wallet-provides-capability.md`).

## Specific questions

1. **Status.** Is app-to-app intent dispatch (`logos.request` → resolve → front the provider → route the result) implemented in the shell today, on a branch, or roadmap-only? We've been treating it as "declared but not dispatching."
2. **Provider callback contract.** What is the exact shape a `ui_qml` provider returns, and how is the single result delivered to the caller (`cb`)? We need it for both directions (Muster as provider of `coordinate.request`, Muster as consumer of a wallet capability).
3. **The `ui_qml`-caller access-policy trap.** `logos-basecamp/README.md` notes that under `--access-policy enforce`, `ui_qml` callers are not in the derived allow-list, so `muster_ui → muster_module` would be denied. We ship `infra/access-policy.json` naming that edge; is that the intended remedy, or should the shell derive UI→backend edges automatically?
4. **Standalone hosts.** Muster also runs in a standalone runner with no shell/broker. There, `logos.request` has nothing to dispatch to. Is a no-broker fallback expected of apps (Muster keeps a direct `lez_core` path for the solo case, per our §6.4 decision), or is the shell assumed present?

## The related — but separate — effect-authorization ask

Distinct from routing intents is the question *"what did the room agree to, before a gated module call runs?"* Muster already produces a signed, replay-bound authorization grant for an executable intent (`coordinate_authorization`), and we've written a full proposal for a host hook that consults it before dispatch: **`docs/design/host-effect-policy.md`** (tracked as `exo-002.7` / M7). That is about gating **core-to-core execution** on room agreement; this document is about **app-to-app intent routing**. They compose but are independent — please read both.

## What Muster does today, without this

Everything that does not need the broker is shipped: core-to-core execution (direct `lp_*`), the `coordinate.request` declaration, `infra/access-policy.json`, and — for LEZ — detect-and-prompt (`exo-44b` L1–L2). The broker is what turns the declarations and prompts into live cross-app flows.
