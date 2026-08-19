# module/ — the real Muster core (Nim behind the `muster.lidl` contract)

Greenfield as of P0. This is the correct-from-the-ground-up build that replaces
the `demo/` speed build. It is a Nim core, chronos-only, behind the published
LIDL contract in [`src/api/muster.lidl`](src/api/muster.lidl), wrapped as
`muster-module.lgx` and hosted headless by `logoscore` (P0–P3) and by
logos-basecamp (P4+).

See `../docs/02-implementation-plan.md` (phases, ADRs) and `../CLAUDE.md`
(invariants). Acceptance is graded by the exophial specs in
`../contracts/specs/derived-exo-*.spec.json`; each names probes under
`tests/probes/probe_*.nim` that its worker writes and must make pass.

## P0 status

**Current step: the ADR-008 loading spike.** `src/api/muster.lidl` declares a
two-method surface (`health`, `echo`) whose only job is to prove a Nim-backed
module — generated over the `lidl_c.h` JSON bridge (references cloned to
`~/Github/logos-co/logos-lidl` and `~/Github/logos-co/logos-rust-sdk`) — loads,
dispatches, and answers one call in `logoscore`. Fallback (ADR-008): if the Nim
codegen backend stalls, hand-write the generated surface for this one contract;
`muster.lidl` stays normative either way.

Not yet present (arrive with their phase / spec pebble):

- `src/dcbor/` — deterministic CDE encoding (§4.5). Spec `derived-exo-d7c` (`exo-d7c`).
- `src/schemas/` — domain-separated `hash-input` records. Spec `derived-exo-449` (`exo-449`).
- `src/log/` — signed hash-linked log, reducers, convergence. Spec `derived-exo-548` (`exo-548`).
- `src/crypto/` — keys, sign/verify, envelope + epochs (P1/P3).
- `src/intents/` — effect types, lifecycle reducer, expiry (P1).
- `src/drivers/` — interface, conformance suite, stub, safe (P1/P2).
- `src/transport/` — interface, local/memory, messaging (P3).
- `src/plugins/` — runtime, manifest enforcement, first-party (P5).

## Intended layout

```
module/
  src/
    api/         muster.lidl (normative contract) + generated surface — the only outward seam
    schemas/     CDDL sources + generated Nim types + golden vectors
    dcbor/       deterministic CBOR encode/decode
    crypto/      keys, sign/verify, envelope + epochs
    log/         hash-linked signed log, causal order, reducers, persistence
    intents/     effect types, lifecycle reducer, expiry
    drivers/     interface, conformance suite, stub, safe
    transport/   interface, local/memory, messaging impl
    plugins/     runtime, manifest enforcement, first-party
  tests/
    probes/      the probe_*.nim acceptance oracles named by the derived-exo-* specs
```

## Working agreements (from `../CLAUDE.md`)

- chronos only; never std asyncdispatch.
- No ad-hoc serialization where bytes get hashed or signed — deterministic dCBOR only.
- Every hash on a signing path is a domain-separated `hash-input` record.
- The module imports nothing from `../ui/`; it reaches other modules only through logos-core.
