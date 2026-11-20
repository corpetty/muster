# The chat module as a lez-msig's room: the limited binding (exo-7a5)

*2026-11-20. RFP-005 S.2, roadmap M3 (moved up from M6 to de-risk, Franck 2026-11-20).*

## What is built

Muster's room stays the coordination layer: proposals, approvals and the signed log. What moves
to `chat_module` is the multisig's **deliberation**. Muster provisions a `chat_module` group for
each lez-msig and keeps its roster equal to the members the program holds; members read and write
it in the platform's chat app.

- `transport/chat_groups.nim`: the seam (`ChatGroups`) and a fake that behaves as the module does.
- `transport/chat_groups_lp.nim`: `chat_module` over lp_*.
- `coordination/msig_chat.nim`: the room's half, pure:
  - `member/<who>/chat` is a member's chat address for this session, author-signed;
  - `lmsig/<ck>/chat` is the group's conversation id, announced by the client that created it;
  - `chatPlan` is what this client does now. One client acts (the steward: the opener while a
    member, else the lowest member), so the group sees one commit at a time.
- `muster_module`'s intents tick (`msigChatTick`, every 10 s): share this session's address, then
  carry out the steward's plan. `lez_msig_state` reports the group (`chat`).
- `module/tests/msig_chat_test.nim`, 7/7:
  - an address claimed under another member's name is dropped;
  - the steward creates, announces and invites;
  - the plan converges;
  - a relaunch's new address is invited and the stale one removed;
  - a removed member is removed;
  - a member who shared no address is reported;
  - when the opener is removed, a new steward keeps the same group.

It only calls `chat_module` when the host's registry reports it ready (`chat_module` is an
optional dependency, `>=0.3.0`).

## Gaps, each an ask for the chat team

1. **`remove_group_member` is not in the module.** The library has it as
   `remove_group_participants` (logos-chat PR #357), and the module (0.3.0) exposes only
   `add_group_member`. osmaczko's draft logos-chat-module#92 exposed it for GroupV2.
   logos-chat-module#103 updates #92: it merges `main` (GroupV3, `logosctl` doctests) and moves
   the removal onto #357's GroupV3 path. The module's 58 unit tests pass, and the group doctest
   gains a removal step (below). Until it ships, Muster's removals are reported as failed, never
   skipped.
2. **A chat address lives for one session.** Each `init` is a new installation with a new
   address, and the previous session's conversations are read-only history.
   - So a member's membership in the group has to be renewed every launch: they share the new
     address, and the steward invites it and removes the old one.
   - While the steward is offline, a relaunched member is out of the group.
   - Ask: a persistent installation, or an `init` that restores the previous one ("being worked
     on", per the lidl).
3. **Membership changes apply about two minutes later.** A removal is no faster than an add. The
   card should say "being removed from the chat" for that window.
4. **A member cannot remove itself (MLS).** The steward covers this: when the opener is removed,
   the next steward removes them.
5. **Every member is an admin (ASTRO).** Anyone in the group can add or remove anyone through the
   chat app. Muster's steward re-converges the roster to the program's members on its next tick,
   so a stray add is undone. Neither side can stop it.
6. **The binding is a claim.** Nothing proves that a chat address belongs to the room member who
   shared it: the module has no way to sign with the chat account.
   - A false claim can only get that address invited. Who belongs is still decided by the program's
     members, each through their own claim.
   - Ask: a `sign_message` on the chat account, or an address proof, so the binding can be mutual
     like the approval key's (`lmsig/<ck>/key/<who>`).
7. **Still to measure on the wire:**
   - whether the group's conversation id or membership is readable to a store node (Privacy-2);
   - what the key-package service learns.

   These are the doctest's next steps.

## The removal doctest

The module's `doctests/chat-module-group.test.yaml` drives three headless `logosctl` daemons over
the live `logos.dev` fleet. The patch appends a step to it: Alice removes Carol, Alice sends, Bob
reads the message and Carol does not.
