# module/ — the real Muster core (Nim behind the `muster.lidl` contract)

The correct-from-the-ground-up build that replaces the `demo/` speed build. A
Nim core, chronos-only, behind the published LIDL contract in
[`src/api/muster.lidl`](src/api/muster.lidl), wrapped as `muster-module.lgx` and
hosted headless by `logoscore` (P0–P3) and by logos-basecamp (P4+).

See [`../docs/02-implementation-plan.md`](../docs/02-implementation-plan.md)
(phases, ADRs) and [`../CLAUDE.md`](../CLAUDE.md) (the invariants, and the
authoritative current-phase status). Acceptance is graded by the exophial specs
in `../contracts/specs/derived-exo-*.spec.json`; each names probes under
`tests/probes/probe_*.nim` that its worker writes and must make pass.

## Status

**P0–P2 and P4 landed; P3 built — two instances now converge over the live
Logos fleet (membership handshake end to end).** The signing-path core, the
intent lifecycle and driver interface, all ten invariants (the probe suite
under `tests/probes/` is green), the Safe driver (real EIP-712 `safeTxHash`,
secp256k1 owner verification, on-chain `execTransaction` against the anvil
`MiniSafe`), and the LIDL codegen that generates the surface from the contract
are all in. P4 put the whole lifecycle through the real UI in logos-basecamp
(ADR-013). P3 — transport, encryption, and multi-party coordination — is built
and tested; two `muster-ui` instances converge over the public fleet (join →
ask → admit → both at two members). What remains is the cross-host
Safe-transaction half (needs owner-seeded peers) and latency polish (~8s
store-catchup poll). See [`../CLAUDE.md`](../CLAUDE.md) for the phase-by-phase
detail and [`../docs/two-instance-fleet-runbook.md`](../docs/two-instance-fleet-runbook.md)
for the operator flow.

## Build

The flake pins `logos-module-builder` as a local path-input on its
`nim-cdylib-authoring` branch (not upstream yet, PR #202), so a fresh clone needs
that checkout beside this repo. Build through `cache.nix.logos.co` as a
substituter — the invoking user is not a trusted nix user, so pass it
explicitly.

```bash
nix build .#lgx            # muster-module.lgx (dev, keyed linux-amd64-dev)
nix build .#lgx-portable   # portable variant (logoscore's default resolver wants this one)
```

Load it headless and answer one call:

```bash
lgpm install --file ./result*/*.lgx --modules-dir <dir>
logoscore -m <dir> -l muster_module -c 'muster_module.health()' --quit-on-finish
```

## Test

The pure-Nim invariant probes need no host:

```bash
nim r -d:release tests/probes/probe_materialization_mismatch_refused.nim
```

The P2 crypto/Safe tests link `libsecp256k1` and the full P3 stack links
`libsodium` too — see [`tests/README.md`](tests/README.md) for the link flags
and the anvil-backed `safe_anvil_e2e`. Regenerate the generated surface from the
contract with [`tools/regen.sh`](tools/regen.sh).

## Layout

```
src/
  api/          muster.lidl (the only outward seam) + generated surface
  dcbor/        deterministic CDE encoder (inv 5)
  hashing/      sha256 · keccak256 · domain-separated hash-input records (inv 5)
  log/          signed hash-linked log, reduce(log) (inv 4)
  intents/      lifecycle (F-3) · materialization · signing_payload · provenance
  drivers/      driver interface (inv 6) · safe · threshold · conformance suite
  crypto/       two bound identities (secp256k1 auth + Ed25519/X25519 enc),
                signed binding, keystore seam, epoch crypto (F-14/F-16)
  transport/    Transport interface + local/delivery transports (inv 8)
  coordination/ multi-party session · intent lifecycle = reduce(log)
  wallet/       chain-agnostic wallet: EVM + mock shielded adapters, verified reads
  plugins/      plugin sandbox (inv 3)
nim-lib/        muster_gen.nim (generated) + muster_module.nim (hosted surface)
tools/          lidl_gen.nim (Nim LIDL codegen) · regen.sh
tests/          lifecycle/safe/crypto/transport/coordination tests
  probes/       the probe_*.nim acceptance oracles named by the derived-exo-* specs
```

## Working agreements (from [`../CLAUDE.md`](../CLAUDE.md))

- chronos only; never std asyncdispatch.
- No ad-hoc serialization where bytes get hashed or signed — deterministic dCBOR only.
- Every hash on a signing path is a domain-separated `hash-input` record.
- The conformance suite (`src/drivers/conformance.nim`) is green before driver features.
- Invariant tests are append-only. Extend, don't weaken.
- The module imports nothing from `../ui/`; it reaches other modules only through logos-core.

<!-- rot-check: current-phase=CLAUDE.md sha256=3adc867b16fbd8a9f3d021ecd7e317e8f21ec27c144be71a909b405a2fd20343 -->
