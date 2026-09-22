# Proposal: deterministic encoding and domain-separated hash inputs belong in logos-core

**Status:** proposal (upstream). **Motivating case:** the "schema unknown" failure state (exo-1ec.3, shipped). **Second consumer named:** driver manifests (exo-002). **Scope guard:** ADR-009 — this proposes the *encoding and hashing discipline plus the schema-id contract*, not a CDDL parser.

## The ask, in one line

logos-core should provide two primitives that every module which signs, hashes, or renders declared data needs: a **deterministic (CDE) byte encoding** and a **domain-separated hash-input record**. Muster has built and specified both; they should not be re-implemented per module, because the failure mode of getting them subtly wrong is silent and catastrophic.

## Why this is obvious rather than argued: make the failure legible

The upstream case for canonical encoding is usually argued in the abstract ("you'll want determinism eventually"). It is more convincing when a real client *cannot show data* without it, and says so out loud.

Muster now renders an activity **only from a declared, versioned schema**. When an effect declares a schema the client has no vocabulary for, the card draws a named **"⚠ Schema unknown"** failure — naming what was declared and why nothing is rendered from it — and hides the body and the Approve/Deny controls. It does **not** coerce the unknown into a payment, and it does **not** leave a blank pane. (`module/src/coordination/intents.nim` `effectSchema`; `ui/src/qml/MusterCard.qml`; test `module/tests/schema_unknown_test.nim`.)

> **[SCREENSHOT — to add from a GUI session]** The "⚠ Schema unknown" card for a proposal whose effect declares an unrecognized schema, beside a normally-rendered payment card. Capture: launch `make run`, join a room, propose an effect with an unrecognized `effect` value (e.g. `{"effect":"frobnicate"}` via the invoke composer or a seeded message), and screenshot the resulting card. Drop the image at `docs/design/img/schema-unknown-card.png` and replace this block with it. The failure is deliberately screenshot-able — that is the point of making it a named state rather than an empty view.

That failure is only legible because the bytes underneath are deterministic and the schema is declared. Remove either property and the failure becomes "the panel is blank sometimes" — which hides exactly the problem the demonstration depends on. **Legible failure is the argument.** A platform that offers canonical encoding as a shared primitive lets every module fail this way; a platform that does not, leaves each module to reinvent determinism and get the silent-coercion path wrong.

## The lever: the reference implementation already exists, and is specified

Muster carries both primitives today, each behind a typed spec with acceptance oracles, because invariant 5 (deterministic bytes on signing paths) could not be inherited from the platform — logos-core's own transport encoding is non-canonical, so determinism has to be *ours to enforce* (ADR-009). That is precisely the gap this proposal closes.

**1. The CDE encoder — `module/src/dcbor/`** (spec `contracts/specs/derived-exo-d7c.spec.json`). One contract: a value maps to exactly one byte sequence.

- `s1` — same value, any construction order → identical bytes.
- `s2` — map keys in bytewise-lexicographic order of their **encoded** bytes, never length-first (RFC 8949 §4.2.3 "CDE", not §4.2.1 core canonical).
- `s3` — integers in shortest form, no non-canonical padding.
- `s4` — no indefinite-length items, no floats: such inputs are **rejected**, never silently coerced.

Pure stdlib, no external dependency — the invariant lives entirely in code the module controls. That independence is a feature for the reference implementation and a liability at scale: it means every module ships its own copy of a primitive whose correctness is load-bearing.

**2. Domain-separated hash-input records — `module/src/hashing/hash_input.nim`** (spec `contracts/specs/derived-exo-449.spec.json`, criticality catastrophic). Every signing-path hash goes through one typed record, never ad-hoc concatenation:

```
HashInput{ domain: string, fields: seq[(string, CborValue)] }
digest = sha256( dcbor( [domain, {fields}] ) )
```

The domain tag is committed **inside** the deterministically encoded bytes (element 0 of the array), so the same content under a different domain hashes differently. Domain separation is load-bearing, not decorative — it is what makes a signature under one schema worthless under another (mirrors FS-3, and is the mechanism behind invariant 5's "no ad-hoc concatenation"). The `domain` is exactly a schema id: `"muster.event.transfer.v1"`.

## The second consumer: driver manifests need the same schema language

This is not a single-use primitive. The driver **action manifest** (exo-002 — the per-action object answering what an action does / needs / touches / discloses) is itself declared, versioned data that participants must interpret identically or the whole "everyone folds the same thing" property (invariant 4/6) breaks. A manifest is a schema; a manifest field's disclosure rows are schema'd content. The same `(deterministic encoding, domain-separated id)` discipline that lets a card decide *"do I recognize this effect's schema?"* is what lets a broker decide *"do I recognize this action's manifest schema?"* — and, when cdCDDLe ratifies, lets both resolve their schema identity from the same derivation (invariant 5b).

One schema vocabulary, two consumers today (rendering, manifests) and a broker consumer tomorrow (the host effect policy, exo-002.7). That is the shape of a platform primitive, not an app detail.

## Scope: what to promote, and what NOT to (ADR-009)

**Promote:**

1. The CDE encoder contract — the four determinism rules above — as a logos-core-provided encoder, with muster's `derived-exo-d7c` oracle as the conformance test.
2. The hash-input record shape — domain-inside-the-bytes — as the sanctioned way to hash declared data, with `derived-exo-449` as the oracle.
3. The **schema-id field convention**: every signable/declared record carries `profile` + `schema-id`, and an unrecognized id is a *named failure*, never a coercion. (This is the contract; the id vocabulary is the module's.)

**Do NOT promote (yet):**

- A CDDL parser or cdCDDLe. v0 uses hand-assigned ids (`muster.event.*.v1`); "declared, versioned schema" means membership in that id vocabulary, not a parsed CDDL root. The schema-id field is the seam cdCDDLe slots into later **without changing the encoding or hash discipline** — which is exactly why 5b is versioned-and-swappable while 5 is not. Coupling the two would make the (ready, cheap, invariant-critical) encoding primitive wait on the (unratified, expensive) schema-language one. Keep them separate; ship the encoder now.

## The null-ladder framing (see §4 of the 2026-09-02 handoff)

Today the platform's non-canonical transport encoding is the **null** on the provenance axis: data crosses the wire in *an* encoding, just not a determinable one. A shared canonical encoder is the **real** thing at the same seam — the correspondence-principle move, not a different theory. The hazard the null ladder warns about applies directly: the canonical encoder must never be a silent fallback to "whatever the transport did." An unrecognized schema refuses and says so (shipped); a non-canonical encoding on a signing path must likewise refuse, not degrade. Negotiation of "which encoding" must itself be unforgeable — which it is, because the encoding is fixed by the primitive rather than negotiated.

## Acceptance

This proposal is adopted when logos-core exposes the CDE encoder and the hash-input record, muster consumes them in place of its own `src/dcbor/` and `src/hashing/hash_input.nim` (deleting the local copies), and `derived-exo-d7c` + `derived-exo-449` grade green against the platform-provided primitives. Until then, muster keeps its reference implementation, and this document is the standing argument for why it should not have to.

## References

- Motivating code: `module/src/coordination/intents.nim` (`effectSchema`), `ui/src/qml/MusterCard.qml`, `module/tests/schema_unknown_test.nim`.
- Primitives: `module/src/dcbor/dcbor.nim`, `module/src/hashing/hash_input.nim`.
- Specs (acceptance oracles): `contracts/specs/derived-exo-d7c.spec.json` (CDE, invariant 5), `contracts/specs/derived-exo-449.spec.json` (hash-input, catastrophic).
- Invariants 5 and 5b, and ADR-009: `CLAUDE.md`.
- Second consumer: `docs/design/action-manifest.md` (exo-002); host consumer: `docs/design/host-effect-policy.md` (exo-002.7).
- Origin: `docs/03-session-handoff-2026-09-02.md` §3.
