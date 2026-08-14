# Chat identity and conversations do not survive a restart

> **Answered 2026-08-14: confirmed, and it is a known regression.** Persistence is not implemented for λAccounts + λChat; all conversations and identities are ephemeral. It *was* implemented for pairwise conversations and regressed when the pivot to DeMLS happened, and is being held until group state is stable to cut down on forked groups and state desynchronisation. Tracking issue [`logos-messaging/libchat#28`](https://github.com/logos-messaging/libchat/issues/28); roadmap under [installation management](https://roadmap.logos.co/messaging/roadmap/milestones/2026-chat-beta#installation-management). See [§6](#6-upstream-response-2026-08-14) — none of our five hypotheses in §3 was the cause.

**Components:** `logos-co/logos-chat-module` at `dfe8ccf3` (2026-08-04), consumed as a flake input; hosted by `logos-standalone-app` (`logos-co/logos-standalone-app` `e4eb3c00`) via `logos_host_qt`
**Environment:** LEZ testnet build of the Muster demo, `delivery_preset: logos.test`, x86_64-linux
**Date measured:** 2026-08-13 / 2026-08-14
**Severity:** every launch of an instance has a new address and no conversations. A peer address shared out of band is valid for one session only.

---

## Before anything else: we are not confident we have the cause

We reported a bug to the execution-zone team a few days ago. It was withdrawn: our primary finding was our own misreading of a defaulted field, and two independent measurements agreed with each other because both read the same broken value. The lesson we took is that reproducing a result establishes that it happens and nothing at all about why.

So this report is deliberately split. **§1 is what we measured.** **§2 is what we read out of the shipped binary, which is weaker evidence than it looks.** **§3 is what we explicitly do not know**, including one inference we already retracted while writing this. We would rather walk through it with you than hand over a diagnosis, because we think it is likely we are holding something wrong — a host flag, a preset, a build feature.

---

## 1. What we measured

**An instance's chat address changes on every launch.** Three sessions of the same two peers, from the same two `--user-dir` directories, neither deleted between runs. The addresses each peer sees for the other, read from `chat_module`'s own log lines:

| session | alice sees bob as | bob sees alice as |
|---|---|---|
| 2026-08-13 09:55 | `3096fd24` | `e58fc481` |
| 2026-08-14 08:15 | `0a91a0ca` | `36681062` |
| 2026-08-14 09:23 | `b3f8b3be` | `55cbb48c` |

**A conversation does not survive a clean shutdown.** In two separate sessions we created a direct conversation, exchanged messages both ways, and closed the app normally. Both times the app exited 0, and `chat_module`'s `shutdown` was called — visible in the UI-side call log. Both times, the next launch had zero conversations and the peer had to call `create_conversation` again.

From `chat_module`'s log, the whole lifetime of one such session:

```
09:23:24 INFO: chat_module: init: state installed, joining delivery preset logos.test
09:23:25 INFO: chat_module::actions: delivery is online
09:26:58 INFO: chat_module::actions: created direct conversation d720cb262731622dc00cd41846606680
09:27:03 INFO: chat_module::actions: sent 25 bytes to d720cb262731622dc00cd41846606680
09:27:15 INFO: chat_module::actions: received 26 bytes in d720cb262731622dc00cd41846606680 from b3f8b3be
```

`init: state installed` appears on every start. Nothing is logged at shutdown.

**No database file is written, anywhere.** Searched both instance directories after several sessions, and separately searched the whole home directory and `/tmp` for any file modified during one session's window. The only files either instance ever wrote are `chat_module`'s log, the UI's log, and four JSON files belonging to *our* code. No `.db`, no `.sqlite`, no journal or WAL, in the instance directory or outside it.

**The persistence path is assigned, and it works.** The host is launched with:

```
logos_host_qt --name chat_module \
  --path .../chat_module/chat_module_plugin.so \
  --instance-persistence-path .../module_data/chat_module/99716c89de70 \
  --token-source stdin
```

and `chat_module` writes its log into exactly that directory every run. So the path exists, is assigned, and is writable — the module demonstrates this itself. `init` succeeds, so it is not hitting the "host did not assign an instance persistence path" path.

---

## 2. What the shipped binary contains

Read with `strings` on `chat_module_plugin.so`. This is weaker than source and we are treating it as such.

A persistence layer exists, with real statements over real tables:

```sql
INSERT OR REPLACE INTO conversations (local_convo_id, remote_convo_id, convo_type) VALUES (?1, ?2, ?3)
SELECT local_convo_id, remote_convo_id, convo_type FROM conversations
DELETE FROM conversations WHERE local_convo_id = ?1
SELECT name, secret_key FROM identity WHERE id = 1
INSERT OR REPLACE INTO identity (id, name, secret_key) VALUES (1, ?1, ?2)
CREATE TABLE IF NOT EXISTS ephemeral_keys ( ... )
```

plus `ratchet_state` and `skipped_keys`. There is a `chat_module::persistence::ChatSession` type in the symbol table, and the strings `instancePersistencePath` and `cannot create instance persistence path:`.

So identity is *meant* to be stored and reloaded — `SELECT name, secret_key FROM identity WHERE id = 1` has no other purpose. That is the single strongest reason we think the behaviour in §1 is a bug rather than a design choice.

The contract agrees. `chat_module.lidl` says of `init`:

> Storage lives under the instance directory the host assigns; init fails when the host assigned none.

and of `get_address`:

> The local installation address, shared out-of-band so a peer can open a conversation with this installation via create_conversation.

An address shared out of band implies an address that outlives the session.

---

## 3. What we do not know, including one thing we got wrong

**Retracted while writing this.** We initially concluded the module opens its database with `:memory:`, because that string is in the binary. It is not evidence: SQLite is statically linked here (609 `sqlite3_` symbols, amalgamation version strings present), and `:memory:` appears in every binary that bundles SQLite whatever the connection string. We are recording the retraction rather than deleting it, because it is exactly the failure mode that produced our last withdrawn report, and we would rather you see how we are reasoning.

What we genuinely cannot tell from outside:

1. **Where is the store supposed to land?** The module writes its log to the instance directory but no database. Is the database path derived differently — a subdirectory it fails to create, a separate config key, an XDG location?
2. **Is `logos-standalone-app` supplying what the module needs?** The error text mentions *"start the host with a session or config dir"*, which suggests a distinction between session and config directories that the standalone host may resolve differently from Basecamp or `logoscore`. We have only tested the standalone host.
3. **Does `delivery_preset: logos.test` select ephemeral storage?** We pass `logos.test`. If a test preset deliberately runs stateless, that would explain everything and the answer is simply "use a different preset".
4. **Is there a build feature controlling persistence?** We consume the module through the flake and have never built it ourselves.
5. **Is a per-session identity intended?** We assume not, for the reason in §2, but if it is deliberate we would like to understand how a peer address is meant to be shared.

---

## 4. Reproducer

No special tooling; two instances of any app hosting `chat_module` with separate user directories.

```bash
# two peers, each its own --user-dir
make alice        # in one terminal
make bob          # in another

# in the UI: peer A creates a conversation with peer B's address, send a message
# both directions. Then close both windows normally (do not kill them).

make alice && make bob    # relaunch from the same directories
```

Expected: the conversation is listed, and each peer's address is what it was.
Actual: no conversations, and `get_address` returns a new address for each peer.

Two details that cost us time and may matter to you:

- **Killing the app destroys state that a clean exit might have saved.** Our first attempt signalled the app *and* its `logos_host_qt` module hosts together, which takes the module away before `shutdown()` can run. That produced the same symptom for a different reason and sent us down a wrong path for an hour. The runs reported in §1 are clean exits only.
- **`chat_module`'s own log is the useful artifact**, not the UI's. It is small, and it names the conversation id, the byte counts and the peer prefix, which is what made the changing-identity table above possible.

---

## 5. What would help

In rough order of usefulness to us:

1. Confirmation of whether §1 is expected for this build, and if not, where the database is supposed to be written.
2. Whether we are holding it wrong — preset, host, or a flag we should be passing.
3. If persistence is intended to work and does not, an issue number to track, and any workaround for keeping an identity stable across restarts in the meantime.

Context on why we care: we are building a demo of a coordinated payment inside a conversation, and we want a presenter to start from a prepared state rather than rebuild it live. Our own wallet state persists fine — that is our code, four JSON files in the instance directory. The conversation is the part we cannot carry across a restart, and because the identity changes too, no amount of snapshotting on our side can fix it.

---

## 6. Upstream response (2026-08-14)

Answered by the chat team, in full effect:

> Persistence is not implemented for λAccounts + λChat; all conversations and identities are ephemeral.
>
> Reason: this was implemented for the pairwise conversations but regressed when the pivot to DeMLS occurred.
>
> Development priority: we've been putting this off until group state is stable to cut down on forked groups and state desynchronization bugs.

Tracking: [`logos-messaging/libchat#28`](https://github.com/logos-messaging/libchat/issues/28). Roadmap: [installation management](https://roadmap.logos.co/messaging/roadmap/milestones/2026-chat-beta#installation-management).

**§1 is confirmed. The cause is none of the five things §3 guessed at.** Not the `logos.test` preset, not the standalone host resolving directories differently, not a build feature, not a derived path we failed to find, and per-session identity is not intended — it is simply not implemented right now. It is a known regression with a tracking issue and a deliberate reason for its position in the queue.

**What this explains about §2.** The SQL we found in the shipped binary — the `conversations` and `identity` tables, `SELECT name, secret_key FROM identity WHERE id = 1` — is residue of the pairwise implementation that regressed. The tables are still compiled in; nothing calls them under DeMLS. Our reading that identity was *meant* to be reloaded was correct. What we could not see from outside is that it had stopped being wired up.

That is worth recording as a general caution about the method in §2: **reading capability out of a shipped binary tells you what the code once did, not what it currently does.** A dead code path and a live one look identical in a `strings` dump. It happened to point the right way here; it would not have to.

### What we changed on our side

Nothing to fix — this is upstream and deliberate. What it settles is a design question we were holding open: **a prepared demo state cannot include a conversation**, and no amount of snapshotting on our side can work around it, because the identity changes too and restored messages would name addresses that no longer exist. Our wallet state persists fine and is snapshot-restorable; the conversation is created live at demo time, every time, until `libchat#28` lands.

---

## Contact

Corey Petty — <corey@status.im>. Happy to run variants, capture more logs, or try a patched build; the two instances above are cheap to re-run and we can drive them through any sequence you want to see.
