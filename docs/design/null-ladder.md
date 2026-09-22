# The null ladder

**Status:** named + typed (exo-1ec.5). Core: `module/src/security/levels.nim`. Probe: `module/tests/probes/probe_null_ladder_refuses.nim`. Seam instance: the `ChainAdapter` seam (`module/src/wallet/`). Origin: `docs/03-session-handoff-2026-09-02.md` §4.

## The idea

The status quo is a null cipher. Build the system with the **null in place**, then replace the nulls one at a time. Each real level is the **limiting case** of the null at the *same seam* — the correspondence principle: the weaker theory is the limiting case of the stronger one, not a different theory. An unencrypted channel is an encrypted channel with a transparent key; a local transport is a delivery node with no distance; an anonymous speaker is a bound identity you have chosen not to reveal.

Two consequences shape the design:

1. **The level is a typed attribute the seam declares, read by consumers — never inferred by branching on a concrete type.** If a consumer writes `if adapter of MockChain`, the ladder has failed: adding a third shielded chain would silently miss that branch. Consumers read `securityLevel().atLeast(axis, rung)`.
2. **The null carries the same metadata envelope as the real thing.** There is no "absent" state — an axis a seam does not itself provide is `rungNull` with a mechanism string that *says so*, so a reader always reads a level, never a field's presence.

## Three axes, three nulls — they do not substitute

A level on one axis says nothing about another. A signed artifact is not a private one; an encrypted channel to an unknown peer is not an authenticated one. Keep them separate.

| Axis | Question | Null | Real |
| --- | --- | --- | --- |
| **Authentication** | who is speaking now | anonymous | bound secp256k1 identity |
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

- **Invariant 9** (anonymous drivers stay anonymous): the authentication null is a **legitimate terminal state**, not a rung to climb off. No path force-upgrades authentication; a `require(axAuthentication, rungReal)` belongs only to an already-named context. And were some path to wrongly demand it of an anonymous seam, it would *refuse* — it would never silently de-anonymize. The probe asserts this directly.
- **Invariant 10** (signing refused when an input's origin is unaccountable): the **provenance** rung *extends* that refusal into a typed level; it does not duplicate the check. `rungReal` on provenance is the signed hash-linked log + attested build; `rungNull` is unattested; requiring real of an unattested input refuses — the same refusal invariant 10 already enforces on the signing path, surfaced as a ladder rung.

## What is done, and what is next

**Done (this pass):** the pattern is named here; the level is a typed attribute on the `ChainAdapter` seam (two rungs, read not branched); the refuse-on-failed-upgrade discipline lives in the type with a pure probe proving a failed upgrade refuses rather than falls back, that the authentication null is a legitimate terminal, and that the null carries the full envelope.

**Next (tracked on exo-1ec.5):**

- **Type the remaining seams** the same way — `Transport` (confidentiality/provenance of the path), `ConversationCrypto` (the epoch layer is the confidentiality real; a null-crypto seam is the null), and the driver membership model (anonymous vs named is the authentication axis). Each is a `securityLevel()` the aggregate reads.
- **The provenance ladder as a first-class rung** wired to the invariant-10 accountability record, rather than expressed only through the log's existence.
- **UI visibility (the second DONE-WHEN half):** the active level on all three axes shown in the UI — the room's current authentication / provenance / confidentiality, each with its named mechanism, so a participant can see which nulls are still in place. This is render-bound (ADR-013 harness) and follows once the aggregate `security_levels()` surface exists.
