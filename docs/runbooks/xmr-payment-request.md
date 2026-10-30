# Runbook: request, or send, a payment in XMR

**As of 2026-10-16, Muster 0.3.1** (exo-dcc.5, .19, .20, .32). One person asks another for XMR inside a Muster room, or one person sends XMR to another. The payer pays from any Monero wallet. The payment counts only when the payee's own wallet sees it. Every label below was read from the code on 2026-10-16; the code wins over this page. Detail and sources: [`docs/labbook/xmr-payment-request.md`](../labbook/xmr-payment-request.md).

> **A live stagenet payment was made through this on a Logos Dev Club stream in October 2026.** Before that, requesting, agreeing, asking for an address, and the Wallet listing a real stagenet wallet were seen on display in Basecamp 0.3.2. That run is not yet written up against the checklist at the end (`exo-dcc.19`), so this page does not yet show paying and confirming as they look on screen. If you run it, the checklist says what to send back.

**Stagenet only.** Mainnet waits on the Monero stack's threat model (`exo-dcc.8`).

## 0. Set up, on each of two machines

1. **Get Muster**, either way:
   - **The AppImage** from the [`muster-v0.3.1` release](https://github.com/corpetty/muster/releases/tag/muster-v0.3.1). Run `chmod +x Muster-0.3.1-Basecamp-0.3.2-linux-x86_64.AppImage`, run it, and click **Muster** in the sidebar.
   - **Or**, in an existing Basecamp 0.3.2, install from Muster's catalogue ([`install-from-catalogue.md`](install-from-catalogue.md)).
2. **Open Muster before any other messaging app** (Chat, for instance). Basecamp runs one messaging node, and the first app to start it picks the network. Both of you should be on Muster's default, `logos.dev`. Check under **Settings → Advanced**.
3. **The payee's Monero wallet.** In Muster, go to **Wallet → Monero → Install**, then confirm Basecamp's *Use this app?* prompt, then **Install** in Package Manager. You can untick the optional *Monero Node* to use a remote node. Then open **Monero Wallet** from the sidebar and **Create** a wallet on stagenet (or **Restore phrase**). Back in Muster's **Wallet**, it shows as *Monero · stagenet* with its address.
4. **The payer's Monero wallet**: any stagenet wallet holding enough stagenet XMR, such as Feather, Cake, `monero-wallet-cli`, or Basecamp's Monero Wallet set up the same way.
   - **The campaign payer:** its address is `57VTGxT3AW727aC8Df1WfxfkhrxwknsrZe8Wp2zvwCzt6CJvGjjtiW7Wiei8Y6XmGJjeQMHbZ4S5iFF7DbRqwc7dBsJnXeW`. Restore it from its seed (restore height 2205803) once it is funded.

## 0b. Share a room

1. **The payee:** **Needs you → Getting started → Share**, which copies your contact link. Send it to the payer however you like.
2. **The payer:** **Contacts**, add the link. Then **Start something**, pick an activity, put the contact in *Who's doing it with you?*, and **Open the room**.
   - ✓ The payee gets an invitation on **Needs you**. **Join** makes them a member at once, with no asking.
   - If the composer warns *That isn't a chat id*, the invite cannot go: use the contact link.

## 1a. Request a payment (the payee asks)

**The payee:**
1. In the room, **+ → Request a payment**. **Settles on** should read **Split (Monero)**.
2. Type the amount in XMR. ✓ *Bob pays you 0.1 XMR from any Monero wallet, with a link the room gives them.*
3. **Propose.**
   - If Monero Wallet is closed, Muster offers **Open Monero Wallet**, and the wallet asks for its password. Then **Propose** again.
     - *Known rough edge:* the wallet may still answer `failed` (`exo-dcc.21`); act again.
   - Your wallet mints a fresh subaddress for this request, labelled `muster:req-…`. Proposing is your agreement that it is yours.

**The payer:** on the card, **Agree to my share**.

## 1b. Send money (the payer offers)

1. **The payer:** **+ → Send money**. **Settles on** should read **Monero**. Pick who it goes to and type the amount.
   - If they have shared no Monero address in the room, the form offers **Ask <name> for a Monero address**. Press it.
2. **The payee:** on that address-request card, **Share my Monero address**. Your open wallet mints a fresh subaddress and the room sees it.
3. **The payer:** the form now names that address. Press **Send**. Proposing is your agreement.
4. **The payee:** **Accept — <address> is my address**. Your client accepts only while your open wallet lists that address.

A shared address backs only one payment. A second send to it is refused until the payee shares a fresh one.

## 2. Pay — first on screen

**The payer:** the card shows a QR code, the `monero:` link, **Copy link**, and **Pay with Monero Wallet**.
- **From another wallet:** scan the QR or paste the link. It carries the address and the exact amount, nothing else.
- **From Basecamp's Monero Wallet:**
  1. **Pay with Monero Wallet** copies the address and opens the wallet.
  2. In **Send**, paste it as the address and type the exact amount. **Copy amount** puts the amount on the clipboard.
  3. Review, and confirm in the wallet.
- Then, back in Muster, **I paid**. A transaction id is optional. ✓ *"I paid" tells the room; it doesn't confirm anything.*

## 3. Confirm — first on screen

**The payee:** keep Monero Wallet open on that wallet, and keep **this room open** in Muster. A room's payments are confirmed only while it is the open room (`exo-ff5.9`).

✓ Expect, in order:
1. *says they paid — your wallet confirms it at 10 confirmations* (or the depth the request names);
2. *seen, n of 10 confirmations*, once your wallet sees the transfer;
3. confirmed, and final on both sides, at 10 confirmations. That takes about 20 minutes, since Monero makes a block about every two minutes.

Only an incoming transfer to that subaddress, of exactly the amount, at the request's depth or more, confirms it. The depth is 10 unless whoever made the request picked another (1 to 720) under **Counts as paid at this many confirmations**: fewer is faster for a small amount, and the payee carries the risk of a reorg. The payer's word, a txid, or an explorer never does. **Mark received** is the other way to finish: your word, recorded with no reference.

## 4. The receipt

On the final card, **Details → Download audit trail**. The file verifies from itself alone. From a checkout of this repo, `module/tools/muster_audit_verify.nim` checks it. Its report says who reported paying and that your wallet confirmed it.

## What each party learns

- **The Monero chain** shows no sender, receiver or amount, and a subaddress cannot be linked to the payee's other addresses.
- **The room** holds the request, the people, and any txid reported. None of it leaves the room.
- **A remote node** sees when a wallet syncs and the transactions it broadcasts, unless you run your own (Monero Wallet's optional *Monero Node*). From the next release, Muster's **Connections** row says which one the payee's wallet uses.
- **Any module loaded beside Muster in Basecamp** can read the payee's wallet history while it is open. The action's manifest discloses this.

## Send back: what I need verified (exo-dcc.19)

Note each item, with a screenshot where it says so:
1. [ ] **Invite and join** (0b): the payee joined without asking. Did *Join* work across the two machines?
2. [ ] **Request** (1a) or **Send** (1b) reached *payable* on both sides. A screenshot of the payer's card with the QR.
3. [ ] **Paying:** which wallet, and did it read the link (QR or paste)? If you used **Pay with Monero Wallet**, did the address-and-amount paste work?
4. [ ] **Before the first block:** did the payee's card show *seen, 0 of 10* while the payment was still unconfirmed, or only after the first block? This is the spike question: does an incoming transfer show in `history()` before it confirms?
5. [ ] ***seen, n of 10*** counting up. A screenshot at some n.
6. [ ] **Final on both sides at 10.** The time from **I paid** to final.
7. [ ] **The receipt:** it downloads. If you can, send me the file and I'll run the verifier on it.
8. [ ] **First sync:** how long a fresh stagenet wallet took to sync in Monero Wallet (the other spike question).
9. [ ] Anything that read wrong, stalled, or needed a second try. The exact text, please.

Self-test without a wallet: `scripts/split-xmr-self-test.sh`. The paid path is held by the spec's probes (`scripts/grade-specs.sh exo-dcc.5`).
