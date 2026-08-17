# What the software connects to, step by step — a private→private transfer

Reference for the demo walkthrough article. Every claim here is read off the
`demo/muster-ui` speed build (the composed-upstream-modules build, not the
specified client), with file:line so it stays checkable. Where the code
measured something, the measurement is carried through rather than rounded off.

## The whole surface, in one paragraph

The app talks to exactly **two remote things**, and touches **one local store**:

- **The messaging network** — `delivery_module` embeds a **Logos Messaging
  node** that joins the **`logos.test`** fleet, publishes this identity's key
  package to the **key-package registry**, and carries the encrypted room
  (including its MLS invite/welcome handshake). This is the *only* thing that
  connects when the app launches.
- **The execution zone** — `lez_core` (embedding wallet-ffi) is a client of the
  **testnet sequencer at `https://testnet.lez.logos.co`**
  ([`Zone.h:22`](../../demo/muster-ui/src/Zone.h)). Nothing here connects until
  you **open the wallet**. It is reached two ways: wallet-ffi's own connection
  for sync/transfers/proofs, and direct **JSON-RPC POSTs over `curl`** for the
  few public reads the wallet can't answer from its own state
  ([`Zone.h:84`](../../demo/muster-ui/src/Zone.h)).
- **On disk** — the wallet's `config/storage/statistics/meta.json` in the
  module's assigned directory. The chat identity and the conversations are held
  **in memory only** (libchat#28), so a restart mints a new chat address and the
  room history is gone.

The single most useful framing for the article: **messaging is a standing
connection from launch; the zone is touched only on the actions that move or
read value.** There is no background chain polling — between button presses the
app talks to nobody except the messaging health probe.

The module set and how they depend on each other:
`muster_ui → [chat_module, delivery_module, lez_core]`, with delivery's contract
sourced *through* chat_module
([`metadata.json`](../../demo/muster-ui/metadata.json) `dependencies` /
`dependency_overrides`).

---

## Phase 0 — Launch the app

**Connects to:** the messaging fleet. **Not** the zone.

1. When the framework has wired the modules, `onContextReady` →
   `initialiseModule` calls
   `chat_module.init({ delivery_preset: "logos.test", log_level: "info" })`
   ([`ChatBackend.cpp:172`](../../demo/muster-ui/src/ChatBackend.cpp),
   preset at [`ChatBackend.cpp:26`](../../demo/muster-ui/src/ChatBackend.cpp)).
   The `logos.test` preset is what points the embedded Logos Messaging node at
   the fleet and its bootstrap set. `chat_module` embeds libchat (E2EE, MLS for
   groups); `delivery_module` embeds the messaging node. During `init` the node
   also **publishes this identity's key package to the key-package registry**, so
   the chat address alone is later enough for a peer to open a room with you
   ([`two-instance-exchange.md §37`](../../demo/muster-ui/docs/two-instance-exchange.md)).
2. It subscribes to module events — `message_received`, `message_sent`,
   `conversation_created`, `delivery_state_changed`, … —
   ([`ChatBackend.cpp:293`](../../demo/muster-ui/src/ChatBackend.cpp)) and takes
   a first local snapshot (`list_conversations`), which after a fresh start is
   empty.
3. The node dialling the fleet is asynchronous: `delivery_state_changed` drives
   the status to **Online**, and the topology figure's measured window for that
   is **5–20 s**. Until Online, `get_address` is withheld
   ([`ChatBackend.cpp:343`](../../demo/muster-ui/src/ChatBackend.cpp)) — so your
   own chat address only exists once the node has joined.
4. A **health probe** starts: `chat_module.healthAsync` every **10 s** (2 s
   timeout, 2 misses ⇒ declared gone)
   ([`ChatBackend.cpp:219`](../../demo/muster-ui/src/ChatBackend.cpp),
   [`:35`](../../demo/muster-ui/src/ChatBackend.cpp)). This is the only traffic
   the app generates while idle.

> **What an observer sees at launch:** the store node learns which content
> topics this client subscribes to and when — the contact graph,
> pseudonymously. The zone sees nothing; you haven't spoken to it.

---

## Phase 1 — Establish the encrypted room

**Messaging only. The zone is not touched.** This is the "start something / open
a chat" step, and it is **independent of the wallet** — it can happen before or
after the wallet is open. Nothing about a token transfer requires the room to be
built in any particular order relative to funding.

1. **You need the peer's chat address.** It comes off their account card (shown
   once Online, from `get_address`,
   [`ChatBackend.cpp:343`](../../demo/muster-ui/src/ChatBackend.cpp)) and is
   handed over out of band. There is no directory to look anyone up in.
2. **Open the conversation** — `create_conversation(peerAddress)`
   ([`ChatBackend.cpp:438`](../../demo/muster-ui/src/ChatBackend.cpp)). The
   module **fetches the peer's key package from the registry** and **sends them
   the MLS cryptographic invite (welcome)**; the thread opens empty on your side
   ([`two-instance-exchange.md §72`](../../demo/muster-ui/docs/two-instance-exchange.md)).
   A group is the same shape: `create_group_conversation` then
   `add_group_member`, each an MLS commit that re-keys the group
   ([`ChatBackend.cpp:492`](../../demo/muster-ui/src/ChatBackend.cpp),
   [`:508`](../../demo/muster-ui/src/ChatBackend.cpp)).
3. **The peer joins.** They receive the invite and join; `conversation_created`
   fires and the room appears in both lists. Because the room has to exist before
   anything can be said in it, an opening action (e.g. "ask to be paid") is
   **held until the peer actually joins** — `holdAskUntilPeerJoins` /
   `onPeerJoined`, bounded by a timeout, after which it drops the held card
   rather than send into an empty room
   ([`ChatBackend.cpp:455`](../../demo/muster-ui/src/ChatBackend.cpp),
   [`:473`](../../demo/muster-ui/src/ChatBackend.cpp)).

> **What an observer sees:** the store node sees the invite/welcome traffic and
> both endpoints' subscription timing — that a room formed between two
> subscribers, and roughly when. MLS gives the room forward secrecy and re-keys
> on membership change, so a later joiner cannot read earlier messages; the
> content — including every card that later rides in it — stays encrypted. The
> zone sees nothing: no part of establishing a room touches the chain.

---

## Phase 2 — Open the wallet

**First contact with the zone.** `openWallet` → `ensureWalletOpen` →
`finishWalletOpen`, all deferred off the UI thread because every call below
blocks ([`ChatBackendWallet.cpp:528`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).

1. **Open or mint the wallet file.** If `storage.json` exists,
   `lez_core.open(cfg, storage, stats)`; otherwise
   `lez_core.create_new(...)`, which mints a wallet and returns a BIP39 mnemonic
   ([`:260`](../../demo/muster-ui/src/ChatBackendWallet.cpp),
   [`:277`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). The config is
   **not** written by the app — the wallet writes its own default, already
   pointing at the testnet sequencer, because that default is the schema this
   wallet-ffi expects ([`:240`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).
2. **Create the private account** — `create_account_private`
   ([`:300`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). It is deliberately
   **not registered**: on this zone, a sender's transfer is what *creates* a
   private account, at an identifier the sender picks. What you publish to be
   paid is the **key node** `(npk, vpk)` from `get_private_account_keys`
   ([`ChatBackendAssets.cpp:67`](../../demo/muster-ui/src/ChatBackendAssets.cpp)),
   and every payment to it mints a fresh account you find by scanning. (The long
   comment at [`:313`](../../demo/muster-ui/src/ChatBackendWallet.cpp) is the
   week-long trap: registering a private account *initializes* it and makes the
   id permanently uncreditable by anyone else.)
3. **Create + register the public account** — `create_account_public` then
   `register_public_account`, an on-chain registration
   ([`:342`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). This one *is*
   required, and only because the faucet won't pay an unregistered account. It
   completes well inside 20 s, unlike a private registration.
4. **Sync to the tip** — `syncToTip`: `get_current_block_height`,
   `get_last_synced_block`, then `sync_to_block` in chunks of **250** blocks
   until caught up ([`:121`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).
5. **Read balances** — `readWalletState` reads public and private balances;
   the private balance is a **scan** over `list_accounts`, not a lookup
   ([`:419`](../../demo/muster-ui/src/ChatBackendWallet.cpp),
   `readPrivateBalance`). Status → **Ready**.

> Opening the wallet is several sequencer round-trips: one account registration
> and a full sync from the last-synced block to the tip.

---

## Phase 3 — Fund the wallet (the PoW faucet, then shield)

**Connects to:** the zone, twice — a JSON-RPC read plus wallet-ffi calls.
`fundWallet` ([`ChatBackendWallet.cpp:590`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).

1. `syncToTip`.
2. **Read the faucet puzzle** — a direct JSON-RPC `getAccount` POST to the
   sequencer for the pinata account
   (`kPinataB58 = EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7`), via `curl`
   ([`:620`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). It returns a
   33-byte puzzle: a difficulty byte + a 32-byte seed.
3. **Proof of work, locally** — find a nonce whose `sha256(seed ‖ nonce)` has
   `difficulty` leading zero bytes ([`:642`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).
   Seconds at testnet difficulty; no network during this.
4. **Claim** — `lez_core.claim_pinata(kPinataId, publicAccount, nonce)`; the
   prize (**150 λ**, `kPrize`) lands in the *public* account
   ([`:679`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).
5. **Wait for the claim to land** — `waitForPublicFunds` polls the wallet's own
   `get_balance` (sync + read) until it sees ≥150, up to 60 s
   ([`:152`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). The chain showing
   the balance is not the same as this wallet being able to spend it — that gap
   is the trap the whole settle machinery exists for.
6. **Shield into private** — `transfer_shielded_ownedAsync(public → private)`,
   a zk proof on a **15-minute** budget (`kProveMs`), then `settleAfterTransfer`
   ([`:737`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). A shielded proof
   was **measured at 6 m 41 s** on a 13-core desktop
   ([`Zone.h:29`](../../demo/muster-ui/src/Zone.h)).

After this the spendable balance is private, which is what a private→private
payment draws on.

---

## Phase 4 — Ask for, and share, the receiving key

**Messaging only. The zone is not touched.** Address exchange is ordinary
encrypted chat traffic — an "address card" rides the same E2EE path as text.

- **Request** — `requestAddress` → `sendMessage(addressRequest())`
  ([`ChatBackendWallet.cpp:824`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).
- **Share** — `shareAddress` → `sendMessage(addressShare(...))` carrying, for
  the private holding, the **key node** from `get_private_account_keys`
  ([`:833`](../../demo/muster-ui/src/ChatBackendWallet.cpp);
  key-node read at
  [`ChatBackendAssets.cpp:63`](../../demo/muster-ui/src/ChatBackendAssets.cpp)).
  No on-chain registration happens; the key node never touches the chain.

> The store node sees more room activity of the same shape. The zone sees
> nothing — a receiving key is not a chain object.

---

## Phase 5 — Agree to pay

**Messaging only.** A direct send, or a proposal and approvals that are ordinary
authored messages. The home surface, proposals and the journey are all
`reduce(messages)` over `get_messages` — never a second record
([`ChatBackendJourney.cpp:390`](../../demo/muster-ui/src/ChatBackendJourney.cpp),
[`ChatBackendIntent.cpp:282`](../../demo/muster-ui/src/ChatBackendIntent.cpp)).
An approval is **authenticated by the room** (chat_module binds each message to
its author) but **not authorizing at the zone**: the paying account is
single-key, and the zone checks none of the room's counting.

---

## Phase 6 — Pay

**Connects to:** the zone (the transfer), then messaging (the receipt).
`sendPayment` → `payForIntent`
([`ChatBackendWallet.cpp:871`](../../demo/muster-ui/src/ChatBackendWallet.cpp),
[`:946`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).

1. **Provenance check, locally** — `chat_module.get_messages` re-reads the
   conversation and **refuses to pay an address the room never named**
   ([`:986`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). It establishes
   that a named peer put this address in this room (unforgeable in the room); it
   does **not** establish they meant it now — the build has no signing payload to
   bind that (F-20's job).
2. **Sync before spending** — `syncToTip`, so the spend draws on notes the
   wallet can actually see (an unsynced note is `InsufficientFunds`, not a wait).
3. **Transfer** — the private rail's send is
   `lez_core.transfer_privateAsync(to, amount)`
   ([`ChatBackendAssets.cpp:130`](../../demo/muster-ui/src/ChatBackendAssets.cpp)).
   Shielded at both ends; a zk proof on the 15-minute budget. (The four rails
   map cleanly: `transfer_privateAsync` = private→private,
   `transfer_shieldedAsync` = public→private, `transfer_deshieldedAsync` =
   private→public, `transfer_publicAsync` = public→public,
   [`ChatBackendAssets.cpp:130`–`185`](../../demo/muster-ui/src/ChatBackendAssets.cpp).)
4. **On success** — `walletSave`, then `sendMessage(sendReceipt(...))` back into
   the same room, carrying the rail and what it disclosed
   ([`:1057`](../../demo/muster-ui/src/ChatBackendWallet.cpp)). Failure comes
   back as a well-formed `success:false` envelope, not an empty string, and is
   checked as such ([`Zone.h:64`](../../demo/muster-ui/src/Zone.h)) — the reason
   a hard-failed transfer must never post a receipt.
5. **Settle** — `settleAfterTransfer(45000)`: sync-and-re-read until *this
   wallet's own view* actually moves, because a transfer the zone accepted is
   not yet a balance either side can see
   ([`:181`](../../demo/muster-ui/src/ChatBackendWallet.cpp); measured
   2026-08-12: a 7-minute shield completed and the wallet still showed
   `150 public / 0 private` until it settled).

> The sequencer learns that a transfer happened, and when — not the amount, nor
> either account, on the private rail. That "a transfer happened, and when" is
> the floor on every rail. No mixnet, so no network-origin protection; on a
> two-user testnet the anonymity set is as small as it gets; what the mempool
> exposes before confirmation is **not assessed**.

---

## Phase 7 — Receive & settle (the payee)

**Connects to:** the zone (a scan). `scanForIncomingPayment`
([`ChatBackendWallet.cpp:768`](../../demo/muster-ui/src/ChatBackendWallet.cpp)).

A shielded payee has **no address to watch**: the money mints a fresh account
under their key node at an identifier the sender chose, so nothing can notify
them. The receipt card is a **hint to go and look**, never a fact to display —
the app reads only "somebody said a payment happened", then scans with the
viewing key. `settleAfterTransfer` runs the same sync-and-re-read poll; the
private balance comes from summing `list_accounts`. A receipt for a payment that
was never made moves no number — it costs one sync and finds nothing.

---

## The connection ledger (for a table in the article)

| Action | Messaging (`delivery_module` → `logos.test`) | Zone (`lez_core` → `testnet.lez.logos.co`) | Local only |
|---|---|---|---|
| Launch app | **connect + go Online (5–20 s)**; publish key package to registry; health probe every 10 s | — | first (empty) conversation snapshot |
| Start a conversation (room) | fetch peer's key package; send MLS invite/welcome; peer joins | — | hold opening card until peer joins |
| Open wallet | — | `open`/`create_new`, register public account, full sync, read balances | mint/read wallet files; BIP39 mnemonic |
| Fund wallet | — | `getAccount` faucet read (JSON-RPC), `claim_pinata`, shield proof (~7 min) | proof-of-work mining |
| Ask / share address | send address card (E2EE) | — | — |
| Agree to pay | send proposal/approval (E2EE) | — | fold over `get_messages` |
| Pay | send receipt card (E2EE) | provenance sync, `transfer_privateAsync` (~7 min), settle poll | provenance check over messages |
| Receive & settle | (receipt arrives) | sync + scan `list_accounts`, settle poll | — |

## Caveats the article should keep honest

- **No offline/local mode.** Both remotes are live: the `logos.test` fleet and
  the testnet sequencer. Local-first is a property of the *specified* client,
  not this build.
- **Chat identity and history are in-memory only** (libchat#28). A prepared demo
  state can carry the wallet but never the conversation, and a restart is a new
  chat address.
- **Public reads go out over `curl`** as JSON-RPC POSTs — a real process spawn
  per read, not an in-library call ([`Zone.h:84`](../../demo/muster-ui/src/Zone.h)).
- **The zone is only ever touched on explicit actions.** There is no background
  balance polling; between actions the only network traffic is the messaging
  health probe.
- **`~7 minutes` is one machine's measurement** (6 m 41 s, 13-core desktop,
  testnet, 2026-08-11). Don't state it as typical.
