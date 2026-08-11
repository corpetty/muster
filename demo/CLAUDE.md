# demo/ — the speed build

**Read `README.md` in this directory first.** It states, invariant by invariant, how this code deliberately departs from the ones in the repo root, and why that is the point rather than an oversight.

The short version: this is a one-week prototype built to back a campaign write-up, composing shipping Logos modules rather than implementing the Muster specification. It has no signed log, no effect/materialization split, no replay binding, and no conformance suite. Do not take a pattern from here into `module/` or `ui/`.

## What lives here

```
muster-ui/     fork of logos-co/logos-chat-ui v0.2.2 (QML + QtRO C++ backend)
  src/         ChatBackend (upstream) + ChatBackendWallet + ChatBackendJourney (ours)
  src/qml/     ChatUi module; ours are MusterCard, WalletCard, SendDialog,
               VisibilityPanel, VisibilityClaims, JobStrip
.run/          per-peer state (gitignored) — one directory is one identity
.tools/        local downloads (gitignored)
```

Upstream modules consumed as flake inputs, not vendored: `chat_module` (e2e chat),
`delivery_module` (transport), `lez_core` (execution-zone wallet).

## Rules that are not obvious

- **The build cannot see QML errors.** `nix build` passes while the app fails to load, and the failure surfaces as "Failed to load UI plugin" with the reason in no log. Run `qmllint` (invocation in `../docs/labbook/qml-errors-are-invisible-to-nix-build.md`) *and* launch the app before believing a QML change works. A green build proves nothing here.
- **`lez_core` reports failure by returning an empty string or a non-zero int, not through `CallError`.** Check both on every call. See `../docs/labbook/lez-core-error-conventions.md`.
- **Anything that proves must use the generated `*Async` variant.** The sync wrapper hardcodes a 20s timeout; a shielded transfer takes ~7 minutes, and an expired call discards a result the zone goes on to produce.
- **`save()` after every mutating zone call.** The wallet-ffi is in-memory; without it the next `open()` has forgotten the transfer.
- **A peer's wallet lives inside its chat instance directory.** Two peers sharing one directory would share one identity, which would make any recording a lie.
- **Claims shown in the UI are data** (`VisibilityClaims.qml`), carrying evidence and, for a gap, the fix and its honest status. A claim without evidence must be visible as a hole. The honesty rules in `../docs/00-vision.md` bind this directory even though the invariants do not.

## Testing posture

There are no tests here, deliberately — this is a prototype whose purpose is to be run and written about, and it is the refactor target for spec-first work rather than a codebase to maintain. Commits touching only this directory carry `TDD-Exempt:` with that reason. Anything promoted out of here into `module/` or `ui/` arrives through `discuss-issue` with acceptance oracles, not by being copied.
