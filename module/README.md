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

**P0–P4 landed; P3 built — two instances converge over the live Logos fleet;
the multisig families (Phases A–D) landed 2026-09-24/25.** The signing-path core,
the intent lifecycle and driver interface, all ten invariants (92 unit tests and
55 invariant probes, green via `tests/run-suite.sh`), and the LIDL codegen that
generates the surface from the contract are all in. P4 put the whole lifecycle
through the real UI (ADR-013). P3 — transport, encryption, and multi-party
coordination — is built and tested; two `muster-ui` instances converge over the
public fleet (join → ask → admit → both at two members, ~1s cross-host receive).
The room coordinates and settles multisigs of four kinds: Safe v1.4.1 (the real
contract on anvil, at the live nonce), Bitcoin P2WSH / tapscript through PSBT
(regtest), the LEZ multisig program (on the public LEZ testnet), and FROST
(one BIP-340 signature on Bitcoin, or from an untweaked LEZ account). What remains
is the multi-party runs across two machines, and author-signed log events
(exo-f76). See [`../CLAUDE.md`](../CLAUDE.md) for the phase-by-phase detail and
[`../docs/two-instance-fleet-runbook.md`](../docs/two-instance-fleet-runbook.md)
for the operator flow.

**Landed beyond the phase plan:** a chain-agnostic wallet (EVM + mock + a real LEZ
adapter — send assets via Logos on the zone's four rails); a driver standard (registry,
conformance suite, a threshold k-of-n driver, and a generic **invoke** driver that
coordinates any Logos module action); the **action manifest** — one per-action object
answering what an action does / needs / touches / discloses / how the room agrees, with
per-instance readiness, an information-flow view, exportable provenance, and a
self-explaining card; and the **material** layer — a local holdings catalogue, offers
(requirements × my holdings with per-choice disclosure), keyed contribution, and a
per-key F-14 binding published in-room, including a room-coordinated LEZ transfer (Mode B)
where the recipient supplies their own address.

## Build

The flake pins `logos-module-builder` to a GitHub ref on the `corpetty` fork
(`c10a94c`): basecamp's coherent builder plus the `nim.packages` hook and a RUNPATH
fix, upstream-pending in
[logos-module-builder#226](https://github.com/logos-co/logos-module-builder/pull/226).
No local checkout is needed; a fresh clone builds. Build through
`cache.nix.logos.co` as a substituter — the invoking user is not a trusted nix
user, so pass it explicitly (`--extra-substituters https://cache.nix.logos.co/public
--extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=`).

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

One command runs every unit test and invariant probe, in parallel, with no host
and no chain:

```bash
tests/run-suite.sh              # everything that needs no chain
tests/run-suite.sh probes       # the invariant probes only
tests/run-suite.sh dcbor frost  # the tests whose path contains either substring
```

It fetches the Nim closure at the revs `metadata.json` pins
([`tools/nim-closure.sh`](tools/nim-closure.sh), into `~/.cache/muster/nimpkgs`) and
takes libsodium from nixpkgs. The tests that need a local chain (anvil, Bitcoin Core
regtest, a LEZ sequencer) run by name with `tests/run-suite.sh e2e <name>`; see
[`tests/README.md`](tests/README.md) for each one's chain and arguments. Regenerate
the generated surface from the contract with [`tools/regen.sh`](tools/regen.sh).

## Layout

```
src/
  api/          muster.lidl (the only outward seam) + generated surface
  dcbor/        deterministic CDE encoder (inv 5)
  hashing/      sha256 · keccak256 · domain-separated hash-input records (inv 5)
  log/          content-addressed, hash-linked log, reduce(log) (inv 4)
  intents/      lifecycle (F-3) · materialization · signing_payload · provenance · disclosure
  drivers/      driver interface (inv 6) · manifest (per-action provenance/permissions/
                disclosure) · profile (the multisig family) · conformance · safe ·
                btc_multisig · lez_multisig · frost / btc_frost / lez_frost · threshold ·
                invoke (any module action) · eip191
  crypto/       two bound identities (secp256k1 auth + Ed25519/X25519 enc),
                signed binding, keystore seam, epoch crypto (F-14/F-16)
  transport/    Transport interface + local/delivery transports (inv 8)
  coordination/ multi-party session · intent lifecycle = reduce(log) · readiness ·
                information-flow view · offers/material folds
  wallet/       chain-agnostic wallet: EVM + Bitcoin Core + mock + real LEZ adapters, verified reads
  settlement/   the settlement seam, chosen by the driver's profile: Safe · Bitcoin · LEZ multisig · LEZ FROST
  bitcoin/      Bitcoin primitives + PSBT, pinned to the BIP vectors
  frost/        FROST (BIP-445) + ChillDKG, held to every draft vector; round secrets as keystore ops
  lez/          the LEZ multisig program model + LEZ public transactions
  plugins/      plugin sandbox (inv 3)
nim-lib/        muster_gen.nim (generated) + muster_module.nim (hosted surface)
tools/          regen.sh (fetches the SDK's lidl-gen + regenerates muster_gen.nim) · nim-closure.sh
                (the pinned Nim closure) · muster_audit_verify.nim · headless-host/
tests/          unit tests · run-suite.sh (all of them, one command) · vectors/ (BIP, FROST, LEZ)
  probes/       the probe_*.nim acceptance oracles named by the derived-exo-* specs
```

## Working agreements (from [`../CLAUDE.md`](../CLAUDE.md))

- chronos only; never std asyncdispatch.
- No ad-hoc serialization where bytes get hashed or signed — deterministic dCBOR only.
- Every hash on a signing path is a domain-separated `hash-input` record.
- The conformance suite (`src/drivers/conformance.nim`) is green before driver features.
- Invariant tests are append-only. Extend, don't weaken.
- The module imports nothing from `../ui/`; it reaches other modules only through logos-core.

<!-- rot-check: current-phase=CLAUDE.md sha256=23859ca04cb56c32a0e61229dc150cf04894b7c4783a2d728f2c3d161cfe6463 -->
