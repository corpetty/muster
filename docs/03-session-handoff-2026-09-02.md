# Muster — Claude Code session handoff

**Date:** 2026-09-02
**Repo:** https://github.com/corpetty/muster
**Source:** call with Jacek (2026-09-02) + the current README state

This document starts a new session. It does not assume the previous conversation is
in context.

> **Incorporated into the repo 2026-09-02.** Verified against `CLAUDE.md`,
> `docs/02-implementation-plan.md`, and the live upstream state, as §0 and §9
> instruct. Corrections are marked **VERIFIED**, **CORRECTED**, or **REFUTED**
> inline. Tracked as pebble epic `exo-h02`; each section has its own pebble.


---

## 0. Read before you touch anything

In this order:

1. `CLAUDE.md` — authoritative repo layout and the ten invariants.
2. `docs/00-vision.md` — the honesty rules that bind every surface.
3. `docs/01-furps.md` — normative requirements with stable ids.
4. `docs/02-implementation-plan.md` — phases P0–P6, ADR status, accept criteria.
5. `contracts/specs/` — the twelve typed specs with acceptance oracles.
6. `module/src/drivers/` and `module/src/dcbor/` — the two seams most of this work touches.

Two standing rules from the repo:

- The demo and the specified client are different codebases. The demo violates most
  invariants. Do not cite `demo/` as how Muster works.
- Every claim on a surface must be enforced by running code. If a task cannot be
  demonstrated, mark it unbuilt rather than shipping the claim.

The task list below was written without reading `CLAUDE.md`. Check each task against the
invariants and the phase plan before you start, and correct this document where it is wrong.

---

## 1. What changed: PR #202 landed

`logos-co/logos-module-builder` PR #202 (the `nim.packages` hook and the RUNPATH fix on
the `nim-cdylib-authoring` branch) is upstream. The build no longer needs a contributor's
machine.

This is the first task and it unblocks the supply-chain work in §5.

### **CORRECTED 2026-09-02 — the premise is only one-third true; §1 is blocked**

PR #202 **is** merged (2026-08-31 → `master`, merge commit `65c3b58`), and it did land
the `codegen.nim` authoring path. But #202 carried **only** that path. Checked against
`logos-co/logos-module-builder` `origin/master` (`a53baae`, 2026-09-02) versus the local
`nim-cdylib-authoring` checkout:

| Piece | `module/metadata.json` needs it | Upstream `master` |
| --- | --- | --- |
| `codegen.nim` authoring path | yes | **present** (#202) |
| `codegen.nim.link` link flag | yes (`link: ["sodium"]`) | **present** |
| `codegen.nim.link` **RUNPATH dirs** | yes (logos-core unsets `LD_LIBRARY_PATH`) | **absent** |
| `codegen.nim.packages` (nimble deps) | yes — **11 packages**: nim-secp256k1, stint, stew, results, intops, nim-eth, nimcrypto, nim-web3, chronos … | **absent** |
| `nim.packages` per-package `submodules` | yes (nim-secp256k1) | **absent** |

`master`'s own comment still reads *"nim.packages hooks can add nimble deps **when they
arrive**"* — they have not arrived. The whole of ADR-014 (the Nimbus/Status Nim reuse:
stint, nim-eth's `verifyMptProof`, nim-web3) rides on `nim.packages`, and the RUNPATH
half is the fix `CLAUDE.md` records as *"local, uncommitted, worth upstreaming."*

**Therefore: removing the `path:` pin today does not produce a working build — it breaks
`module` outright.** The genuine precondition is upstreaming the remainder:

1. `nim.packages` + per-package `submodules` (local commits `6ae3aee`, `0f3e45b`).
2. The RUNPATH half of `nim.link` (part of `e0faeae`) **plus its uncommitted
   `cmake/LogosModule.cmake` counterpart** — 14 lines building an
   `INSTALL_RPATH "$ORIGIN:<nim.link dirs>"` suffix. This is not committed anywhere.
3. Rebase: the local branch forked long ago — `master` is **76 commits ahead** and has
   since deleted `lib/resolvePlatforms.nix` and rewritten `flake.lock`. The four Nim
   commits do not apply as-is.

**Interim unblock available now:** push the rebased branch to a fork and pin
`github:<fork>/logos-module-builder/<rev>`. That satisfies "a person who has never
touched the repo can clone it and build" today, without waiting on review.

**Also corrected — "point both at the released upstream ref" is wrong for `ui/`.**
ADR-013 pins `ui/flake.nix` to basecamp's *own* builder rev
(`4717b9a`) **deliberately**, so the generated client and QtRO view-glue ABI-match
basecamp's ui-host. The two flakes must **not** converge on one ref until basecamp
itself moves. That pin is already a `github:` ref and is not a machine-local pin —
it needs no change. The only machine-local pin in `ui/flake.nix` is
`muster_module.url = "git+file:///home/petty/Github/corpetty/muster?dir=module"`.

**Still valid as written:** removing the `muster_module` absolute path, the fresh-clone
run, the README/`module/README.md`/`module/tests/README.md` updates, and the CI job.

**Tasks**

- Remove the local-checkout pin on `logos-module-builder` in `module/flake.nix` and
  `ui/flake.nix`. Point both at the released upstream ref.
- Remove the absolute path to `muster_module` in `ui/flake.nix`. Reference it through the
  flake output.
- Run `make build` and `make run` from a clean clone in a clean nix store.
- Update `README.md`: delete the "Runs on a contributor's machine today, not yet from a
  fresh clone" note and the PR #202 caveat. Update `module/README.md` and
  `module/tests/README.md` to match.
- Add a CI job that builds from a fresh clone, so this cannot regress.

**Done when:** a person who has never touched the repo can clone it, run `make build` and
`make run`, and reach the lifecycle dashboard. CI proves it on every push.

---

## 2. Driver manifests — make drivers self-describing

**Where it came from.** Jacek's point: look at how VS Code extensions declare themselves,
then apply it to the Muster driver standard.

**The model.** A VS Code extension ships a manifest that the host reads *without loading
the extension's code*. `contributes.configuration` is a JSON Schema — type, default, enum,
description, scope — and the host builds the whole settings UI from it. The extension never
draws a settings panel. Other contribution points (commands, menus, views) declare UI
surfaces the same way, and visibility is declarative through `when` clauses over context
keys. Code loads lazily, only when a declared trigger fires.

**The gap here.** `src/drivers/` already has the harder half: a registry, a generic
interface (invariant 6), a conformance suite, and a threshold k-of-n driver that proves the
seam is generic. What a registry entry does not carry is the driver's *configuration*. So
every new driver needs hand-written UI.

**Tasks**

- Extend the registry entry with a declared config schema (CDDL, per §3) and a capability
  list. Keep the schema separate from the call interface: `muster.lidl` is the seam for
  calls, this is the seam for settings.
- Version the schema. The host must be able to refuse an entry whose schema version it
  does not understand, and say so by name.
- Make the host able to enumerate and configure a driver before loading it.
- Generate the driver settings surface from the declared schema. No per-driver QML.
- Extend the conformance suite with a second check: the driver's declared schema matches
  what it actually accepts. A driver that accepts config it did not declare fails.
- Decide config scope now — per-install, per-machine, per-identity, per-room — and put it
  in the schema. Retrofitting scope is expensive.

**Done when:** the safe driver and the threshold driver both configure through the
generated surface, and conformance fails a driver with a lying manifest.

---

## 3. dCBOR / CDDL into logos-core

**Where it came from.** Find a way to make the need for CDDL and dCBOR in logos-core
obvious, rather than argued — by way of Muster activities that cannot show data without it.

**The lever.** `module/src/dcbor/` is already the reference implementation (deterministic
CDE, invariant 5), paired with the domain-separated hash-input records. The upstream
argument is easier if the failure is legible instead of silent.

**Tasks**

- Rule: an activity renders only from a declared, versioned schema.
- When no matching schema resolves, show a named failure state — "schema unknown", plus
  the module name and version. No blank panes, no empty lists. A silent empty view hides
  the problem the demonstration depends on.
- Write the upstream proposal: promote the CDE encoder and the hash-input record
  discipline to logos-core, with the rendering failure as the motivating case.
- Note the second consumer while you write it: driver manifests (§2) need the same schema
  language.

**Done when:** a stale or missing schema produces a named, screenshot-able failure, and
the proposal exists in `docs/` with that screenshot in it.

---

## 4. The null ladder — type it, do not branch on it

**Where it came from.** The status quo is a null cipher. Build the system with the null in
place, then replace the nulls one at a time. An unencrypted channel is an encrypted
channel with a transparent key. The analogy is the correspondence principle: the weaker
theory is the limiting case of the stronger one, not a different theory.

**It is already in the code, unnamed.** The `ChainAdapter` seam holds an EVM adapter and a
mock shielded adapter — the transparent chain is the null case and the shielded one
replaces it at the same seam. The Transport seam holds the local transport and the real
delivery module the same way.

**Three axes, three nulls. Keep them separate; they do not substitute.**

| Axis | Question | Null | Real |
| --- | --- | --- | --- |
| Authentication | who is speaking now | anonymous | bound secp256k1 identity |
| Provenance | where this came from, what path it took | unattested | signed hash-linked log, attested build |
| Confidentiality | who can read it | plaintext / transparent chain | ECIES epochs, shielded adapter |

A signed artifact is not a private one. An encrypted channel to an unknown peer is not an
authenticated one.

**Tasks**

- Name the pattern in `docs/` and point at both existing instances.
- Make the level a typed attribute on the seam, not a branch in the code path. The null
  must carry the same metadata envelope as the real thing.
- Build the provenance ladder, which does not exist yet.
- **Hazard to design against.** TLS shipped NULL and export-grade cipher suites, and the
  result was downgrade attacks — FREAK, Logjam. Negotiation itself must be authenticated.
  The null must be an explicit opt-in, displayed, and never a silent fallback when the
  real option fails. The honesty rules already demand this at the surface; put it in the
  type as well.

**Done when:** a probe shows that a failed upgrade refuses rather than falls back, and the
active level on all three axes is visible in the UI.

---

## 5. Provenance and the supply chain

**Where it came from.** The curl project as the model, and a standard for establishing a
supply chain for components.

**What curl actually does.** Not a product — a process. Signed commits to prove
provenance. Every release tarball signed, so a consumer can confirm the files were not
altered after they were produced. The git repository as the authoritative and auditable
source of truth, held there by review requirements, a banned-function list, a function
complexity ceiling, and a ban on binary blobs and most base64 content, both of which can
hide a payload. A written policy on what the project expects from dependencies. And the
verification steps documented, so a consumer can run the check.

**Split the work in two.**

*Runtime provenance* — `src/intents/provenance` and the signed hash-linked log. This
exists. It answers: where did this intent come from and what path did it take.

*Build provenance* — does not exist. §1 is the precondition: while the build depends on a
contributor's machine, there is no chain of custody from source to artifact to claim.

**Standards to evaluate**

- **in-toto** — the one with an actual language. You write a layout declaring the expected
  steps in the chain and who is authorized to perform each one, then verify collected link
  metadata against it. Closest match to what Jacek described.
- **SLSA** — build track and source track, four levels. The vocabulary and the level
  targets.
- **Sigstore / Rekor** — signing plus an append-only transparency log.
- **SPDX or CycloneDX** — component inventory format.

**Tasks**

- After §1, produce a reproducible build from a fresh clone. Nix does most of this once
  the pins are gone.
- Sign releases. Document the verification steps so a consumer can run them.
- Draft an in-toto layout for the Muster release chain and see what it costs.
- Write the dependency policy — what Muster expects from what it pulls in.
- Note the overlap worth writing up: Logos already has a transparency log and a storage
  layer, so attestations are a native payload rather than a third-party service.

**Done when:** a release ships with a signature and documented verification, and the
layout draft exists.

---

## 6. Source-to-sink pipeline

**Where it came from.** JACK audio as the reference for a source-to-sink pipeline. Earlier
versions of this exist for Logos in `logos-legos` and the v2 `logos-workflow-*` modules,
and both need updating against the current logos-core architecture.

**Why JACK is the right reference.** A connection is legal only when the port types match,
and format and rate are settled at connect time — not discovered at runtime.

That is the same check as §3: a link is valid only if the source's output schema satisfies
the sink's input schema. And the null ladder from §4 becomes port attributes negotiated at
the same moment: cipher, credential, and provenance level are all settled when the ports
connect.

**Tasks**

- Pull `logos-legos` and the `logos-workflow-*` modules. List what breaks against the
  current logos-core module interface.
- Replace ad-hoc wiring with typed port negotiation against the declared schemas.
- Carry the three levels from §4 as port attributes.

**Done when:** the breakage list exists and a design note connects port typing to the
CDDL schema work.

---

## 7. Basecamp: spec versus implementation

**Where it came from.** It should be possible to rebuild `logos-basecamp` from its specs.
The open question is how much was lost in translation on the way to what is built now.

**Task.** Diff the logos-core module interface spec (logos-core-poc2, CDDL/dCBOR) against
what `logos-basecamp` actually implements. Produce two lists: behavior in the spec that is
not implemented, and behavior implemented that the spec does not describe. The second list
is the translation loss.

This one is independent of the rest and can run in parallel.

---

## 8. Suggested order

1. §1 — fresh-clone build. Unblocks §5 and removes the largest caveat in the README.
2. §3 — schema failure state. Cheap, and it is the demonstration everything else cites.
3. §2 — driver manifests. Depends on the schema language from §3.
4. §4 — name and type the null ladder. Mostly documentation plus a probe.
5. §5 — build provenance. Needs §1 done.
6. §6 — pipeline. Largest, least urgent.
7. §7 — basecamp diff. Parallel, any time.

---

## 9. Open items

- Config scope for driver settings — decide before writing the schema (§2).
- Whether the driver manifest schema and the wire schema share one CDDL dialect or two.
- Which SLSA level to target, and whether IFT infrastructure can meet it.
- The cross-host Safe-transaction half of P3 still needs owner-seeded peers. Confirm
  whether it precedes or follows this list.
- Verify every task above against `CLAUDE.md` and `docs/02-implementation-plan.md`. This
  document was written from the README and meeting notes, not from the specs.
