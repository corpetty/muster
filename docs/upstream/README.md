# Upstream asks

Shareable request-for-comment documents to point external teams at. Each is written
to be sent as-is to start a conversation; nothing in them is built on the other team's
side.

- [`lez-wallet-provides-capability.md`](lez-wallet-provides-capability.md) — **nice-to-have, not a blocker.** Asks the
  **LEZ Wallet App** team (`lez_wallet_ui`) to declare a `provides` provisioning
  capability. Muster is not blocked on it: it can provision LEZ directly over `lez_core`
  (`wallet_lez_setup`) or ship its own shim. This ask is about UX + keeping keys in one
  home, for `exo-44b` L4's *preferred* path.
- [`app-to-app-intent-broker.md`](app-to-app-intent-broker.md) — **the one upstream
  dependency muster has no fallback for.** Asks the **Basecamp / logos-core** team about
  the status of app-to-app intent dispatch (`logos.request`). Muster can shim any missing
  *provider*, but only the shell can *dispatch*; without it `provides: coordinate.request`
  is inert. Blocks `exo-44b` L4 and the `coordinate.request` handler.

Related, in-repo proposal (not an external ask, but reads with the broker one):
[`../design/host-effect-policy.md`](../design/host-effect-policy.md) — the *effect
authorization* host hook (M7, `exo-002.7`): consulting Muster's room-agreement grant
before a gated core-to-core call. Distinct from intent routing; they compose.
