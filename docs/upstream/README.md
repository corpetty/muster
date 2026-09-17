# Upstream asks

Shareable request-for-comment documents to point external teams at. Each is written
to be sent as-is to start a conversation; nothing in them is built on the other team's
side.

- [`lez-wallet-provides-capability.md`](lez-wallet-provides-capability.md) — asks the
  **LEZ Wallet App** team (`lez_wallet_ui`) to declare a `provides` provisioning
  capability, so Muster can delegate LEZ account setup/funding to it instead of
  re-implementing the wallet. Blocks Muster epic `exo-44b` L4.
- [`app-to-app-intent-broker.md`](app-to-app-intent-broker.md) — asks the **Basecamp /
  logos-core** team about the status of app-to-app intent dispatch (`logos.request`),
  and states what Muster needs as both a provider (`coordinate.request`) and a consumer
  (a wallet capability). Blocks `exo-44b` L4 and the `coordinate.request` handler.

Related, in-repo proposal (not an external ask, but reads with the broker one):
[`../design/host-effect-policy.md`](../design/host-effect-policy.md) — the *effect
authorization* host hook (M7, `exo-002.7`): consulting Muster's room-agreement grant
before a gated core-to-core call. Distinct from intent routing; they compose.
