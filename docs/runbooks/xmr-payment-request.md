# Runbook: request a payment in XMR

**As of 2026-10-09 (exo-dcc.5, exo-dcc.20).** One person asks another for XMR inside a Muster
room. The payer pays from any Monero wallet. The payment counts only when the payee's own
wallet sees it. Every label below was read from the code on 2026-10-09; the code wins over
this page. Detail and sources: [`docs/labbook/xmr-payment-request.md`](../labbook/xmr-payment-request.md).

> **No payment has been made through this yet.** Steps 1 and 2, and asking for an address,
> were seen on display in Basecamp 0.3.2 with a real stagenet wallet. Steps 3 and 4, a real
> payment and its confirmation, are first on screen: the two-machine run is `exo-dcc.19`, and
> it waits on stagenet XMR for the payer. What you see there is the finding.

**Stagenet only.** Muster requests on Monero stagenet. Mainnet waits on the Monero stack's
threat model (`exo-dcc.8`).

## What you need

**The payee** (the person asking to be paid):
- Logos Basecamp 0.3.2, with Muster installed from its catalogue
  ([`install-from-catalogue.md`](install-from-catalogue.md)) and **Monero Wallet Backend**
  left ticked.
- **Monero Wallet** (`monero_wallet_ui`), with a stagenet wallet in it. If it is missing, the
  card offers **Install monero_wallet_ui**, and Basecamp's own dialog does the install.

  The standalone runner (`make run`) bundles no Monero wallet, so it cannot be the payee.

**The payer:**
- Muster, in Basecamp or the standalone runner. Muster needs no wallet on this side.
- Any Monero wallet on stagenet, holding enough stagenet XMR: Cake, Feather,
  `monero-wallet-cli`, or Basecamp's own Monero Wallet.

**Both** in one Muster room. Start one from **Home → Start something**, and invite the other.

## 1. Request

**The payee:**
1. **Home → Start something → Request a payment**, or in a room you share, **+** →
   **Request**. **Settles on** should read **Split (Monero)**.
2. Type the total in XMR. Choose who pays, if the room has more than one other person.
   ✓ Expect a line like *Bob pays you 0.1 XMR from any Monero wallet, with a link the room
   gives them.*
3. **Propose.**
   - If your Monero wallet is closed, Muster says so and offers **Open Monero Wallet**.
     Basecamp asks *Use this app? Muster wants to monero.wallet.unlock*; Monero Wallet asks
     for the wallet's password. Then **Propose** again.
     *Known rough edge:* Monero Wallet answers `failed` even after it opened the wallet
     (`exo-dcc.21`), so the warning stays until you act again.
   - With the wallet open, your wallet mints a fresh subaddress for this request, labelled
     `muster:req-…`. You never type an address.

Proposing is your agreement that the address is yours.

## 2. Agree

**The payer:** on the card, **Agree to my share**. There is no link to pay until every party
has agreed.

## 3. Pay — first on screen

**The payer:** the card shows a QR code, the `monero:` link as text, and **Copy link**.

1. Scan the QR, or paste the link, in your Monero wallet. The link carries the address and
   the exact amount, nothing else: no description and no name. The memo stays in the room.
2. Send exactly that amount, to exactly that address.
3. Back in Muster, **I paid**. A transaction id is optional.
   ✓ Expect *"I paid" tells the room; it doesn't confirm anything.*

## 4. Confirm — first on screen

**The payee:** keep Monero Wallet open on that stagenet wallet, and keep the room open in
Muster. A room's payments are confirmed only while it is the open room (`exo-ff5.9`).

✓ Expect, in order:
- *says they paid — your wallet confirms it at 10 confirmations*, once the payer says so;
- *seen, n of 10 confirmations*, once your wallet sees the transfer;
- the part confirmed, and the request final on both sides, at 10 confirmations. Monero makes
  a block about every two minutes, so allow about 20 minutes.

Your wallet confirms only an incoming transfer to that request's subaddress, of exactly the
amount asked, at 10 confirmations or more. The payer's word, a txid alone, or a block
explorer never confirm it.

**Mark received** is the other way to finish: your word that you were paid, recorded with
no reference.

## Asking on someone's behalf

Bob can propose a split in XMR that pays Alice, the one who paid the bill:

1. **Bob:** **+** → **Split** → **Split (Monero)**, **Who paid the bill?** → Alice. Until
   she has shared a Monero address in the room, the composer offers **Ask Alice for a Monero
   address**.
2. **Alice:** on the address-request card, **Share my Monero address**. Her wallet mints a
   fresh subaddress, and the room sees it.
3. **Bob:** **Propose**.
4. **Alice:** **Agree — I paid, and <address> is mine**. Her client agrees only while her open
   wallet lists that address.

## What each party learns

- **The Monero chain** shows no sender, receiver or amount. A subaddress is not linkable to
  the payee's other addresses. This is Monero's guarantee; the card says so.
- **The room** holds the request, the link between the payment and the people, and any txid
  someone reported. None of it leaves the room.
- **The payer's remote node** sees their wallet's sync unless they run their own node or go
  through a proxy.
- **Any module loaded beside Muster in Basecamp** can read the payee's wallet history and
  subaddresses while the wallet is open. The action's manifest discloses this.

## Known rough edges

- Monero Wallet answers `failed` to an unlock it carried out (`exo-dcc.21`). Act again.
- Several shares paid to one subaddress must differ in amount, so equal shares are refused.
- "seen, n of 10" has not been seen with a real payment yet (`exo-dcc.19`).

Self-test without a wallet: `scripts/split-xmr-self-test.sh` drives the refusals and remedies
through the real runner, offscreen. The paid path is held by the spec's probes
(`scripts/grade-specs.sh exo-dcc.5`).
