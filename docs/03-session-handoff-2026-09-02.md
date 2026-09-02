
---

## 10. Tracking (added on incorporation, 2026-09-02)

Epic `exo-1ec`. Order below is §8's, amended: §1 is no longer first because it is
blocked — the builder gap `exo-865` is.

| Pebble | Section | Priority | State |
| --- | --- | --- | --- |
| `exo-865` | **precondition** — builder gap: `nim.packages` + `nim.link` RUNPATH not upstream | P0 | blocks `exo-414` |
| `exo-414` | §1 fresh-clone build | P1 | blocked by `exo-865` |
| `exo-340` | §3 schema-unknown failure state + upstream proposal | P1 | ready |
| `exo-ec1` | §2 driver manifests | P2 | blocked by `exo-340` |
| `exo-6d4` | §4 null ladder | P2 | ready |
| `exo-968` | §5 build provenance | P2 | blocked by `exo-414` |
| `exo-330` | §6 source-to-sink pipeline | P3 | blocked by `exo-340` |
| `exo-9ff` | §7 basecamp diff | P3 | ready, parallel |

### Corrections applied on incorporation

- **§1 premise** — corrected in place. PR #202 landed only the `codegen.nim` path;
  `nim.packages`, per-package `submodules`, and the `nim.link` RUNPATH half are all
  still unmerged, and one of them (the `cmake/LogosModule.cmake` rpath suffix) is not
  committed anywhere. See the CORRECTED block in §1.
- **§1 "point both at the released upstream ref"** — wrong for `ui/`. ADR-013 pins it to
  basecamp's own builder rev on purpose; that pin is already a `github:` ref and stays.
- **§8 order** — §1 demoted below §3 until `exo-865` clears.

### Checked and left as written

- §0's reading order, the demo/spec-client separation, and the honesty rule all match
  `CLAUDE.md` and `docs/00-vision.md`.
- §2's account of `module/src/drivers/` (registry, generic interface, conformance suite,
  threshold k-of-n driver) is accurate.
- §4's claim that the pattern already exists unnamed at the `ChainAdapter` and `Transport`
  seams is accurate.
- §5's split — runtime provenance exists (invariant 10, `derived-exo-3a1`), build
  provenance does not — is accurate.

### Scope notes added

- **§3** — `module/src/schemas/` does not exist; there is no CDDL parser and no cdCDDLe in
  v0 (ADR-009). "Declared, versioned schema" here means the v0 hand-assigned id vocabulary
  (`muster.event.*.v1`), not a parsed CDDL root, or the task silently grows a parser.
- **§4** — invariant 9 makes the *authentication* null a legitimate terminal state for an
  anonymous driver, not a rung to be climbed off. Invariant 10 already refuses signing on
  unaccountable input; the provenance rung extends it rather than duplicating it.
- **§7** — `logos-core-poc2` is read, not copied, and its tests are not spec;
  `logos-lips draft/logos-core-module-specs` is unmerged and tracked, not targeted. Say
  which artifact is being treated as normative and why.

### §9 open items — one answered

- *"The cross-host Safe-transaction half of P3 still needs owner-seeded peers. Confirm
  whether it precedes or follows this list."* — It is **independent**. It needs the two
  runner peers seeded with anvil Safe owner keys plus the R-4/R-6 kill-mid-collection run;
  none of §1–§7 touches that path. It does not block, and is not blocked by, this list.
