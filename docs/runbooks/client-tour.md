# Runbook: tour the client — everything new, hands-on

**As of 2026-09-28 (main after #167).** Two instances on one machine, driven by you,
through everything the client gained recently. Most of it has been proven only by tests
until now. Some steps are the **first time anyone does them on screen**; those are marked
**🆕 first on screen**. What you see there is the finding.

Every label, command and setting below was read from the code on 2026-09-28. The code
wins over this page. If a label differs, note it: that is a finding too. **Known rough
edges** are listed where you will meet them, so you can tell a known issue from a new one.

| Part | What | Needs | Time |
|---|---|---|---|
| 0 | Build, launch two peers | Nix; network access to the Logos fleet | 10 min (+ first build) |
| 1 | Rooms that name nobody | — | 5 min |
| 2 | Chat and who said it | — | 2 min |
| 3 | A decision the room signs | — | 10 min |
| 4 | A Safe payment, settled on chain | anvil | 15 min |
| 5 | Bitcoin through a FROST key 🆕 | bitcoind regtest | 20 min |
| 6 | The LEZ multisig on the public testnet 🆕 | internet; ~40 s blocks | 20 min |
| 7 | LEZ FROST 🆕 | internet | 10 min |
| 8 | Wallet and Send λ | — | 5 min |
| 9 | The walkthrough and the atlas | a browser | 5 min |

Older, still-valid runbooks cover what this one skips. [`../manual-test-runbook.md`](../manual-test-runbook.md)
covers the surfaces, multi-room, the dashboard and Settings.
[`transaction-lifecycle-demo.md`](transaction-lifecycle-demo.md) is the talk-track version.
[`../two-party-demo-runbook.md`](../two-party-demo-runbook.md) covers two machines.

---

## 0. Build and launch two peers

```bash
git pull --ff-only
```

```bash
make build
```

The first build takes minutes. It builds the committed module, and warns if `module/`
has uncommitted edits.

**Both peers must run this build.** Since #167 the wire format changed: join requests,
key grants and envelopes are all sealed differently. An older build, the
`v0.1.0-demo` AppImage included, cannot share a room with this one in either direction.

Start from fresh identities so seeding applies. Seeding is honoured only when an identity
is first minted.

```bash
make clean-peer PEER=alice
```

```bash
make clean-peer PEER=bob
```

Then run one peer per terminal:

```bash
make run-fleet PEER=alice
```

```bash
make run-fleet PEER=bob
```

**✓ Expect**
- Two windows, each on the public `logos.test` fleet.
- Alice is seeded as anvil Safe owner 0 and Bob as owner 1. Each already has the other,
  and Carol, as named contacts.
- The nav bar reads **Home · Room · Account · Walkthrough · Settings · Contacts · Send λ**.

> Running one instance alone? `make run` now seeds you as owner 0 (fixed in this PR — the
> seed never applied before). `make run SEED=` opts out; `make run SEED=0x…` picks a key.

Your own chat id is in **Settings → YOUR CHAT ID** (128 hex, with **Copy**). You won't
need it here, because the contacts are pre-seeded.

---

## 1. Rooms that name nobody (exo-661.7)

What changed. Everything on a room's content topic is readable by any store node and any
subscriber. Until #167 the topic itself gave away:

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
*Your ask is sealed and sent*. The room header shows the room's title
(`Room · talk · with …`), not its topic.

**Known rough edges**
- Titles are session-only; after a restart, Home and the header show the topic.
- Auto-admit works only while Alice stays in the room she just composed. After she
  re-opens it from Home, admit by hand.

---

## 2. Chat and who said it (exo-f76)

In the shared room, type in **Say something** and press **Send**, from each side.

**✓ Expect**
- Your own messages are labelled **you**.
- The other side's messages carry the contact alias, then the timestamp (raw unix
  seconds).

What changed. Messages, declines, material shares, account disclosures and FROST joins
now carry their author's signature. An event whose signature doesn't verify is dropped
from every view. **Nothing on screen shows this.** There is no "signed" badge, and a
dropped forgery leaves no trace. The screen shows only correct names. The proof is
`authorship_test`.

---

## 3. A decision the room signs (no chain)

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
   module proves from the log and her keys that she approved (exo-59c). On Bob's side the
   same line reads **by Alice**.
4. **Bob: Approve.** ✓ Expect **2 of 2**, **by Alice, you** on Bob's side, then the ready
   box: **✓ Endorsed — a signed group decision. Nothing settles on-chain.** A member
   counts once however many times they sign (exo-a5a): one signature published under two
   names used to count twice. That can't be done from the UI; `distinct_signer_test`
   proves it.
5. **Room history** (right column) reads *Approved by Alice*, *Approved by you*. Open **Who can
   see what** and try **Show per-action rows**.
6. Propose a second statement. **Bob: Deny.**
   ✓ Expect the card to show **1 declined: Bob** (on Bob's side, **you**). The history line
   reads *Declined by Bob — chose not to take part — the threshold is unchanged*.
7. **Governance.** In *Endorse with*, click **＋ Propose unanimous** and approve it on both
   sides. ✓ Expect a **Unanimous** button to appear. The room admitted a new policy by
   vote.

**The audit trail.** On any card, click **Download audit trail**. ✓ Expect: *Saved …
(verifies on its own) and a readable report beside it*, written to `~/Downloads` (or
`$MUSTER_AUDIT_DIR`). Check it with nothing but the file, in bash:

```bash
bash -c 'P=$(module/tools/nim-closure.sh); SODIUM=$(nix build nixpkgs#libsodium --no-link --print-out-paths | head -1); cd module && nim c -d:release --hints:off --threads:on --path:$P/nim-secp256k1 --path:$P/nim-stew --path:$P/nim-results --path:$P/nimcrypto --path:$P/nim-stint --path:$P/nim-intops/src --passL:"$SODIUM/lib/libsodium.so" -o:../muster-audit-verify tools/muster_audit_verify.nim'
```

```bash
./muster-audit-verify ~/Downloads/muster-audit-<id>.cbor --report
```

✓ Expect `"ok": true`, the approvals by name, and exit code 0. Edit one byte of the file
and the verifier refuses it (exit 1).

---

## 4. A Safe payment, settled on chain (anvil)

**Setup.** In a third terminal:

```bash
nix shell nixpkgs#foundry nixpkgs#jq nixpkgs#git -c infra/anvil/devnet.sh
```

✓ Expect `SAFE_ADDR=0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841` and `RPC=http://127.0.0.1:8545`.
It is a real Safe v1.4.1, 2-of-3 over anvil owners 0/1/2, funded with 5 ETH. Anvil keeps
running after the script exits; stop it later with `pkill anvil`.

1. **Alice:** in **Accounts** (right column), click **Disclose the local test Safe**.
   ✓ Expect the row **Local test Safe (anvil) · 2 of 3**, then `evm.safe · eip155:31337 · …`,
   **the chain agrees**, and (new) the whole address with **Copy address**.
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
6. **Open "What this needs"** (exo-ec8, precise names).
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

   Nothing should say `chain:31337` or `safe:0x…`.

   ✓ Expect *anyone reading the chain* to see **to, value, data, operation, nonce, gas,
   payer, policy, signers**, and *your RPC provider* the **signed-tx**.
7. **Approve on both.** ✓ Expect **✓ Ready — the approvals are collected.** and
   **Settle on-chain**.
8. **Settle on-chain.** ✓ Expect **✓ Settled on-chain (final)**. Confirm with the chain
   itself:

   ```bash
   nix shell nixpkgs#foundry -c cast balance 0x90F79bf6EB2c4f870365E785982E1f101E93b906 --rpc-url http://127.0.0.1:8545
   ```

   The balance is 10000.001 ETH in wei: anvil's 10000 plus your 0.001.

**Optional:** *Endorse with* **Attest** (EIP-191) acts from the same Safe.
✓ Expect *✓ a recognized attester (a Safe owner)*.

The history reads *Submitted on-chain — the Safe execTransaction was sent through your
RPC*, then *Settled on-chain — final — the payment landed*. A settle still pending after
the first ~4 s keeps being watched, and turns final when the receipt lands.

---

## 5. Bitcoin on regtest 🆕 first on screen

Two ways to hold Bitcoin together:
- **5a**, a classic multisig (P2WSH `sortedmulti` or taproot `multi_a`) built from each
  member's key;
- **5b**, a FROST key made by a ceremony, whose spend settles as a single 64-byte
  signature.

**Setup.** In a terminal:

```bash
nix shell nixpkgs#bitcoind -c infra/bitcoind/regtest.sh
```

✓ Expect `RPC=http://127.0.0.1:18443 USER=muster PASSWORD=muster`. Every start is a fresh
chain; `infra/bitcoind/regtest.sh stop` stops it.

**Both peers:** **Settings → Bitcoin node** → `http://muster:muster@127.0.0.1:18443` →
**Save**.

Keep a bash shell open for the node:

```bash
nix shell nixpkgs#bitcoind -c bash
```

```bash
bcli() { bitcoin-cli -regtest -rpcuser=muster -rpcpassword=muster -rpcport=18443 "$@"; }
bcli createwallet miner
M=$(bcli getnewaddress); bcli generatetoaddress 101 "$M" >/dev/null
R=$(bcli getnewaddress); echo "$R"
```

### 5a. A Bitcoin multisig

1. **Both:** **Settings → YOUR BITCOIN KEY** → **Copy**. Paste Bob's key into the chat for
   Alice.
2. **Alice:** **Accounts → Bitcoin multisig**.
   - Pick **P2WSH** (or **Taproot**).
   - Set **k** `2`, network `regtest`.
   - Paste both keys, comma-separated, then **Disclose this Bitcoin multisig**.
   - ✓ Expect a `btc.p2wsh-sortedmulti · bip122:0f9188f1… · bcrt1q…` account, **2 of 2**.
     Its address is derived from the keys.
3. **Fund it:** **Copy address**, then:

   ```bash
   bcli sendtoaddress <paste> 1.0 && bcli generatetoaddress 1 "$M" >/dev/null
   ```

4. **Alice:** **+** → **Payment** → *Settles via* **Bitcoin (P2WSH)** → pick the account.
   - Recipient: `$R`. The placeholder now asks for a Bitcoin address.
   - **amount (sat)** `40000000`, **fee** `2`, then **Propose**.
   - ✓ Expect the card: **Proposed a Bitcoin payment**, `40000000 sat → bcrt1q…`. Change
     back to the account is not counted as a payment.
5. **Both: Approve** (in-app DER signatures), or try **Sign outside muster (PSBT)** on one
   side: copy the PSBT, sign it in Core, and **Import** it.
6. **Settle on-chain**, then mine a block:

   ```bash
   bcli generatetoaddress 1 "$M" >/dev/null
   ```

   ✓ Expect *Broadcast to Bitcoin*, then *Confirmed on Bitcoin* in the history, and the
   ready box turns final.

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
bcli sendtoaddress <paste the FROST address> 1.0 && bcli generatetoaddress 1 "$M" >/dev/null
```

**Spend it**
1. **Alice:** **+** → **Payment** → *Settles via* **Bitcoin (FROST)** → pick the FROST
   account under *From*.
2. Recipient: the `$R` address.
3. **amount (sat)** `40000000`, **fee (sat/vB)** `2`, then **Propose**.
4. On the card, ✓ expect **round 1 of 2**.
   - **Open "What this needs"**: expect `environment: bip122:0f9188f13cb7b2c71f2a335e3a4fc328`,
     `infra: bitcoind-rpc` and `authority: frost-share`. Touches name each coin spent as
     `utxo:<txid>:<vout>`.
5. **Both: Approve once.** Round 2 follows on its own.
   ✓ Expect the header to move to *2 rounds complete*.
6. **Settle on-chain** 🆕. Then mine a block:

   ```bash
   bcli generatetoaddress 1 "$M" >/dev/null
   ```

   Check the recipient:

   ```bash
   bcli getreceivedbyaddress "$R"
   ```

   ✓ Expect `0.40000000`. Also look up the spend transaction (`bcli getrawtransaction
   <txid> 1`). Its witness should be **one 64-byte signature**, the same as a
   single-signer taproot spend.

**Known rough edge:** **Sign outside muster (PSBT)** appears on a FROST card, but a FROST
key has no outside format.

---

## 6. The LEZ multisig on the public testnet 🆕 first on screen

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
   - **`infra: lez-rpc`**, not `lez_core` (exo-ec8)
   - `authority: lez-multisig-member`

   **Touches** names the proposal account and every account the proposal passes (write),
   plus the program it calls (read), all as `lez:testnet:<id>`.
5. **Bob: Approve.** This is your own on-chain vote.
   ✓ Expect *⏳ Your vote is on its way to the chain — it counts once a block includes it.*
6. **Settle on-chain** 🆕. ✓ Expect *⏳ Executing on chain*. **The execution is expected
   to be rejected** unless the vault holds that token. Nothing in the app mints a token or
   funds the vault yet (`exo-2752`). What you're judging here is the propose-and-vote experience.

---

## 7. LEZ FROST 🆕 first on screen

This is the Part 5 ceremony, but on the LEZ. Set **network** `lez:testnet`. The group's
key then owns a LEZ public account directly, with no tweak.

1. Run the ceremony. ✓ Expect a LEZ FROST account to be disclosed.
2. **+** → **Payment** → **LEZ (FROST)** → recipient + amount → **Propose**.
3. ✓ Expect **Approve** and **Deny** on the card. Until #166 this card was "schema
   unknown", with no way to approve.
4. Approve once on each side. Round 2 follows.
5. **Settle on-chain** is expected to be **rejected**: the group account holds nothing,
   and nothing in the app funds it.

---

## 8. Wallet and Send λ (no infra)

- **Account → WALLET:** **Refresh balances**. The badge always reads *attested*: the
  verified read isn't wired to this card yet.
- **Send λ:** under *YOUR ADDRESSES — SHARE ONE TO BE PAID*, **Copy** one. Use it (or
  one of the other peer's) as the recipient with an amount, then click **Preview** and
  **Send**.
  - ✓ Expect *Rail: … · public record: …*, then *✓ sent on the … rail*.
  - The rail follows the address form. A public id sends in public; a `priv:npk:vpk` key
    travels shielded, and the preview says which fields reach the public record.
  - Without `MUSTER_LEZ_REAL=1` this runs on an in-process fake LEZ whose demo accounts
    are funded. It's the whole flow with nothing to set up, but each instance has its own
    fake chain, so the other peer won't see the payment arrive.

---

## 9. The walkthrough and the atlas

- **Walkthrough → Open the room.**
  - New PROTECTS claim: **Nothing on the room's topic says who is in it** (FS-7,
    `store_node_view_test`, imperative).
  - The store-node GAP claim now says exactly what remains visible: topic, timing, size,
    frame kind.
- **<https://corpetty.github.io/muster/atlas/>** → **Actions**.
  - `room/admit-member` describes the sealed request and grants.
  - `room/join`: the random topic.
  - `sui.multisig/rekey-by-alias` is new.
  - The registry corrections (exo-a70) are live.

---

## What to report

For each part: ✓, or what you saw instead. For 🆕 steps, what you saw even if it looks
right. Beyond that, what felt wrong, slow or confusing. Timings help most for the
handshake (Part 1) and the chain waits (Parts 4–7).

**Known rough edges** (so you can skip reporting these):
- Nothing mints a LEZ token or funds a vault or group account (`exo-2752`), so the LEZ
  settles in Parts 6–7 are expected to be rejected.
- Room titles last only for the session.
- A FROST card offers **Sign outside muster (PSBT)** with nothing to export.

The fourteen rough edges the first version of this runbook listed are fixed (`exo-59c`),
except the LEZ funding, which is now its own feature (`exo-2752`).

**Reset**

```bash
make clean-peer PEER=alice
```

```bash
make clean-peer PEER=bob
```

```bash
nix shell nixpkgs#bitcoind -c infra/bitcoind/regtest.sh stop
```

```bash
pkill anvil
```
