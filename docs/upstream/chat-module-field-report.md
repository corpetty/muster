# Field report: chat_module groups as a multisig's room

**To:** the chat team (`logos-co/logos-chat-module`, `logos-messaging/logos-chat`).
**From:** the Muster team (`corpetty/muster`), building RFP-005's multisig coordination client.
**Date:** 2026-11-20. **Status:** notes and asks, kept current as we go. The one change we
needed is offered as logos-chat-module#103.

## One line

Muster gives each multisig a `chat_module` group whose roster follows the multisig's members, kept
in step by one client. It works over `logos.dev`, including removal through #103. What makes it
hard:
- an address lasts one session;
- membership changes land about two minutes later;
- every member is an admin;
- nothing proves that a chat address belongs to the person who shared it.

## How to read this

- **[measured]**: we ran it: the module's own group doctest over `logos.dev`, three headless
  `logosctl` daemons, the module built from source; or Muster's test against a fake that behaves
  as we observed.
- **[from source]**: read in `logos-chat-module` / `logos-chat`, with the reference given.
- **[inferred]**: our reasoning; not run.

## The use case

An M-of-N multisig (a vault on LEZ) has members who need to talk about what they are approving.
Muster keeps the binding record: proposals, approvals and the signed log. The **deliberation** moves
to a `chat_module` group, so members use the platform's chat app.

The group must always hold exactly the multisig's current members. When the multisig adds a member,
they are invited; when it removes one, they are removed. One client acts at a time (a "steward",
the opener while they are a member), so the group sees one commit at a time. Code:
`module/src/coordination/msig_chat.nim`, `module/src/transport/chat_groups_lp.nim`; design notes in
`docs/labbook/chat-module-binding.md`.

## What we measured

- **Removal works on GroupV3** [measured]. With #103 (#92 brought up to `main`, the removal on
  logos-chat#357's `remove_group_participants`), the group doctest's removal section passes, all
  22 steps:
  - `remove_group_member` answers `success`;
  - both remaining rosters converge to two members;
  - a message sent after the removal reaches Bob and never Carol.

  `cargo test --release` in `rust-lib`: 58/58.
- **A membership change lands about two minutes after it is made** [measured], an add and a
  removal alike: an MLS commit, applied later. A UI has to show the in-between state ("being
  removed").
- **Muster's side** [measured, against a fake]: `msig_chat_test` 7/7. A forged address claim is
  dropped; the plan converges; a relaunch's new address is invited and the old removed; when the
  opener is removed, a new steward keeps the same group.

## What we hit, and what would help

### 1. `remove_group_member` is not in the module yet

0.3.0 exposes `add_group_member` only. The library has the removal (logos-chat#357, GroupV3);
osmaczko's #92 exposed it for GroupV2, before `main` moved to GroupV3 and `logosctl`.

**Ask:** review #103, which updates #92 to both. Before merging, its libchat pin needs to move to
the `main` that carries #357. Until it ships, Muster reports each removal as failed, never as
skipped, because a removed member who can still read is the failure that matters.

### 2. An address lasts one session

Each `init` is a new installation with a new address; the previous session's conversations become
read-only history [measured]. For a group that must follow a membership list:
- every member's relaunch means sharing the new address, then the steward inviting it and removing
  the old one;
- while the steward is offline, a relaunched member is out of the group.

**Ask:** a persistent installation, or an `init` that restores the previous one. The lidl says this
is being worked on; this is the change that would make groups usable for standing membership.

### 3. Every member is an admin, and a member cannot leave

Under ASTRO any member can add or remove anyone through the chat app [from source]. Muster undoes a
stray change on the steward's next pass, but neither side can prevent one. A member also cannot
remove itself (MLS), so Muster's next steward removes a departing opener.

**Ask, for discussion:** a group whose roster only one member, or an outside authority, can change.
For Muster that authority is the multisig's on-chain member list.

### 4. Nothing proves a chat address is the sharer's

The module has no way to sign with the chat account, so Muster's link from a member to their chat
address is a claim. A false claim can only get an address invited, because who belongs is still
decided by the multisig [inferred]. The binding is one-sided where every other identity link in
Muster is mutual.

**Ask:** `sign_message` on the chat account, or an address-ownership proof.

### 5. Still to measure

These are the doctest's next steps; we will add the results here:
- whether a store node can read a group's conversation id or roster;
- what the key-package service learns;
- delivery latency under the module, beyond membership changes.

## Reproduce

- **The removal doctest:** on #103's branch, `doctests/chat-module-group.test.yaml` with
  `logosctl` over `logos.dev`.
- **Muster's side:** `module/tests/run-suite.sh msig_chat`.
