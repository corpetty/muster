# Runbook: try everything — two instances, one machine

**As of 2026-09-30 (main after #195).** Two instances on one machine, driven by you,
through everything the client can do today. Two scripts do all the setup:
`scripts/try-infra.sh` brings up every local chain the tour uses, already funded, and
`scripts/try-peer.sh` launches each peer seeded for it. After that, every part is
clicking.

Every label, command and setting below was read from the code on 2026-09-30. The code
wins over this page. If a label differs, note it: that is a finding too. **Known rough
edges** are listed where you will meet them, so you can tell a known issue from a new one.
Steps nobody has yet done on screen are marked **first on screen**; what you see there is
the finding.

| Part | What | Needs | Time |
|---|---|---|---|
| [0](#0-set-up-the-chains-and-two-peers) | Build, bring up the chains, launch two peers | Nix; the Logos fleet | 15 min (+ first build) |
| [1](#1-rooms-that-name-nobody) | Rooms that name nobody | — | 5 min |
| [2](#2-chat-and-who-said-it) | Chat and who said it | — | 2 min |
| [3](#3-a-decision-the-room-signs) | A decision the room signs, and its audit trail | — | 10 min |
| [4](#4-a-safe-payment-settled-on-chain) | A Safe payment, settled on chain | anvil (up) | 10 min |
| [5](#5-bitcoin-a-multisig-and-a-frost-key) | Bitcoin: a multisig with a signer outside muster, and a FROST key | regtest (up) | 20 min |
| [6](#6-split-the-bill) | Split the bill: ETH, a token, for someone else, another currency, settle up, Bitcoin, renewing an expired split | anvil + regtest (up) | 35 min |
| [6h](#6h-the-private-split-on-the-lez-testnet) | The private split on the LEZ testnet | internet; proofs of minutes each | 40 min |
| [7](#7-the-lez-multisig-on-the-public-testnet) | The LEZ multisig on the public testnet | internet; ~40 s blocks | 20 min |
| [8](#8-lez-frost) | LEZ FROST | internet | 10 min |
| [9](#9-wallet-and-send-λ) | Wallet and Send λ | — | 5 min |
| [10](#10-the-walkthrough-and-the-atlas) | The walkthrough and the atlas | a browser | 5 min |
| [11](#11-preview-the-ui-in-a-nim-host) | Preview: the UI in a Nim host (no C++) | — | 5 min |

Every action here has a page in the atlas, <https://corpetty.github.io/muster/atlas/>
(**Actions**): what it signs, who learns what, what it refuses, and its tests. Each
built action there links back to its part of this tour.

Older runbooks cover what this one skips. [`../manual-test-runbook.md`](../manual-test-runbook.md)
covers multi-room, the dashboard and Settings in depth.
[`transaction-lifecycle-demo.md`](transaction-lifecycle-demo.md) is the talk-track version.
[`../two-party-demo-runbook.md`](../two-party-demo-runbook.md) covers two machines.

---

## 0. Set up: the chains and two peers

### Build

```bash
git pull --ff-only
```

```bash
make build
```

The first build takes minutes. It warns if `module/` has uncommitted edits.

**Every peer must run this build.** Since #167 the wire format changed: join requests,
key grants and envelopes are all sealed differently. An older build, the `v0.1.0-demo`
AppImage included, cannot share a room with this one in either direction.

### The chains

```bash
scripts/try-infra.sh up
```

It takes about a minute (longer the first time, while nix fetches foundry and Bitcoin
Core). It uses ports of its own, 8555 and 18453, so a devnet you already run on 8545 is
left alone. Each `up` starts fresh chains.

**✓ Expect** it to end with:

```
anvil     up on http://127.0.0.1:8555 (started here)
bitcoind  up on :18453, height 103
miner     running
```

What is now up:

- **anvil** (chain 31337), with the real Safe v1.4.1 at
  `0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841`: 2-of-3 over anvil accounts 0, 1 and 2
  (Alice, Bob and Carol), holding 5 ETH.
- **MTD**, an ERC-20 test token with 6 decimals. Alice, Bob and Carol hold 1000 MTD each.
- **Bitcoin Core on regtest.** Alice's and Bob's payer addresses hold 0.05 BTC each. A
  2-of-3 P2WSH multisig and a 2-of-3 taproot multisig over Alice, Bob and Carol hold
  1 BTC each. Carol's key is in Bitcoin Core's `carol` wallet, so in Part 5 she is the
  signer outside muster.
- **A miner** that mines a block every 10 s, so no step waits on you to mine.
- A check that the **LEZ testnet** answers.

Every address and key a step needs is in `.run/try/env`:

```bash
scripts/try-infra.sh env
```

Two helpers talk to these chains: `scripts/try-infra.sh btc …` runs `bitcoin-cli` on
this node, and `scripts/try-infra.sh eth …` runs `cast` on this anvil. `status` shows
what is up; `down` stops only what `up` started.

### Two peers

One per terminal:

```bash
scripts/try-peer.sh alice --fresh
```

```bash
scripts/try-peer.sh bob --fresh
```

Use `--fresh` the first time, and whenever the chains are new. It wipes that peer's
identity, saved Settings and contacts, because seeding applies only when an identity is
first minted, and a saved Setting beats the seeding.

**✓ Expect**
- Two windows, each on the public `logos.dev` fleet. Since Testnet v0.3 a node on
  `logos.test` starts only with an active RLN membership (exo-eb6.3); `TRY_FLEET=logos.test`
  picks it once you have one.
- Alice is anvil account 0 and Bob account 1: each is a Safe owner, and each Bitcoin key
  pays from its funded payer address. Each already has the other, and Carol, as named
  contacts.
- **Settings** shows **RPC endpoint · now: http://127.0.0.1:8555** and **Bitcoin node ·
  now: http://muster:muster@127.0.0.1:18453**.
- The nav bar reads **Home · Room · Account · Walkthrough · Settings · Contacts · Send λ**.

`scripts/try-peer.sh carol --fresh` in a third terminal adds a third member. Nothing in
the tour needs her, but a split among three is more interesting, and settling up among
three nets more.

Each peer's log is `.run/try/<peer>.log`. `make run-fleet PEER=alice` still works, but it
points at port 8545 and at no Bitcoin node; this tour assumes `try-peer.sh`.

**Saving in Settings.** One **Save** stores every value on the page, and from then on
the saved values beat what `try-peer.sh` passes in. `--fresh` resets that.

---

## 1. Rooms that name nobody

What changed (exo-661.7). Everything on a room's content topic is readable by any store
node and any subscriber. Until #167 the topic itself gave away:

- **the join request:** the joiner's identity, plus a signature that recovers their
  address;
- **every admit:** the whole member list;
- **every message:** its key epoch (which generation of the room key sealed it);
- **the room's name:** the activity, part of the peer's chat id, and the creation time.

None of it is there now.

**Steps**

1. **Alice:** **Start something** → **Just talk**. Under *Who's doing it with you?* pick
   the **Bob** chip, then **Open the room with them**.
2. **Alice:** look at the room header. It reads `Room · /muster/1/muster.room.<16 hex>/proto`.
   ✓ Expect: random bits only — no "talk", no piece of Bob's id, no time.
3. **Alice:** go **Home**. ✓ Expect: the row is titled **talk · with** followed by the
   first 8 hex of Bob's id and "…". That title lives in this session only; the topic
   names nothing.
4. **Bob:** on **Home**, under **Invitations**, expect **Alice invited you to a room ·
   talk**. Click **Join**.
5. **Both:** watch the right-hand panel. Bob asks automatically. Alice admits him
   automatically, because she named him in step 1.
   ✓ Expect: both show **2 in the room**, typically within 15–20 s. Bob's Home title is
   **talk · from Alice**.

What happens underneath:

- Bob's first ask may find no room join key yet. It then asks the room to announce one,
  and the next retry, 3 s later, sends the sealed request.
- Alice's key grants are sealed whole to each member.
- The store node sees *that* someone asked, and that an admit re-keyed two members.
  It never sees who.
- `module/tests/store_node_view_test.nim` proves this frame by frame.

**Also try the manual path.**

1. **Alice:** **Start something** → **Just talk** → **Bob** → **Open the room with
   them**.
2. **Alice:** go **Home** at once, then back into the new room by its row. Re-entering
   clears the auto-admit.
3. **Bob:** **Join** the new invitation.
4. **Alice:** under **Waiting to join**, Bob appears by alias. The row adds **· owner**
   if his signed binding names a signer of an account disclosed in the room. Click
   **Admit**.
5. If Bob's ask ever stalls, **Ask to join this room** (Bob's scope panel) re-sends it.

While Bob's ask waits for the room's join key, his scope panel says so: *Waiting for
someone in the room to announce its join key…*. Once it's sealed and sent, the panel reads
*Your ask is sealed and sent*.

Use the first room for the rest of the tour.

**Known rough edges**
- Titles are session-only; after a restart, Home and the header show the topic.
- Auto-admit works only while Alice stays in the room she just composed. After she
  re-opens it from Home, admit by hand.

---

## 2. Chat and who said it

In the shared room, type in **Say something** and press **Send**, from each side.

**✓ Expect**
- Your own messages are labelled **you**.
- The other side's messages carry the contact alias, then the timestamp (raw unix
  seconds).

What changed (exo-f76). Messages, declines, material shares, account disclosures and
FROST joins carry their author's signature. An event whose signature doesn't verify is
dropped from every view. **Nothing on screen shows this.** There is no "signed" badge,
and a dropped forgery leaves no trace. The screen shows only correct names. The proof is
`authorship_test`.

---

## 3. A decision the room signs

No chain. This is also where the card explains itself, and where you take away a
record anyone can check.

1. **Alice:** click **+** → **Statement** → *Endorse with* **Threshold**. Type something in
   **what the room ratifies…**, then **Propose**.
   - The card reads **Proposed a statement**, headed **Statement · 2 of 2**, with the
     status rail proposed · collecting · ready · final.
2. **Open "What this needs".**
   ✓ Expect:
   - **✓ you have everything this needs**, from one need: **authority: roster-member**.
   - *Who will see what*: the store node sees only **timing, topic**.
   - The agreement line ends with **final in the room**.
3. **Alice: Approve.** ✓ Expect: the slots show **1 of 2**, the first slot carries **Y**,
   and a line under them reads **by you**. **Approve** is gone from Alice's card: the
   module proves from the log and her keys that she approved. On Bob's side the same line
   reads **by Alice**.
4. **Bob: Approve.** ✓ Expect **2 of 2**, **by Alice, you** on Bob's side, then the ready
   box: **✓ Endorsed — a signed group decision. Nothing settles on-chain.** A member
   counts once however many times they sign; `distinct_signer_test` proves it.
5. **Room history** (right column) reads *Approved by Alice*, *Approved by you*. Open **Who can
   see what** and try **Show per-action rows**: each row is one field reaching one
   observer, and the store node is on every one.
6. Propose a second statement. **Bob: Deny.**
   ✓ Expect the card to show **1 declined: Bob** (on Bob's side, **you**). The history line
   reads *Declined by Bob — chose not to take part — the threshold is unchanged*.
7. **Governance.** In *Endorse with*, click **＋ Propose unanimous** and approve it on both
   sides. ✓ Expect a **Unanimous** button to appear. The room admitted a new policy by
   vote. (The payment and split kinds need no such vote: each is usable from the start.)

**The audit trail.** On any card, click **Download audit trail**. ✓ Expect: *Saved …
(verifies on its own) and a readable report beside it*, written to `.run/try/<peer>-audit`.
Check it with nothing but the file. Build the verifier once:

```bash
bash -c 'P=$(module/tools/nim-closure.sh); SODIUM=$(nix build nixpkgs#libsodium --no-link --print-out-paths | head -1); cd module && nim c -d:release --hints:off --threads:on --path:$P/nim-secp256k1 --path:$P/nim-stew --path:$P/nim-results --path:$P/nimcrypto --path:$P/nim-stint --path:$P/nim-intops/src --passL:"$SODIUM/lib/libsodium.so" -o:../muster-audit-verify tools/muster_audit_verify.nim'
```

```bash
./muster-audit-verify .run/try/alice-audit/muster-audit-<id>.cbor --report
```

✓ Expect `"ok": true`, the approvals by name, and exit code 0. Edit one byte of the file
and the verifier refuses it (exit 1).

---

## 4. A Safe payment, settled on chain

The Safe is already deployed and funded (Part 0).

1. **Alice:** in **Accounts** (right column), click **Disclose the local test Safe**.
   ✓ Expect the row **Local test Safe (anvil) · 2 of 3**, then `evm.safe · eip155:31337 · …`,
   **the chain agrees**, and the whole address with **Copy address**.
2. **Bob:** within 10 s the Safe appears under Accounts too. Other members' accounts
   refresh on a 10-second tick.
3. **Alice:** **+** → **Payment** → *Settles via* **Safe** → pick the account under
   *From*.
   ✓ Expect the context box: *you act as … ✓ a Safe owner — your approval counts*.
4. Enter recipient `0x90F79bf6EB2c4f870365E785982E1f101E93b906` (anvil account 3) and
   amount `1000000000000000` (wei). Click **Propose**.
5. **On the card, open ▸ How this account works.**
   ✓ Expect ten rows: *Where the rule lives · What you sign · Only valid on · Ordering ·
   Expiry · Collecting · What the chain learns · Approving costs you · Changing signers ·
   Ways around the rule*.
6. **Open "What this needs".**
   ✓ Expect the needs:
   - `environment: eip155:31337`
   - `infra: rpc`
   - `authority: safe-owner (each signer)`
   - `address: payee`
   - `asset: amount`

   ✓ Expect **Touches**:
   - `eip155:31337:0xeb4520e3…e841 (write)` — the Safe, named in CAIP-10
   - `…/nonce (write)`
   - `eip155:31337 (write)`

   ✓ Expect *anyone reading the chain* to see **to, value, data, operation, nonce, gas,
   payer, policy, signers**, and *your RPC provider* the **signed-tx**.
7. **Approve on both.** ✓ Expect **✓ Ready — the approvals are collected.** and
   **Settle on-chain**.
8. **Settle on-chain.** ✓ Expect **✓ Settled on-chain (final)**. Confirm with the chain
   itself:

   ```bash
   scripts/try-infra.sh eth balance 0x90F79bf6EB2c4f870365E785982E1f101E93b906
   ```

   ✓ Expect `10000001000000000000000`: anvil's 10000 ETH plus your 0.001, in wei.

**Optional:** *Endorse with* **Attest** (EIP-191) acts from the same Safe.
✓ Expect *✓ a recognized attester (a Safe owner)*.

The history reads *Submitted on-chain — the Safe execTransaction was sent through your
RPC*, then *Settled on-chain — final — the payment landed*.

---

## 5. Bitcoin: a multisig, and a FROST key

Two ways to hold Bitcoin together:
- **5a**, a classic multisig built from each member's key. The tour's 2-of-3 is
  already funded, and its third signer, Carol, signs in Bitcoin Core: a signer outside
  muster.
- **5b**, a FROST key made by a ceremony, whose spend settles as one 64-byte signature.

Both peers already point at the node (Settings → **Bitcoin node**). A payment confirms
within about 10 s, because the miner is running.

For a recipient, take a fresh address from the node's miner wallet:

```bash
scripts/try-infra.sh btc -rpcwallet=miner getnewaddress
```

### 5a. A multisig, with a signer outside muster

1. Get the three keys:

   ```bash
   grep TRY_KEY_ .run/try/env
   ```

   Alice's and Bob's are also in their own **Settings → YOUR BITCOIN KEY**.
2. **Alice:** **Accounts → Bitcoin multisig**.
   - Pick **P2WSH**.
   - Set **k** `2`, network `regtest`.
   - Paste the three keys, comma-separated, then **Disclose this Bitcoin multisig**.
   - ✓ Expect a `btc.p2wsh-sortedmulti · bip122:0f9188f1… · bcrt1q…` account, **2 of 3**.
     Its address is derived from the keys alone, and it is `TRY_P2WSH` in
     `.run/try/env`: Bitcoin Core derived the same one, and it already holds 1 BTC.
3. **Alice:** **+** → **Payment** → *Settles via* **Bitcoin (P2WSH)** → pick the account.
   - Recipient: the address from above.
   - **amount (sat)** `40000000`, **fee** `2`, then **Propose**.
   - ✓ Expect the card: **Proposed a Bitcoin payment**, `40000000 sat → bcrt1q…`. Change
     back to the account is not counted as a payment.
4. **Alice: Approve.** Her signature is made in-app, through her keystore.
5. **Carol signs outside muster.** On the card, click **Sign outside muster (PSBT)**, then
   **Copy PSBT**. In a terminal:

   ```bash
   scripts/try-infra.sh btc -rpcwallet=carol walletprocesspsbt "<paste the PSBT>" true ALL
   ```

   Copy the `"psbt"` value it prints (not the whole JSON). Paste it into **the signed PSBT
   (base64)** on the card, then **Import**.
   ✓ Expect *✓ 1 signature(s) added — signed outside muster, counted.* and the state
   `executable`. Carol's slot is ringed, and the card says why: *1 signed in muster —
   committed to where every input came from. 1 signed outside muster and pasted in
   (ringed) — counted, but committed to nothing beyond the transaction itself.* Open
   **How do I know this?** to see the two approvals graded **committed — attested in
   muster** (Alice) and **unattested — pasted from outside muster** (Carol).
6. **Settle on-chain.** ✓ Expect *Broadcast to Bitcoin*, then *Confirmed on Bitcoin* in
   the history, within about 10 s, and the ready box turns final.

**Try the taproot one too:** the same steps with **Taproot**; its address is `TRY_TAPROOT`.
Carol signs with `DEFAULT` in place of `ALL`:

```bash
scripts/try-infra.sh btc -rpcwallet=carol walletprocesspsbt "<paste the PSBT>" true DEFAULT
```

Or skip Carol and have **Bob: Approve**: any two of the three settle it.

### 5b. A FROST key

**The ceremony**
1. **Alice:** in **Accounts → FROST key ceremony (Bitcoin taproot)**, fill in:
   - name `vault`
   - **t** `2`, **n** `2`
   - network `regtest`

   Then click **Open the ceremony and join it**.
2. **Bob:** the ceremony row appears (`vault · 2 of 2 · 1 joined · …`). Click **Join**.
3. Watch the row advance through its steps, driven by each instance's 1 s tick.
   ✓ Expect a **FROST 2 of 2** account (`btc.frost-bip445 · bip122:0f9188f1… · bcrt1p…`).
   If it doesn't show, go Home and click the room row.

**Fund it.** Click **Copy address** on the FROST account. Then:

```bash
scripts/try-infra.sh btc -rpcwallet=miner sendtoaddress <paste the FROST address> 1.0
```

**Spend it**
1. **Alice:** **+** → **Payment** → *Settles via* **Bitcoin (FROST)** → pick the FROST
   account under *From*.
2. Recipient: a fresh miner address, as above.
3. **amount (sat)** `40000000`, **fee (sat/vB)** `2`, then **Propose**.
4. On the card, ✓ expect **round 1 of 2**.
   - **Open "What this needs"**: expect `environment: bip122:0f9188f13cb7b2c71f2a335e3a4fc328`,
     `infra: bitcoind-rpc` and `authority: frost-share`. Touches name each coin spent as
     `utxo:<txid>:<vout>`.
5. **Both: Approve once.** Round 2 follows on its own.
   ✓ Expect the header to move to *2 rounds complete*.
6. **Settle on-chain.** Within about 10 s, check the recipient:

   ```bash
   scripts/try-infra.sh btc -rpcwallet=miner getreceivedbyaddress <the recipient>
   ```

   ✓ Expect `0.40000000`. Look up the spend (`scripts/try-infra.sh btc getrawtransaction
   <txid> 1`): its witness is **one 64-byte signature**, the same as a single-signer
   taproot spend.

**Known rough edge:** **Sign outside muster (PSBT)** appears on a FROST card, but a FROST
key has no outside format.

---

## 6. Split the bill

One of you fronted a bill; the others each owe a share. There is no shared account: each
person agrees to their own share with their room key, the person who fronted it agrees
that the address is theirs, and then each person pays their own share from their own
wallet. The one who fronted it confirms each payment from their own read of the chain.
Nothing on the chain says who was at dinner.

**Where it starts.** In a room, **+** → **Split**. A new room can start as one too:
**Start something** → **Split a bill**. The row under the total says where it settles,
**Settles on**:

| Button | Pays in | Confirmed by |
|---|---|---|
| **Split (Ethereum)** | ETH, or an ERC-20 token | the creditor's own RPC read |
| **Split (Bitcoin)** | BTC | the creditor's own node, at 1 confirmation on regtest |
| **Split privately (LEZ)** | LEZ, shielded to shielded | the creditor's own wallet scan |

All three are usable at once: the room does not vote to admit them.

**Stay in the room while a payment lands.** A payer's client reports the payment, and the
creditor's client confirms it, only while that room is the one on screen. Leave it
before a payment shows **✓ received** and the report waits until you come back.

### 6a. A bill in ETH

1. **Alice:** **+** → **Split** → *Settles on* **Split (Ethereum)**.
   - **total (ETH)** `0.02`; **what for (only the room sees this)** `dinner`.
   - Under *Who owes you a share — tap to leave someone out:*, Bob's chip is in.
   - **✓ I'm in it too** is on.
   - ✓ Expect the preview: *1 person owes you 0.01 ETH; your own share is 0.01 ETH (it
     absorbs any rounding). They pay from their own wallet — the payment is public on
     the chain.*
   - **Propose.**
2. ✓ Expect the card **Proposed a split**, headed **Split · 2 of 2**: every party must
   agree, and the slots already show one, because proposing was Alice's own agreement.
   Bob's row reads **to agree**, and Alice's line ends *Paid to 0xf39f…*, her own
   address.
3. **Bob:** **Home** reads **1 waiting on you**, with a row **Needs your agreement**. In the
   room, his card reads *Your share: 0.01 ETH → 0xf39f…, from your own wallet. Muster
   builds the payment from this split — nothing to type, and nothing else can be sent.*
   - **Open "What this needs"**: the payer's needs are marked *(each person who pays
     their part)*, and *anyone reading the chain* learns payer, payee and amount.
   - **Agree to my share.** ✓ Expect *✓ Agreed — each person now pays their own share.*
4. **Bob:** **Pay my share — 0.01 ETH**.
   ✓ Expect *Sent 0.01 ETH from your wallet (…) — it shows as paid once it settles.*
   Bob's row moves **paying…** → **paid (…) — Alice has not seen it yet** →
   **✓ received**. Alice clicks nothing: her client confirms from her own RPC read.
5. ✓ Expect *✓ Settled — every share confirmed by who it was owed to.* on both.

**Mark received** on the creditor's card is for money that arrived outside muster: it
is the creditor's word, and the row says so.

### 6b. In a token

The tour's anvil has **MTD**, 6 decimals, 1000 each. Its address is `TRY_TOKEN`:

```bash
grep TRY_TOKEN .run/try/env
```

1. **Alice:** **+** → **Split** → **Split (Ethereum)**. Paste the token address into
   **pay in a token instead of ETH: its address (0x…), or leave empty**.
   ✓ Expect *MTD — the token at 0x… says so; 6 decimals. A token names itself: check the
   address.*, and the total field reads **total (MTD)**.
2. Total `30`, then **Propose**. ✓ The card adds *Paid in MTD — the token at 0x… (a token
   names itself; the address is what counts).*
3. **Bob:** **Agree to my share**, then **Pay my share**: 15 MTD.
4. When Bob's row reads **✓ received**, check Alice's balance on the token itself:

   ```bash
   scripts/try-infra.sh eth call <TRY_TOKEN> "balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
   ```

   ✓ Expect `1015000000`: 1000 MTD plus Bob's 15, in base units.

### 6c. For someone else

Bob writes the split, but Alice paid the bill. It is paid at the address Alice shared
into the room, and nobody pays until Alice agrees that address is hers.

1. **Alice shares an address.**
   - **Bob:** **+** → **Payment**, then **Ask the room** beside the recipient field.
     ✓ Expect a card **Asked for an address**.
   - **Alice:** on that card, **Share an address**. ✓ Expect a card **Shared an address** ·
     ETH · *public account · 0xf39f…*.
2. **Bob:** **+** → **Split** → **Split (Ethereum)** → under **Who paid the bill?** pick
   **Alice**.
   - ✓ Expect *Paid to 0xf39f…, the address Alice shared. Nobody pays until Alice agrees
     it is theirs.*
   - Total `0.004`; **✓ Alice is in it too**; the **You** chip (Bob) is in. Leave the
     token field empty (clear MTD's address if it is still there). **Propose.**
3. **Alice:** her card reads *Proposed by Bob on your behalf. Nobody pays until you agree
   that 0xf39f… is yours.* Click **Agree — I paid, and 0xf39f… is mine**.
   ✓ Expect *✓ You agreed that 0xf39f… is yours.*
4. **Bob:** proposing on someone's behalf is not agreeing to your own share. **Agree to
   my share**, then **Pay my share**.

A client agrees only to an address it holds. Had the split named an address that is not
Alice's, her card would say so and offer no Agree.

### 6d. A bill in another currency

1. **Alice:** **+** → **Split** → **Split (Ethereum)** → **The bill is in another
   currency**.
   - The currency field reads `EUR`.
   - **total (EUR)** `36`.
   - **1 EUR = ? ETH** `0.0004`.
   - **where the rate is from (everyone will see it)**: `my card statement`.
   - ✓ Expect *36 EUR at 1 EUR = 0.0004 ETH comes to 0.0144 ETH. The rate is your quote: it
     is recorded with the proposal, and everyone agreeing trusts it.*
   - **Propose.**
2. **Bob:** the card, in the warning colour: *A bill of 36 EUR, converted at 1 EUR =
   0.0004 ETH — Alice's quote, from “my card statement”, …. Agreeing means trusting this
   rate: check it first.* **Agree to my share**, and **don't pay it**: Part 6e settles it.

The quote is signed into the split and recorded as an outside read before anyone
agrees. Without that record, every agreement would be refused as an input nobody can
account for (invariant 10).

### 6e. Settle up

Several agreed, unpaid shares on one chain and asset, netted into fewer payments. Every
member's balance is kept exactly, and each person is paid only at an address a split
owing them agreed.

1. You need at least two open shares. Bob owes Alice 0.0072 ETH from 6d. Now the other
   way:
   - **Bob:** **+** → **Split** → **Split (Ethereum)**, total `0.006`, memo `taxi`,
     **✓ I'm in it too**, Alice in. **Propose.**
   - **Alice:** **Agree to my share**, and don't pay it. She owes Bob 0.003 ETH.
2. **Alice:** **+** → **Split** → **Split (Ethereum)**, with the token field empty →
   **Settle up the room's open splits instead**. No total is needed. It nets the shares
   on the chain and asset the composer is set to: ETH here.
3. ✓ Expect a card **Proposed to settle up**: *Settle up — 1 payment instead of 2 shares
   from 2 splits*, one row **Bob → Alice · 0.0042 ETH · once everyone agrees**.
4. **Bob:** **Agree to settle up**. Then **Pay 0.0042 ETH to Alice**.
5. ✓ Expect the row to reach **received ✓** without Alice clicking. The settle-up goes
   final, and so do both splits it covered: their shares read **✓ paid through a
   settle-up**, marked by each creditor's client.

While the settle-up is agreed, paying a covered share directly is refused. A settle-up
never nets the private split: its shares are told apart by amount.

### 6f. In Bitcoin

Alice's and Bob's payer addresses already hold 0.05 BTC each (`TRY_ALICE_BTC`,
`TRY_BOB_BTC`). A payer pays from `wpkh(<their muster key>)`, through their own node.

1. **Alice:** **+** → **Split** → **Split (Bitcoin)**. **total (BTC)** `0.02`,
   **✓ I'm in it too**, Bob in. ✓ Expect the preview to end *Each share is exactly
   1000000 sat.*: a Bitcoin share is paid and confirmed in satoshis. **Propose.**
   ✓ Expect the card to pay Alice's own wpkh address, `TRY_ALICE_BTC`.
2. **Bob:** **Agree to my share**, then **Pay my share — 0.01 BTC**. His client reads his
   coins from his node, signs each input through his keystore, and broadcasts.
3. ✓ Expect Bob's row: **paying…** until a block includes it (the miner, within 10 s),
   then **paid**, then **✓ received**: Alice's own node found an output paying her address
   exactly 1000000 sat.
4. Check it on the node:

   ```bash
   scripts/try-infra.sh btc scantxoutset start '["addr(<TRY_ALICE_BTC>)"]'
   ```

   ✓ Expect `"total_amount": 0.06000000`: her 0.05 and Bob's 0.01.

A Bitcoin split is proposed only by whoever fronted it: the room's shared addresses are
Ethereum ones. Settling up works on Bitcoin too: two open BTC splits, then **Settle up
the room's open splits instead** under **Split (Bitcoin)**. A share below Bitcoin's
546-sat dust limit can never be paid, so **Propose** stays off while the preview warns.

### 6g. Renew an expired split

A split's agreement expires (after 7 days by default). A share still unpaid then cannot
be paid under it, and paying against an expired agreement is refused. Renewing proposes a
settle-up of its unpaid shares under a fresh expiry, and everyone who still owes agrees
again. To see it without waiting a week, give Alice's proposals a two-minute expiry.

1. Close Alice's window and relaunch her with the short expiry, without `--fresh`, then
   open the room from **Home**:

   ```bash
   MUSTER_INTENT_TTL_S=120 scripts/try-peer.sh alice
   ```

2. **Alice:** **+** → **Split** → **Split (Ethereum)**, total `0.002`, **✓ I'm in it
   too**, Bob in, then **Propose**. **Bob:** **Agree to my share**, and don't pay it.
3. Wait two minutes. ✓ Expect on both cards: *Expired: no share of it can be paid now.
   Renewing asks everyone who still owes a share to agree again, under a new expiry;
   once they pay, this split is settled too.* and a button **Renew the unpaid shares**.
4. **Bob:** **Renew the unpaid shares**. His client has the usual 7-day expiry, so the
   renewal gets it. ✓ Expect *Renewal proposed — it appears below; everyone who still
   owes a share agrees to it again.*, a settle-up card for Bob's one unpaid share, and
   on the old card *A renewal of its unpaid shares is waiting below for everyone it names
   to agree.*
5. **Alice:** **Agree to settle up**. **Bob:** **Pay 0.001 ETH to Alice**.
   ✓ Expect the renewal to go final, and the expired split with it: Bob's share reads
   **✓ paid through a settle-up**.
6. Close Alice's window and relaunch her with the usual expiry:

   ```bash
   scripts/try-peer.sh alice
   ```

**Known rough edges in Part 6**
- The rail row shows **1 needed** beside the split buttons, though every party must agree.
- After paying in a token, the note names it `erc20:0x…`, not by its symbol.
- The verify box's **shown** row is blank on a split card.
- Nothing on screen shows your Bitcoin payer address; it is in `.run/try/env`.

### 6h. The private split on the LEZ testnet

**First by hand.** The same split, paid shielded to shielded on the LEZ testnet: the chain
learns only that private transfers happened, never who paid whom or how much. The
creditor's own wallet scan finds a note of exactly the share. It has run end to end on
the testnet by script (`scripts/split-lez-testnet.sh`); this is the first time by hand.

It needs real LEZ wallets on both sides, and Bob needs a private balance. There is no
faucet button in the app yet, so `--lez-fund` does what a person would: one claim from the
testnet faucet (about 150 base units) into Bob's public account, then a shield of all of
it to his own key node. Each proof takes minutes; allow about 40 minutes in all.

1. Close both windows, then relaunch, without `--fresh` (keep the identities and the
   room). Back in each window, open the room from **Home**: after a restart its row is
   titled by its topic.

   ```bash
   scripts/try-peer.sh alice --lez
   ```

   ```bash
   scripts/try-peer.sh bob --lez-fund
   ```

2. **Bob:** wait until his wallet is funded:

   ```bash
   grep LEZFUND .run/try/bob.log
   ```

   It moves through `LEZFUND setup`, `LEZFUND public balance …` (the claim, once a block
   includes it), `LEZFUND shield`, and ends at `LEZFUND funded`: about 10 minutes, most
   of it the shield's proof and a first scan from block 0.
3. **Alice:** **+** → **Split** → **Split privately (LEZ)**. **total (LEZ)** `0.0000001`
   (100 base units: LEZ has 9 decimals, and the faucet pays little). **✓ I'm in it too**,
   Bob in.
   - ✓ Expect *1 person owes you about 0.00000005 LEZ. They pay privately from their own
     wallet: the chain learns only that a private transfer happened, and your own scan
     finds the note by its amount.*
   - **Propose.** The card shows where it pays as *a shielded key node, …*, and adds
     *· private: the chain names no one*.
4. **Bob:** **Agree to my share**. Once `LEZFUND funded`, **Pay my share**.
   ✓ Expect *Sending … LEZ privately — your wallet is proving the transfer, which takes a
   few minutes; it shows as paid once it lands.* His row reads **paying…** for about
   6–8 minutes.
5. ✓ Expect Bob's row on Alice's side: **✓ received — a private note of exactly this
   share**, once her scan finds it, then final on both.

The testnet wallets live in `.run/try/alice-lez` and `.run/try/bob-lez`, and `--fresh`
leaves them alone. A second private split reuses them: `--lez` on both, and Bob pays from
the change his note kept.

**If it stalls:** Bob's pay answers *no one shielded note of yours covers …* until the
shield has landed, and *… pay once it has; it cannot yet see the note it would spend*
while his scan catches up. Wait, then pay again.

---

## 7. The LEZ multisig on the public testnet

This is a Squads-style program on Logos's own chain, already deployed on the public
testnet. The defaults already point there: Settings shows **LEZ sequencer · now:
https://testnet.lez.logos.co (lez:testnet)**. Blocks take about 40 s, so expect waits.

1. **Both:** in **Accounts → LEZ multisig**, click **My LEZ member account**. Copy the id,
   and paste Bob's into the chat for Alice.
2. **Alice:** set **k** `2`, and in *members' LEZ accounts, comma-separated* enter both
   ids. Click **Create this LEZ multisig on chain**.
   ✓ Expect *⏳ Sent to … (tx …) — it is disclosed here once a block includes it.*
   After inclusion the account discloses itself. Refresh via Home → the room row.
3. **Alice:** **+** → **Payment** → *Settles via* **LEZ multisig**. Fill in *recipient
   token holding* and *amount (token units)*, then **Propose**.
   ✓ Expect *⏳ Proposal #N is on its way to the chain*. Your Propose counts as your vote.
4. **Open "What this needs"**.
   ✓ Expect:
   - `environment: lez:testnet`
   - `infra: lez-rpc`
   - `authority: lez-multisig-member`

   **Touches** names the proposal account and every account the proposal passes (write),
   plus the program it calls (read), all as `lez:testnet:<id>`.
5. **Bob: Approve.** This is your own on-chain vote.
   ✓ Expect *⏳ Your vote is on its way to the chain — it counts once a block includes it.*
6. **Settle on-chain** (first on screen). ✓ Expect *⏳ Executing on chain*. **The
   execution is expected to be rejected** unless the vault holds that token. Nothing in
   the app mints a token or funds the vault yet (`exo-2752`). What you're judging here is
   the propose-and-vote experience.

---

## 8. LEZ FROST

This is the Part 5b ceremony, but on the LEZ. Set **network** `lez:testnet`. The group's
key then owns a LEZ public account directly, with no tweak.

1. Run the ceremony. ✓ Expect a LEZ FROST account to be disclosed.
2. **+** → **Payment** → **LEZ (FROST)** → recipient + amount → **Propose**.
3. ✓ Expect **Approve** and **Deny** on the card.
4. Approve once on each side. Round 2 follows.
5. **Settle on-chain** is expected to be **rejected**: the group account holds nothing,
   and nothing in the app funds it (`exo-2752`).

---

## 9. Wallet and Send λ

- **Account → WALLET:** **Refresh balances**. Alice's ETH is read from the tour's anvil.
  The badge reads *attested*: the verified read isn't wired to this card yet.
- **Send λ:** under *YOUR ADDRESSES — SHARE ONE TO BE PAID*, **Copy** one. Use it (or
  one of the other peer's) as the recipient with an amount, then click **Preview** and
  **Send**.
  - ✓ Expect *Rail: … · public record: …*, then *✓ sent on the … rail*.
  - The rail follows the address form. A public id sends in public; a `priv:npk:vpk` key
    travels shielded, and the preview says which fields reach the public record.
  - Without `--lez` this runs on an in-process fake LEZ whose demo accounts are funded.
    It's the whole flow with nothing to set up, but each instance has its own fake chain,
    so the other peer won't see the payment arrive.

---

## 10. The walkthrough and the atlas

- **Walkthrough → Open the room.**
  - PROTECTS: **Nothing on the room's topic says who is in it** (FS-7,
    `store_node_view_test`, imperative).
  - The store-node GAP claim says exactly what remains visible: topic, timing, size,
    frame kind.
- **<https://corpetty.github.io/muster/atlas/>** → **Actions**.
  - Each built action links back here: **Try it yourself** under its summary.
  - Splitting a bill is five actions across three families: `evm.split/split`,
    `evm.split/settle-up`, `btc.split/split`, `btc.split/settle-up` (new), and
    `lez.split/split`, the private split.
  - `room/admit-member` describes the sealed request and grants; `room/join`, the random
    topic.

---

## 11. Preview: the UI in a Nim host

The UI you have been clicking is QML over a C++ backend. Epic exo-607 moves the backend
to Nim on nim-seaqt, so the repository holds no C++ (design and progress:
[`../design/seaqt-ui.md`](../design/seaqt-ui.md)). The first slices run today: the real
`Main.qml` in a Nim host that starts logos-core itself and calls `muster_module` over
`lp_*`.

```bash
scripts/nim-app-core-probe.sh
```

It runs offscreen and needs `make build`. ✓ Expect `PASS`: the module's health reached
the view through the Nim host. The room surfaces are not wired in the Nim host yet;
`scripts/ui-parity.sh` with `MUSTER_UI=nim` is how each will be checked as it lands.

---

## What to report

For each part: ✓, or what you saw instead. For first-on-screen steps, what you saw even
if it looks right. Beyond that, what felt wrong, slow or confusing. Timings help most
for the handshake (Part 1), the chain waits (Parts 5–8) and the private split's proofs
(Part 6h).

**Known rough edges** (so you can skip reporting these):
- Nothing mints a LEZ token or funds a vault or group account (`exo-2752`), so the LEZ
  settles in Parts 7–8 are expected to be rejected.
- Room titles last only for the session.
- A FROST card offers **Sign outside muster (PSBT)** with nothing to export.
- A split agreement can reach the other side before the proposal's context does, over
  the fleet: the agreement is refused and has to be tried again (`exo-ca3`; #187 makes
  the card say so and the self-test retry).
- Leave a room before a payment shows **✓ received**, and its report waits until you
  come back (Part 6).

**Reset**

```bash
scripts/try-infra.sh down
```

Then `--fresh` on the next `scripts/try-peer.sh`. Don't `make clean` while the chains
are up: it removes `.run/`, which holds the Bitcoin node's data directory.
