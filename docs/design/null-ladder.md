# The null ladder

**Status:** named + typed (exo-1ec.5). Core: `module/src/security/levels.nim`. Probe: `module/tests/probes/probe_null_ladder_refuses.nim`. Seam instance: the `ChainAdapter` seam (`module/src/wallet/`). Origin: `docs/03-session-handoff-2026-09-02.md` §4.

## The idea

The status quo is a null cipher. Build the system with the **null in place**, then replace the nulls one at a time. Each real level is the **limiting case** of the null at the *same seam* — the correspondence principle: the weaker theory is the limiting case of the stronger one, not a different theory. An unencrypted channel is an encrypted channel with a transparent key; a local transport is a delivery node with no distance; an unauthenticated speaker is a bound identity whose binding has not been checked.

Two consequences shape the design:

1. **The level is a typed attribute the seam declares, read by consumers — never inferred by branching on a concrete type.** If a consumer writes `if adapter of MockChain`, the ladder has failed: adding a third shielded chain would silently miss that branch. Consumers read `securityLevel().atLeast(axis, rung)`.
2. **The null carries the same metadata envelope as the real thing.** There is no "absent" state — an axis a seam does not itself provide is `rungNull` with a mechanism string that *says so*, so a reader always reads a level, never a field's presence.

## Three axes, three nulls — they do not substitute

A level on one axis says nothing about another. A signed artifact is not a private one; an encrypted channel to an unknown peer is not an authenticated one. Keep them separate.

| Axis | Question | Null | Real |
| --- | --- | --- | --- |
| **Authentication** | who is speaking now | unauthenticated (no driver active) | bound secp256k1 identity |
| **Provenance** | where this came from, what path it took | unattested | signed hash-linked log, attested build |
| **Confidentiality** | who can read it | plaintext / transparent chain | ECIES epochs, shielded adapter |

## Already in the code, now named

The pattern was already present in two seams before it had a name:

- **`ChainAdapter`** — the EVM/Safe adapter is the transparent **confidentiality null**; the mock shielded adapter and the real LEZ adapter are the **real** level at the *same* seam. This is now typed: `ChainAdapter.securityLevel()` declares the rung, and the shielded adapters override confidentiality to `rungReal` (`module/src/wallet/{adapter,mock_chain,lez_adapter}.nim`). A consumer reads `atLeast(axConfidentiality, rungReal)` — it never pattern-matches the adapter type.
- **`Transport`** — `LocalTransport` is the null (in-process, no distance); `delivery_module` is the real network path. The same shape: a null impl and a real impl behind one interface.

Both adapters honestly declare `rungNull` on the axes a chain seam does **not** govern (it does not authenticate the room member; it reads from untrusted RPC, invariant 8) — a seam never claims a level it does not provide.

## The hazard this is designed against

TLS shipped NULL and export-grade cipher suites, and the result was **downgrade attacks** — FREAK, Logjam. The lesson is that negotiation itself must be authenticated, and the null must never be a *silent fallback* when the real option fails. The honesty rules already demand this at the surface (`docs/00-vision.md`); the null ladder puts it in the **type**:

- `require(axis, rung)` **refuses** — it raises `DowngradeRefused` when the seam cannot meet the rung, and there is deliberately **no `orNull` variant**. A consumer that needs the real level and cannot get it fails loudly; it does not proceed at the null.
- The rungs are **ordered**, and consumers compare with `>=`, never `== rungReal`, so a richer level can be inserted later without touching call sites.

## Invariant guards

- **Authentication is real whenever a driver is active.** Every driver binds identity (ADR-015 retired anonymous membership), so the authentication null only describes a seam with no driver behind it — it is not a terminal a room settles at. A `require(axAuthentication, rungReal)` against such a seam *refuses*; it never proceeds at the null. Privacy toward everyone outside the room is carried by the confidentiality axis, not by withholding identity inside it.
- **Invariant 10** (signing refused when an input's origin is unaccountable): the **provenance** rung *extends* that refusal into a typed level; it does not duplicate the check. `rungReal` on provenance is the signed hash-linked log + attested build; `rungNull` is unattested; requiring real of an unattested input refuses — the same refusal invariant 10 already enforces on the signing path, surfaced as a ladder rung.

## What is done, and what is next

**Done:**

- The pattern is named here, and the refuse-on-failed-upgrade discipline lives in the type: `require` raises `DowngradeRefused` with no `orNull` fallback, proven by the pure probe (a failed upgrade refuses; the null carries the full envelope; rungs are ordered).
- **All four seams that map to the three axes are typed**, each declaring a `securityLevel()` a consumer reads (never branching on the concrete type):
  - `ChainAdapter` → **confidentiality** (transparent EVM = null, shielded mock/LEZ = real).
  - `ConversationCrypto` → **confidentiality** of room data (`EpochCrypto` = real, ECIES/F-16; base = null).
  - the driver → **authentication** (`securityLevel(DriverDescriptor)`: every driver binds identity, so real whenever a driver is active).
  - `Transport` → **none**, honestly: it carries opaque bytes, so all axes are null with mechanisms naming where the real level lives (the `DeliveryTransport` override names the store-node metadata exposure, FS-9).
- **`combine()`** composes the active room envelope — per axis, the strongest rung any active seam provides — the data source for the UI's "active level on all three axes".

**Next (tracked on exo-1ec.5):**

- **UI visibility (the second DONE-WHEN half):** surface `combine()` over the room's live seams as a module method and render the three axes in the UI, each with its named mechanism, so a participant can see which nulls are still in place. Render-bound (ADR-013 harness).
- **The provenance ladder as a first-class rung** wired directly to the invariant-10 accountability record, rather than stood in by the signed log's existence.
