# What this demo protects, and what it doesn't

Source material for the week-one *Discovery* article. Every row follows the rule in `../docs/00-vision.md`: name what is protected and which mechanism does it, name what leaks and to whom, then name the specific thing that would close the gap **and that thing's real status** — `shipped`, `specified`, `partial`, or `none`. "Coming soon" is not a status.

**Confidence marking.** This was written from the build in this repo on 2026-08-11. Rows marked **[verified]** were observed on this machine. Rows marked **[from source]** are read off the code or contracts of the modules we consume but not separately exercised. Rows marked **[inferred]** are reasoned from design and should be checked before they appear in print. Do not publish an `inferred` row as fact.

---

## 1. Finding each other

**What happens:** Alice copies her chat address from the account card; Bob pastes it into New chat. The conversation opens.

**Protected.** There is no directory, no registry, and no lookup service. Nobody is asked who they want to talk to, so nobody learns it. The address is minted locally by `chat_module`. **[verified — the app reaches `delivery is online` and mints an address with no account, signup or server call.]**

**Leaks.**
- The bootstrap is **out of band and unauthenticated**. Whatever channel carries that address — Signal, a QR code, a conference badge — is the weak link, and if it is compromised the attacker becomes the conversation. Muster cannot help here; it can only avoid making it worse. **[inferred from design — no in-band verification exists in this build.]**
- A store node sees which content topics a client subscribes to and when it publishes or fetches. That is the conversation *graph*, pseudonymously — who talks to whom, and when — and end-to-end encryption does not touch it. **[from source — this is the documented shape of one-topic-per-conversation delivery; not separately measured here.]**

**What would close the graph leak:** a mixnet at the transport layer. Not an application change, and not Tor — Tor hides *who by IP*, not *what links to what*.
**Status: `specified`, early.** `LOGOS-MIXNET` exists as a LIP at status `raw` — the earliest lifecycle stage, its own rationale section reading "To be defined" — with a real supporting body of work (LIBP2P-MIX, cover traffic, LIONESS, RLN). The implementation is a testnet proof of concept, **integrated into send only**; receive over mix is not there. It is not on the published near-term Messaging roadmap. *(Carried from `docs/00-vision.md`, dated 2026-08; re-check before publishing.)*

**Running your own store node is not a fix.** It protects the operator's own metadata, not that of the people they talk to, and it inverts the threat: an operator who serves content from their own node learns when a target fetches it.

---

## 2. Talking

**What happens:** ordinary messages, and Muster's structured cards, travel the same path.

**Protected.** `chat_module` provides end-to-end encryption (MLS for groups). The address-request, address-share and receipt cards are JSON *inside* the encrypted message body, so they inherit that protection exactly as text does. **This demo adds no cryptography of its own** — a claim worth making precisely because so many demos quietly do. **[verified — cards go through the same `send_message` path as text; see `MusterMessage.h` and `ChatBackendWallet.cpp`.]**

**Leaks.** Message *timing* and *size* remain observable to the transport, as above. Content does not.

**What would close it:** the same mixnet, plus padding. **Status: `specified`, early** (as above).

---

## 3. Agreeing where to pay

**What happens:** Bob asks for an address; Alice chooses which of her holdings to answer with — a *shielded receiving key set* from `lez_core.get_private_account_keys`, or a public account id. The card names the form it carries, and Bob's rail choices are filtered to the ones that can pay that form.

**Protected, if she shares the shielded one.** That destination names an account outside observers cannot associate with a payment, and it is exchanged inside the encrypted conversation. No third party is asked to resolve a name. **[from source — the contract exposes these as private-account keys and `transfer_private` consumes them; the privacy property is the zone's claim, which we consume rather than verify.]**

**The choice is deliberately the payee's, and it comes first.** Sharing a public account invites a payment anyone can read, and that consequence lands on the person being paid — so they make it, and the dialog says what it costs where they make it. A payer cannot upgrade a public destination to a private one: the address form is what a rail can reach, not a preference. **[from source — `Assets::AddressForm`, and `ChatBackend::sendableRailById` is the only path value moves through.]**

**The contrast worth drawing.** `lez_core` also ships an on-chain **label** system (`add_label` / `resolve_label`): a public, human-readable directory. It is genuinely more convenient and it is a different privacy trade — resolving a label is a public act, and the mapping is permanent. Same stack, two discovery models, honest costs on both. This is the cleanest teaching moment in the whole demo. **[from source — present in the generated contract; not exercised in this build.]**

**Leaks.** **Nothing binds the chat identity to the zone account.** Muster shows you an address that arrived from the peer you are talking to, and the encryption means only that peer could have sent it — but no cryptographic statement connects "the person holding this chat identity" to "the party controlling this account". In this build that is acceptable because the conversation *is* the authentication. It stops being acceptable the moment a third party relays an address, or a plugin proposes one. **[verified as absent — the two identities are minted independently, by different modules, and nothing in our code relates them.]**

**What would close it:** an authenticated binding between the chat identity and the settlement account, signed by both. **Status: `none` shipped.** It is exactly the problem the real Muster tracks as ADR-010, still open, and the reason F-14 wants one key serving both roles. This demo is a live demonstration of why that ADR matters.

---

## 3b. Agreeing to pay

**What happens:** instead of paying an address outright, a member proposes the payment to the room, picks how many people must agree, and the card collects approvals until it is ready. Whoever proposed it then pays.

**Protected.** An approval is an ordinary message, so it inherits the conversation's authentication exactly as text does: it carries its author, and nobody in the room can forge one, replay someone else's, or approve twice — the fold deduplicates by author. The count on the card is a real count of real members. It is also collected **without a coordination service**: there is no server that learns what was proposed, who has agreed, who has not, and when. **[verified — approvals go through the same `send_message` path; attribution is the message's own `sender`, matched against `list_group_members`. See `ChatBackendIntent.cpp`.]**

**The contrast worth drawing.** This is the cleanest comparison in the demo after the label system. The usual multisig flow pools proposals and signatures in a hosted transaction service, where the operator — and frequently anyone with the URL — sees the proposal, the signer set, who has signed and the timing, all *before* anything reaches a chain. The negotiation leaks before the transaction does. Here that entire stage is inside the encrypted room. **[from source — the documented shape of hosted multisig coordination; not separately measured.]**

**Leaks.**
- **The zone does not enforce the threshold.** This is the honest limit and it must not be soft-pedalled: the account that pays is single-key. Whoever proposed the payment could have paid it without waiting for anyone, and the only record that they *did* wait is the conversation. "2 of 3" is enforced by the room, not by the chain, and an outside observer sees an ordinary shielded transfer with no policy attached to it. **[verified as absent — nothing in our code or `lez_core` reaches a threshold check; the transfer call is the same one a direct send makes.]**
- **An approval is not bound to what it approves.** Approvals name a proposal by an id this app minted. Nothing commits to an execution environment, an account, a serialization slot or an expiry, so their scope is this conversation by convention rather than by construction. **[verified as absent — we build no signing payloads.]**

**What would close the first:** an account whose policy the zone itself enforces, so the threshold is checked where the money moves rather than where it was agreed.
**Status: `partial`.** `logos-co/lez-multisig` implements exactly this flow — Squads-style on-chain proposals, M-of-N, `ChainedCall` into a target program — and `lez_core` exposes `send_generic_public_transaction` to drive it. But it runs against a **local sequencer**; there is no documented deployment to the public testnet this demo uses, its proposal state and calls are **public accounts**, and its members must be fresh nonce-0 keypairs claimed at creation. So today the choice is **a chain-enforced threshold or a shielded amount, not both** — which is itself the most useful thing this section can teach, and worth stating as a live trade rather than a missing feature. *(Read off the repo 2026-08-11; re-check before publishing.)*

**What would close the second:** replay binding — signing payloads that commit to environment, account, slot and expiry. **Status: `none`** here; it is F-5 in the real client.

---

## 4. Paying

**What happens:** whichever of the zone's four transfer directions the payer chose. `transfer_private` from Bob's shielded account to Alice's shielded keys is the one the demo leads with; `transfer_shielded`, `transfer_deshielded` and `transfer_public` are offered beside it.

**Protected, on the private rail.** Private → private: the amount and both accounts stay off the public record. Funding deliberately shields the faucet prize into the private account *before* any payment, so the balance that rail draws on is already private and the transfer is shielded at both ends rather than only on arrival. **[from source + design — the sequence is ours and deliberate; the privacy guarantee is the zone's.]**

**The other three are offered on purpose, and each has its own claim.** A demo that only ever shipped the private path would be asking to be taken on trust. Shielding out of a public account names the payer; paying into a public account names the payee; public → public names everyone and returns in seconds instead of minutes. The receipt for each states what that rail actually disclosed, read from the rail itself rather than from a flag the reader interprets — so "what left the room" is the payment's own account of itself and cannot drift from the promise made before it. **[from source — `Assets::Disclosure` is written by the rail into the receipt card and read back by both the card and the visibility panel.]**

**A rail with no claim cannot be paid with.** `sendableRailById` refuses one whose `claimId` names nothing in `VisibilityClaims.qml`, at the single place value moves. This is the one place in the demo where the honesty rule is enforced by the code rather than by remembering it. **[verified — `payForIntent` and `proposePayment` both route through it; there is no other caller of a rail's `send`.]**

**What it costs, measured.** One shielded transfer took **6 minutes 41 seconds** at ~1300% CPU (13 cores saturated) on a desktop machine — 2026-08-11, LEZ testnet, `transfer_shielded_owned` of a single note. **[verified — timed from the zone's own log, start of proving to the wallet's next write.]** That is the honest price of the privacy claimed above, and it is worth publishing rather than eliding: a private payment here is not an interaction you wait on, it is a job you start. It also bounds what the demo can show live — a screen recording cannot sit through it, and two peers each proving compounds it.

Whether that figure is expected, hardware-bound, or a symptom of something misconfigured is **not yet established** — worth asking whoever owns the zone before the article states it as typical. What is established is that it happened, twice, on this machine.

**Leaks.** The zone still learns **that a transfer happened, and when**. Timing correlation across a small anonymity set is a real attack, and a demo with two users is the smallest possible anonymity set. Say this plainly rather than letting a shielded transfer imply more than it delivers. **[inferred — standard for this class of system; worth stating conservatively.]**

**What would close it:** a larger anonymity set and timing decorrelation. **Status: `partial`** — the shielded-transfer machinery is real and working; the anonymity set on a testnet is small by definition.

---

## 4b. The open bug, stated plainly

**Cause found (2026-08-11).** A shielded payment debits the sender and the recipient's balance never moves — but the money is not lost. It is credited to a **different account id than the one the recipient advertised**, and a client polling the id it published sees zero forever.

`wallet_ffi` derives a private account id from *(viewing key, identifier)*. The recipient's keys carry no identifier, so `lez_core.transfer_private` picks one **at random** — its own comment says so — and the note lands at an account neither party can predict. Enumerating the recipient's wallet after syncing finds it: the advertised account at 0, and a brand-new account holding exactly the amount paid.

Written up for the zone's developers, with a single-file reproducer that links `wallet-ffi` directly, in [`poc/BUG-private-transfer-recipient-identifier.md`](poc/BUG-private-transfer-recipient-identifier.md).

What follows is the measurement that got there, kept because the sequence of wrong turns is the useful part.

**The measurement (2026-08-11, two freshly minted peers, LEZ testnet).** Both peers' private accounts were created *and registered on-chain* — confirmed by transaction hash, not by absence of error. The sender held 150 private and paid 10. The zone proved for **7.4 minutes** and returned success with a transaction id. Afterwards:

| | before | after |
|---|---|---|
| sender, private | 150 | **140** |
| recipient, private | 0 | **0** |

The recipient's balance was re-read five times, each with a full sync to tip, over several minutes. It never moved. Reproduced by `muster-ui/doctests/credit/run-credit.mjs`, which drives both instances and prints the two numbers that matter.

**Registration was not the fix** — both accounts were registered and the advertised balance still did not move. The second suspect was right: `get_private_account_keys` does not return the thing `transfer_private` credits. Enumerating the recipient's wallet afterwards showed the payment sitting in a new account:

```
private 021fbfac…4634 balance=0    <-- advertised, registered, polled
private b719ff50…259a balance=10   <-- the payment
```

**Three findings that had to be cleared out of the way first**, each of which had been quietly hiding the real behaviour:

- **`register_private_account` proves, so it must be async.** Called through the generated sync client it hit the hardcoded 20-second timeout every time. The call had been in the code for a day and had *never once succeeded*.
- **It also requires an uninitialized account.** A second attempt is rejected with `Guest panicked: Account must be uninitialized`, so registration is only possible at creation and a peer minted by an older build cannot be repaired — it has to be re-minted.
- **`lez_core` has a third failure convention.** Seventeen of its methods return a JSON envelope (`{"success": false, …}`) rather than a bare transaction id, so the usual empty-string check reads a hard failure as success. That is why a shielding step that had failed reported nothing and left the prize in the public account — and why a *payment* could have posted a receipt for a transfer the zone rejected. Every call site now parses the envelope.

**A trap for anyone measuring this:** the balance read immediately after a transfer is stale. The sender showed 150 → 150 right after the proof and 150 → 140 on the next refresh. Do not conclude anything from the first read — which is very likely how the original report came to say the sender was debited by a different amount than it was.

It is in this document because the article must not describe the payment pipeline as working end to end. Everything up to and including *initiating* a shielded payment is real and measured; **the recipient's client shows nothing**, and until either the zone addresses the account it advertised or this app enumerates accounts after syncing, a user watching their balance has no way to know they were paid. **[verified: symptom reproduced twice, cause identified, reported upstream.]**

**The workaround is now in**, and it is labelled as one everywhere it shows. After syncing, the wallet enumerates `list_accounts` and sums every private account it can see, rather than polling the one id it published; payments are spent from the largest of those, because a note is held by the account it landed in and not by the one we created. Verified on a peer whose payment had been stranded: it had shown `0`, and now shows the 10 it was actually paid.

It is a workaround, not a design, and it has a visible cost that is disclosed rather than smoothed over:

- **The balance is a sum over accounts the user never created.** The wallet card says so, next to the number, whenever that is true — not in a panel someone has to open.
- **A single payment can only draw on one of those accounts**, so the figure shown may be larger than anything one send can spend.
- The `payment` step in the visibility panel carries this as a `gap` with status `none`, naming the fix (the recipient's identifier travelling with the address they publish) and pointing at the upstream report.

It comes out — along with the summing in `readWalletState` — the moment a payment arrives at the address it was sent to. Until then this build does not conform to what the real client is specified to do, and `README.md` leads with that.

## 5. What this build does not do at all

Not gaps in Logos — gaps in *this demo*, which the real client covers. Listed because a prototype that hides its shortcuts teaches nothing. The full table is in `README.md`.

- **No signed, hash-linked log.** Conversation state is whatever `chat_module` holds. There is no artifact you could replay to prove what was agreed.
- **No effect/materialization split and no re-derivation.** The user reviews an amount and a destination; nothing independently re-derives what is signed. In the real client this check is core behavior that cannot be disabled (F-4, FS-6).
- **No replay binding of our own.** We do not construct signing payloads, so there is nothing committing to environment, account, slot and expiry (F-5).
- **No membership epochs we verify.** Group re-keying is `chat_module`'s business; we neither check it nor claim it.
- **Two live remote dependencies** — the public `logos.test` delivery network and the LEZ testnet sequencer. There is no offline or local mode, so "local-first" is a property of the real client, not of this demo.
- **One asset: native λ.** The catalogue takes more, and the four rails are all four directions the zone offers for λ — but λ is the only thing in it. What that would take, established 2026-08-12 rather than guessed:
  - **Zone tokens: days, not a dead end, and public-path only.** `lez_core` exposes `token_elf` / `ata_elf` and `send_generic_public_transaction`, and the token program is pre-registered in genesis, so nothing needs deploying. What a client must build itself is RISC0-serde instruction encoding (`instruction: any` is a `Vec<u32>`, not CBOR), the program ids (image ids of the ELFs — not in the LIDL), and ATA derivation (plain SHA-256 over a domain-separated prefix; `wallet_ffi_account_id_for_public_pda` exists in the FFI but is not exposed). There is **no worked client example in any language but Rust** — persona does not touch it, and the module's own tests do not either. Two hard limits: the private path is **not expressible** through LIDL v0.4.0 (`send_generic_private_transaction` resolves *every* account as private, and ATA needs a private owner with a public definition), and there is **no enumeration API** — token balances live in Borsh-encoded account `data`, and a client must track definition ids itself. So a token holding here would be public-only and manually configured, which is worth having as a contrast rail and worth saying plainly about.
  - **Another chain (ETH and the like): not without a new module.** There is no EVM module in the runtime set. Reaching one means either upstream shipping a module or this demo writing its own secp256k1 signing — and that would end the "we write no cryptography" claim, which is load-bearing for everything else here. Out of scope for the prototype rather than merely unbuilt.

---

## Sources

- `../docs/00-vision.md` — the honesty rules and the worked mixnet example these rows follow
- `../docs/01-furps.md` — FS-9 (metadata honesty), F-14/ADR-010 (the identity binding), F-4/FS-6 (re-derivation)
- `logos-co/logos-chat-module` `rust-lib/chat_module.lidl` — the messaging contract we consume
- `logos-blockchain/logos-execution-zone-module` `src/lez_core_module.h` — the wallet contract, including the label system
- `logos-co/eth-lez-atomic-swaps` `delivery-dogfooding.md` and `docs/scaffold-upstream-tracker.md` — a catalogue of platform gaps with upstream issue numbers, useful if the article wants specifics with receipts
