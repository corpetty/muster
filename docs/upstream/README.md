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

- [`logos-module-builder-field-report.md`](logos-module-builder-field-report.md) — for the
  **module builder** team: a Rust module whose crate has a path dependency outside its package
  needs a staged source (import-from-derivation) and trips Cargo's implicit workspace membership;
  and why the v0.4 prover became its own module, `lez_msig_v04_module`, so a host holds both lines.
- [`lez-v04-field-report.md`](lez-v04-field-report.md) — for the **LEZ** team: lez-msig on
  0.4.0-rc3 (devnet and local): what each step meters and costs, refusals burning the whole gas
  limit with no estimate RPC, a PDA unable to pay its own fee, version detection, deploy resume,
  and risc0's recursion circuit answering 403 (a hosted copy would unblock every program author).
- [`spel-field-report.md`](spel-field-report.md) — for the **SPEL** maintainers: lez-msig's IDL v2
  through `refactor/lez-v0.4.x`; `spel encode` silently drops a vector's elements after the first
  (a signer would approve what the bytes do not say), refuses vectors in JSON-valued fields, a
  struct message the program decodes cannot be described, and state types are found in the crate only.
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
