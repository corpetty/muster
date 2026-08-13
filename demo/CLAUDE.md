# demo/ — the speed build

**Read `README.md` in this directory first.** It states, invariant by invariant, how this code deliberately departs from the ones in the repo root, and why that is the point rather than an oversight.

The short version: this is a one-week prototype built to back a campaign write-up, composing shipping Logos modules rather than implementing the Muster specification. It has no signed log, no effect/materialization split, no replay binding, and no conformance suite. Do not take a pattern from here into `module/` or `ui/`.

## What lives here

```
muster-ui/     fork of logos-co/logos-chat-ui v0.2.2 (QML + QtRO C++ backend)
  src/         ChatBackend (upstream) + ChatBackendWallet + ChatBackendAssets
               + ChatBackendJourney + ChatBackendIntent (ours)
  src/qml/     ChatUi module; ours are MusterCard, WalletCard, RailPicker,
               ShareAddressDialog, SendDialog, ProposeDialog, PinnedIntent,
               VisibilityPanel, VisibilityClaims, JobStrip
.run/          per-peer state (gitignored) — one directory is one identity
.tools/        local downloads (gitignored)
```

Upstream modules consumed as flake inputs, not vendored: `chat_module` (e2e chat),
`delivery_module` (transport), `lez_core` (execution-zone wallet).

## Rules that are not obvious

- **Assets and rails live in one table, and adding one means adding a claim.** `ChatBackendAssets.cpp` holds two catalogues — `Holding` (a balance: where it is, how to read it, what address a peer pays it at) and `Rail` (a way to pay: which holding it spends, what form of address it needs, and what the chain learns). Every surface downstream reads those rows; none of them branches on a particular asset. **If adding an entry made you edit a view, the entry is not carrying enough** — put the missing fact in `Assets.h` rather than a branch in the view. A `Rail` also names a `claimId` in `VisibilityClaims.qml`, and `sendableRailById` refuses one that names nothing, at the only place value moves. That is the honesty rule made structural: a rail with nowhere to say what it leaks cannot be paid with, whoever forgot.
- **A card names the asset or rail it is about, and `MusterMessage::kVersion` is 2 because of it.** A v1 reader has no field to read that from and would assume v1's single rail — labelling a public account "shielded" and a public payment "not disclosed". Both are the exact lie this app exists not to tell, which is why it is a version bump and not an added field. Reading a v1 card is still safe: every default a missing field falls back to is what v1 meant.
- **The build cannot see QML errors.** `nix build` passes while the app fails to load, and the failure surfaces as "Failed to load UI plugin" with the reason in no log. Run `qmllint` (invocation in `../docs/labbook/qml-errors-are-invisible-to-nix-build.md`) *and* launch the app before believing a QML change works. A green build proves nothing here.
- **Never register a private account, and never build a receiving wallet by import.** Two upstream landmines, both silent, both permanent. `register_private_account` *initializes* the account, and the zone's initialization nullifier is a hash of the account id alone — so an id can be foreign-initialized exactly once, ever, and registering your own makes it permanently uncreditable by anyone else. Registration is not part of receiving: the sender's transfer creates the account. Separately, a wallet built with `wallet_ffi_import_private_account` panics on sync when a payment arrives at an identifier not in the import, *before* the synced-block marker is written — so the block replays and every later sync dies identically. Mint with `create_new`, or restore from a mnemonic; both derive into the key tree, which handles new identifiers. We shipped the first of these for two days on a misdiagnosis. See `GAPS.md` §4b.
- **A shielded balance is a scan, not a lookup, and that is not a workaround.** What a peer publishes is a key node `(npk, vpk)`; the sender picks the identifier, so every payment mints a fresh account under it. `readPrivateBalance` sums over `list_accounts` and `spendFromAccount` picks the largest note because that is what a correct client does. Do not "simplify" either back to reading one account id.
- **`lez_core` reports failure by returning an empty string or a non-zero int, not through `CallError`.** Check both on every call. See `../docs/labbook/lez-core-error-conventions.md`.
- **Anything that proves must use the generated `*Async` variant.** The sync wrapper hardcodes a 20s timeout; a shielded transfer takes ~7 minutes, and an expired call discards a result the zone goes on to produce.
- **`save()` after every mutating zone call.** The wallet-ffi is in-memory; without it the next `open()` has forgotten the transfer.
- **A transfer the zone accepted is not yet a balance you can read.** The block carrying it may not exist yet, and `syncToTip` does nothing when the height has not moved — so a read taken right after a successful transfer returns the balances from *before* it, and leaves them on screen. That is not a cosmetic lag: an unchanged balance beside a posted receipt is indistinguishable from the payment having failed. Measured 2026-08-12: a 7-minute shield completed and the wallet still showed `150 public / 0 private` until a manual Refresh. Every value-moving path therefore ends in `settleAfterTransfer`, which polls sync-and-re-read until this wallet's own view actually moves. The faucet path already knew this (`waitForPublicFunds`); the lesson is that it is true of *every* rail, not just the faucet.
- **A peer's wallet lives inside its chat instance directory.** Two peers sharing one directory would share one identity, which would make any recording a lie.
- **Claims shown in the UI are data** (`VisibilityClaims.qml`), carrying evidence and, for a gap, the fix and its honest status. A claim without evidence must be visible as a hole. The honesty rules in `../docs/00-vision.md` bind this directory even though the invariants do not.
- **Conversation state is a fold, never a second record.** The journey, the home surface and the proposals are all `reduce(messages)` over `get_messages`, so they cannot drift, survive a restart for nothing, and are correct for a conversation this instance did not start. Two passes where order matters — store-node catchup delivers an approval before its proposal often enough to matter.
- **An approval is authenticated, not authorizing.** `chat_module` binds every message to its author, so the count on a proposal card is real and unforgeable *in the room*. The zone checks none of it: the paying account is single-key. Any wording added near a threshold has to stay inside the `authorization` claim in `VisibilityClaims.qml`, which says exactly this. Filled slots beside a shielded payment imply chain enforcement if left to speak for themselves.

## Testing posture

There are no tests here, deliberately — this is a prototype whose purpose is to be run and written about, and it is the refactor target for spec-first work rather than a codebase to maintain. Commits touching only this directory carry `TDD-Exempt:` with that reason. Anything promoted out of here into `module/` or `ui/` arrives through `discuss-issue` with acceptance oracles, not by being copied.
