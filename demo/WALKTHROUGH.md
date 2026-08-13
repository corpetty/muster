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

> **⚠️ We reported a bug in the execution zone. There wasn't one.** For two days this section described a settlement failure: the sender debited, the receipt rendered on both sides, and the recipient's balance never moving. The symptom was real and reproduced twice. The diagnosis was wrong, and the zone's team said so on 2026-08-13.
>
> **What is actually true.** What a recipient publishes is not an address — it is a **key pair**, the nullifier and viewing public keys. A private account id is `sha256(prefix ‖ npk ‖ vpk ‖ identifier)`, and the *sender* picks the identifier. So every payment made to you mints a brand-new account under your key pair, and you find your money by scanning for it with your viewing key. There is no reusable string, which is most of what the privacy buys: nothing on the public record ties one payment you received to the next.
>
> "Poll the balance of the id you published" is therefore not a thing a correct client does. The recipient's balance never moved because we were watching the wrong number — an account that, by design, no one was ever going to pay twice.
>
> **Why we believed otherwise, which is the part worth reading.** `wallet_ffi_resolve_private_account` returns `identifier: 0` for every account it owns, because that field is defaulted and never populated. We measured it, believed it, and concluded that accounts are created with one identifier while payments are addressed to another — so the two could never meet. That conclusion was the keystone of the whole report and it was an artifact of a broken field. The header's description of `to_identifier` ("Identifier for the recipient's private account") and a doc comment claiming a random identifier where the code uses zero both pointed the same wrong way.
>
> **Two independent measurements agreed and were both wrong** — a two-peer testnet run and a single-process reproducer — because both read the same defaulted field. Reproducing a result establishes that it happens. It establishes nothing about why. That is the most expensive thing this build has taught us.
>
> **And the fix we chose did real damage.** Believing an account had to be registered before it could be credited, we called `register_private_account` on every fresh private account. That call *initializes* the account, and the initialization nullifier is a hash of the account id alone — so any id can be foreign-initialized exactly once, ever. We made our own advertised account permanently uncreditable by anyone else. The call is gone. The published key pair was never harmed.
>
> The proposed fix we were about to send — publish a fixed identifier with the keys — would have worked for exactly one payment and then been dead forever.
>
> **What stands.** A genuine panic in the wallet library, confirmed upstream with a regression test going in: a send to a destination identifier already in the sending wallet's key chain, with a cached state whose commitment is on chain, trips an `expect`. Plus three API defects that cost us the week and are being fixed. Full exchange in `poc/BUG-private-transfer-recipient-identifier.md` §6.
>
> Two other traps worth knowing, both real and both still true. `lez_core` has a third failure convention: seventeen of its methods return a JSON envelope carrying `success: false` rather than the empty string the others use, so the ordinary check reads a hard failure as success — that could have let a *payment* post a receipt for a transfer the zone had rejected, which is the one thing this app must never do. And the balance read immediately after a transfer is stale: the sender showed 150 → 150 right after the proof and 150 → 140 on the next refresh. The first number is not evidence of anything.
>
> **What the app does now, which is what it did before — only correctly labelled.** After syncing it sums every private account it can find, and spends from the one holding the note. Not a workaround: a scan is what a shielded wallet is. The wallet card still says, beside the number, that the balance includes accounts you never created and that one send draws on one of them. The first of those is now a *protection* in the visibility panel — you have no address that can be reused against you — and only the second remains a gap.

## What this was built on

Three modules the platform already ships — chat, delivery, and the execution zone — plus a forked chat UI and roughly one file of our own logic. The parts that took a day were not the ones I expected: not the encryption, not the payment, but discovering that `nix build` cannot see a QML typo, that the zone reports failure by returning an empty string, and that the generated client caps every call at twenty seconds while a proof needs seven minutes.

That last one is worth a bug report rather than a workaround. The synchronous client takes no timeout parameter, and a UI module cannot reach the raw client to set one — only the asynchronous variant accepts a budget. A transfer that quietly exceeds the default does not fail cleanly; it returns an error while the zone keeps computing, and the result is discarded after the work is done.

## Caveats, in one place

This is a prototype built for a campaign, in a week. It deliberately does none of the things the real client is specified to do: no signed hash-linked log, no effect/materialization split, no independent re-derivation of what gets signed, no replay binding, no verified membership epochs. It depends on two live remote services and has no offline mode, so "local-first" describes the design it is a sketch of, not this build. Details in `README.md` and `GAPS.md`.
