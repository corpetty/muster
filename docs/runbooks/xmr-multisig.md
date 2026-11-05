# Runbook: a Monero multisig the room runs, with your own wallets

**As of 2026-10-30** (ADR-020, exo-dcc.34). Three people set up a 2-of-3 Monero multisig wallet in a Muster room, fund it, and spend from it. Each person's own `monero-wallet-rpc` holds their key and does the multisig. Muster carries the messages between the wallets and asks each wallet to take part. It holds no Monero key. Design: [`docs/design/monero-multisig-coordination.md`](../design/monero-multisig-coordination.md).

> **Read first.**
> - The wallet is your own `monero-wallet-rpc`, not Basecamp's Monero Wallet.
> - Upstream calls Monero multisig experimental: a dishonest member could take the funds.
> - **Stagenet only.** One spend at a time, about 20 minutes each.
> - The wallet will need re-creating after Monero's FCMP++ upgrade.
>
> **Status.** The whole runbook ran on stagenet through the UI on 2026-10-17, with three runners on one machine: set up, funded, spent, and settled on all three cards. Labbook: `docs/labbook/monero-multisig-in-the-room.md` §8. If a wallet keeps saying *no connection to daemon*, point it at another stagenet node (`set_daemon`). Leave out any member who will not join from their own wallet: the setup waits for every member it names.

## 0. Set up, on each of three machines

1. **Muster 0.3.3 or later:** the [latest release](https://github.com/corpetty/muster/releases/latest)'s AppImage, or Muster installed in Basecamp from its catalogue ([`install-from-catalogue.md`](install-from-catalogue.md)). Open Muster before any other messaging app (see [`xmr-payment-request.md`](xmr-payment-request.md) §0.2).
2. **`monero-wallet-rpc` on stagenet, with a fresh, empty wallet.** A wallet that has been used before cannot become a multisig wallet.
   ```sh
   # binaries: https://www.getmonero.org/downloads/ or `nix shell nixpkgs#monero-cli`
   monero-wallet-rpc --stagenet --daemon-address <a stagenet node, host:38081> \
     --rpc-bind-ip 127.0.0.1 --rpc-bind-port 38083 --disable-rpc-login --wallet-dir ~/xmr-msig
   # in another terminal: create the wallet it will use
   curl -s http://127.0.0.1:38083/json_rpc -d '{"jsonrpc":"2.0","id":"0","method":"create_wallet","params":{"filename":"muster-msig","language":"English"}}'
   ```
   Use your own stagenet node if you have one. A remote node sees when your wallet syncs and what it broadcasts. Keep the wallet-rpc running for the whole run. Back up the wallet's seed (`query_key` with `key_type: mnemonic`) before you fund it.
3. **In Muster: Settings → Monero multisig wallet.** Enter `http://127.0.0.1:38083` and save.

## 1. A room with all three

One person opens a room and invites the other two (see [`xmr-payment-request.md`](xmr-payment-request.md) §0b). ✓ All three are members.

## 2. Set up the wallet (about a minute)

1. **One member:** open the room's details, then **Add an account → Monero multisig**. Under **Monero multisig (your own wallet)**, the members are listed; tap any who should not take part (you always do). Set **M** to `2` and press **Set up a 2-of-3 Monero multisig**. You join it as you open it.
2. **The other two:** the setup appears in the same section. Press **Join**.
3. Nobody's wallet is asked anything until all three have joined. Then each wallet runs its rounds as the room carries them. Watch each member's round count go up, and the status line under the setup.
4. ✓ The setup shows one address, **disclosed by 3 of 3**. Check that each wallet shows the same address: `curl -s http://127.0.0.1:38083/json_rpc -d '{"jsonrpc":"2.0","id":"0","method":"get_address"}'`.

If a wallet answers *refused: the wallet is already a multisig wallet* or *advanced past the room*, that member needs a fresh, empty wallet and a new setup.

## 3. Fund it

Send stagenet XMR to the multisig address from any stagenet wallet. Wait 10 blocks (about 20 minutes) before spending: Monero locks a received output for 10 blocks.

## 4. Spend from it

1. **Any member:** in the same section, **Send from the multisig**. Fill in the recipient's address, the amount in XMR, the fee cap (default 0.001 XMR) and a memo, then send.
2. **Two members**, the proposer included if they want to sign: on the card, **Approve**. The first two approvals the room counts are the signers.
3. Then, without anyone pressing anything, the card's **Monero multisig** block counts up:
   1. **Synced**: each signer's wallet exports what the other needs.
   2. **Signed**: the first signer's wallet builds the spend, and the second signs it, each only if its own `describe_transfer` shows exactly the agreed recipient, amount and change, with the fee within the cap.
   3. **Submitted**, then final at 10 confirmations.
4. ✓ The card says final on all three. The recipient's wallet sees the payment.

A spend proposed while another one is in flight waits ("an earlier spend from this wallet") until that one is final.

## Send back: what I need verified

1. [ ] **Setup:** reached one address, disclosed by 3 of 3. How long did it take?
2. [ ] Did every wallet show the same address from `get_address`?
3. [ ] **Spend:** the times from **Approve** to **Submitted**, and from **Submitted** to final.
4. [ ] The **Your wallet:** lines shown during the spend, as the exact text. A screenshot of the card with the Monero multisig block.
5. [ ] Anything that read wrong, stalled or needed a second try. The exact text, please.
6. [ ] Each `monero-wallet-rpc` log, if anything was refused.
