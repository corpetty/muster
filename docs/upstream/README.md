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

Field reports (performance and findings from real use, kept current; each ends with asks):

- [`chat-module-field-report.md`](chat-module-field-report.md) — for the **chat** team: a
  `chat_module` group per multisig, its roster following the members; removal on GroupV3
  (logos-chat-module#103), one-session addresses, two-minute membership changes, every member an
  admin, no address proof.

Notes offered (not asks):

- [`atomic-swaps-htlc-on-lez-v03.md`](atomic-swaps-htlc-on-lez-v03.md) — for whoever
  moves **`logos-co/atomic-swaps-poc`** (the ETH ↔ LEZ swap) off LEZ v0.2.2: what LEZ
  v0.3's fees, included-and-billed refusals and `plan`/`apply` ABI do to its HTLC
  escrow, from muster's own v0.3 port of the LEZ multisig.

Related, in-repo proposal (not an external ask, but reads with the broker one):
[`../design/host-effect-policy.md`](../design/host-effect-policy.md) — the *effect
authorization* host hook (M7, `exo-002.7`): consulting Muster's room-agreement grant
before a gated core-to-core call. Distinct from intent routing; they compose.
