# Sending someone money inside a conversation

*A working prototype on the Logos stack, August 2026. Draft source for the testnet v03 campaign. Everything below was run; where something is broken, it says so.*

---

Two people. One wants to pay the other. Nothing else — no marketplace, no escrow, no multisig. It is the smallest complete transaction there is, and running it end to end on Logos turns out to be a good way to find out what the stack actually does today.

Here is the whole thing, in the order it happens.

## 1. Finding each other

Alice opens the app and it hands her an address. Not an account she registered, not a name she reserved, not a phone number she confirmed — an address her own machine minted, a couple of seconds after launch, having asked nobody's permission.

She sends it to Bob however she likes. Signal, a QR code across a table, a business card.

Bob pastes it into **New chat**. The conversation opens on both sides.

**What just happened, precisely:** nothing was looked up. There is no directory to query, so there is no query for anyone to observe, and no service that now knows Alice and Bob are talking. Compare a conventional stack, where "add contact" is a request to a server that learns the edge of a social graph and keeps it.

**What still leaks:** the transport carries the conversation over content topics, and a store node can see which topics a client subscribes to and when it publishes or fetches. That is the conversation graph — pseudonymously, but it is the graph. End-to-end encryption does not touch it. Closing it needs a mixnet at the transport layer; `LOGOS-MIXNET` is specified at status `raw` with a send-only proof of concept, and is not on the near-term roadmap. Running your own store node does not fix it — that protects the operator's metadata, not the metadata of the people they talk to.

**And the bootstrap is the weak point.** The address exchange happens out of band and is unauthenticated. If the channel Alice used to send her address is compromised, the attacker *is* the conversation. Muster cannot fix that; it can only avoid making it worse.

## 2. Talking

Ordinary messages, end-to-end encrypted by the chat module.

Worth stating plainly because it is unusual: **this prototype contains no cryptography of its own.** The structured cards below are JSON inside the ordinary message body, so they inherit exactly the protection that text does. There was no temptation to hand-roll anything, because the platform module already does it.

## 3. Asking where to pay

Bob taps **+** in the composer. A card appears in both threads: *Asked for an address.*

On Alice's side the card carries a button — **Share my address**. One tap.

This is the part that felt different to build. In every wallet flow I have used, "where do I send it" is a trip out of the conversation: switch apps, copy a string, come back, paste, squint at the first and last four characters. Here the ask and the answer are messages, in the thread, in order, where the agreement already lives.

## 4. The address is shielded

What Alice's client sends back is not an account number. It is a shielded receiving key set — a destination that an outside observer cannot associate with a payment.

There is a second option sitting right next to it in the same module, and the contrast is the most interesting thing in the whole build. The execution zone also ships an **on-chain label system**: register a human-readable name, and anyone can resolve it. It is genuinely nicer to use. It is also a public directory, the lookup is a public act, and the mapping is permanent. Same stack, two discovery models, real costs on both sides. Neither is the right answer in general; which one is right depends on whether you would rather be findable or unlinkable.

## 5. Paying

Alice's card offers **Send LEZ**. The dialog asks for an amount and nothing else — the recipient came from Bob's card, so there is no address bar to paste the wrong thing into. That is a small thing that removes an entire category of mistake.

She confirms. The zone starts proving.

**This takes six minutes and forty-one seconds, at about 1300% CPU.** Measured, on a thirteen-core desktop, for a single-note transfer. That is the honest price of the privacy claimed here, and it is worth publishing rather than eliding, because it changes what the feature *is*: a private payment is not an interaction you wait on, it is a job you start. It also bounds what a demo can show — you cannot screen-record it in real time.

When it lands, a receipt card appears in the thread on both sides: *100 LEZ, private → private, nothing on-chain names either side.*

## 6. Where it is broken

> **⚠️ Known bug, cause found, reported upstream, not yet worked around here.** The sender is debited and the receipt renders on both sides, but **the recipient's balance never moves.**
>
> Measured properly, with both peers freshly minted and both private accounts registered on-chain — confirmed by transaction hash, not by the absence of an error. The sender paid 10 of her 150. The zone proved for 7.4 minutes and returned success with a transaction id. She went 150 → 140. He went 0 → 0, re-read five times with a full sync each, over several minutes.
>
> The leading hypothesis — that a private account must be registered before it can be credited — **was wrong**. The real cause is worth stating precisely, because it is a good illustration of a privacy property and a usable interface pulling against each other.
>
> A private account id is derived from the recipient's viewing key **and an identifier**. The keys a recipient can hand out carry no identifier, so the zone's client picks one *at random* for every payment. The note lands at an account derived from a number the recipient has never seen. Enumerate their wallet afterwards and it is right there — the account they advertised holding nothing, and a brand-new account holding exactly what was sent:
>
> ```
> private 021fbfac…4634 balance=0    <-- advertised, registered, polled
> private b719ff50…259a balance=10   <-- the payment
> ```
>
> Nothing was lost. It arrived somewhere they had no reason to look. Reported upstream with a single-file reproducer that links the wallet library directly — no chat, no second peer, no app — in `poc/BUG-private-transfer-recipient-identifier.md`.
>
> Getting to that answer meant clearing three things that were hiding it, each worth knowing on its own. `register_private_account` *proves*, so through the generated sync client it hit a hardcoded 20-second timeout and had never once succeeded. It also demands an uninitialized account, so it works at creation or never — a peer minted by an older build cannot be repaired, only replaced. And `lez_core` turns out to have a third failure convention: seventeen of its methods return a JSON envelope carrying `success: false` rather than the empty string the others use, so the ordinary check reads a hard failure as success. That last one meant a failed shielding step reported nothing at all — and could have let a *payment* post a receipt for a transfer the zone had rejected, which is the one thing this app must never do.
>
> One trap for anyone repeating this: the balance read immediately after a transfer is stale. The sender showed 150 → 150 right after the proof and 150 → 140 on the next refresh. The first number is not evidence of anything.
>
> **This section becomes a fix note before publication, not a deletion.** The honest claim today is that everything up to and including *initiating* a private payment works, and that the recipient's client cannot see the money — which, for a user watching their balance, is indistinguishable from not being paid.
>
> There is a workaround open to us: enumerate accounts after syncing and treat new private accounts as received notes, rather than polling the one id we published. It would complete the journey. It should ship labelled as a workaround with the upstream issue beside it, because "your balance is the sum of accounts you did not create" is exactly the sort of thing this document exists to disclose rather than smooth over.

## What this was built on

Three modules the platform already ships — chat, delivery, and the execution zone — plus a forked chat UI and roughly one file of our own logic. The parts that took a day were not the ones I expected: not the encryption, not the payment, but discovering that `nix build` cannot see a QML typo, that the zone reports failure by returning an empty string, and that the generated client caps every call at twenty seconds while a proof needs seven minutes.

That last one is worth a bug report rather than a workaround. The synchronous client takes no timeout parameter, and a UI module cannot reach the raw client to set one — only the asynchronous variant accepts a budget. A transfer that quietly exceeds the default does not fail cleanly; it returns an error while the zone keeps computing, and the result is discarded after the work is done.

## Caveats, in one place

This is a prototype built for a campaign, in a week. It deliberately does none of the things the real client is specified to do: no signed hash-linked log, no effect/materialization split, no independent re-derivation of what gets signed, no replay binding, no verified membership epochs. It depends on two live remote services and has no offline mode, so "local-first" describes the design it is a sketch of, not this build. Details in `README.md` and `GAPS.md`.
