# Running the two-peer demo

The whole journey — two people meet, one asks the other for an address, and pays it — with both peers on one machine.

## Once

```bash
cd demo
make app        # builds the standalone runner. The slow one; everything else is seconds.
```

Nothing else to install. There is no Basecamp, no package manager and no chain to sync: `chat_module` joins the public `logos.test` delivery network and `lez_core` is a client of the LEZ testnet sequencer.

## Every run

Two terminals:

```bash
make alice      # terminal 1
make bob        # terminal 2
```

Each peer keeps its chat identity *and* its wallet under `.run/<name>/`. They are deliberately in the same place: one peer is one directory, and `make clean-peer PEER=alice` resets both together. Two peers that shared a directory would share an identity, which would make any recording a lie.

## The journey

1. **Wait for Online.** Both peers' account cards read `Online` once delivery connects — a couple of seconds. Nothing works before that, and the app says so rather than failing on the first action.
2. **Open the wallets.** `Open wallet` on each. The first time, this mints a wallet and a private account; afterwards it opens the existing one. The stage label names what it is doing.
3. **Fund at least the payer.** `Fund` claims from the zone's proof-of-work faucet: the app solves the puzzle, claims 150, then shields the prize into the private account. Watch the public balance appear and then move to private — that hop is the demo in miniature.
4. **Meet.** Copy Alice's address from her account card (the copy button flashes *Copied*), paste it into Bob's **New chat**. The conversation opens on both sides. *This is the discovery step: no directory, no lookup, no server that learns they met.*
5. **Ask for an address.** In the conversation, the **+** beside the send button asks the peer where to pay. A card appears in both threads.
6. **Share it.** On the receiving side the card has **Share my address**. One tap replies with a shielded receiving key set — not an account number, a destination nobody else can associate with a payment.
7. **Pay.** That card offers **Send LEZ**. The dialog asks only for an amount, because the recipient came from the card. Confirm.
8. **Wait.** The zone is proving; the wallet reads `sending` for as long as it takes. This is real zero-knowledge work, not a spinner.
9. **Receipt.** A receipt card lands in the conversation for both. Refresh balances to see them move.

## When it goes wrong

- **Stuck at `Initialising`** — `logos.test` is unreachable. The demo needs the public delivery network; there is no local mode.
- **`Open wallet` errors** — the LEZ sequencer (`testnet.lez.logos.co`) is not answering. Nothing local will fix it.
- **First sync is slow** — the wallet walks to the chain tip in chunks and the stage label counts them. It is working; leave it.
- **A payment fails with insufficient funds right after funding** — the wallet had not seen the note yet. `Refresh`, then retry.
- **A peer looks wedged** — logs are under `.run/<peer>/module_data/chat_module/<id>/`, and the app's own **Session logs** dialog lists them.
- **The wallet fails and the card's reason is vague** — the zone logs its real reason to the *app's* stdout, not to the view's log. Grep the terminal you launched from for `[lez_core]`; that line names the actual cause. See `../docs/labbook/lez-core-error-conventions.md`.
- **A peer created by an older build will not open its wallet** — it has a config the zone cannot read. The app now deletes and replaces it automatically; `make clean-peer PEER=<name>` also clears it, at the cost of a fresh identity.

## What to say while recording

The honest framing, which is also the interesting one:

- The conversation is end-to-end encrypted by `chat_module`, and the payment cards ride *inside* it as ordinary messages. **This demo adds no cryptography of its own.**
- The payment is private on both ends — shielded to shielded. The amount and both accounts stay off the public record.
- What is *not* hidden: a store node still sees which topics a client subscribes to and when it publishes, so it learns the conversation graph even though it cannot read a word. Closing that needs a mixnet at the transport layer, not an application change. Say this at the discovery step, where it applies.
- The zone still learns that a transfer happened and when, even though it learns nothing about who or how much.

See `../docs/00-vision.md` for the rule these claims answer to, and `README.md` for what this build deliberately does not do.
