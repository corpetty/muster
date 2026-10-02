# Split the bill: the room agrees who owes what, and each person pays their own share

**Status:** design, 2026-09-28. Epic `exo-a90` (pebbles; `pb dep tree exo-a90` for live status; slices `exo-a90.1`–`.11`). **S0–S5 landed** (2026-09-28): the core seams, the `evm.split` driver, paying and confirming (end to end on anvil, `split_anvil_e2e`), the hosted methods, and the UI (§7), driven end to end through the real runner by `scripts/split-self-test.sh`. The composer and card were looked at on a display (Xvfb) and fixed, exo-9a4. `lez.split` — the private split, §4.7 — is built, hosted and in the UI, and **ran end to end on the LEZ testnet** (2026-09-28). **S9**: the typed spec `contracts/specs/derived-exo-a90.spec.json` (six oracles, graded 6/6).
**Reads with:** `multisig-landscape.md` (families, profiles, the card's fixed rows; this adds one locus to its vocabulary), `action-manifest.md` (the manifest and the credibility axis), `material-and-disclosure.md` (who supplies what; request-first), `lez-adapter.md` (the four LEZ rails and what each discloses), `docs/00-vision.md` (the education mission), FURPS F-3 / F-4 / F-5 / F-10 / F-16 / F-20 / FS-7 / FS-9.
**Prototype:** `ui/prototype/coordination-prototype-v2.html`, the "Split the Lisbon offsite costs" room ("four wallets, no shared account — the room is the only thing holding this together") and the `split` plugin ("even shares, settles to personal wallets").

## 1. What was asked

A room action for splitting a bill: one person fronted it, the others each owe a share, and everybody settles up. Build it as "a family of drivers, or whatever is appropriate".

It is the first muster action with **no shared account**. Every family built so far is a multisig, where a group holds an account and authorizes spending from it. In a split there is nothing to hold. Four people pay from four wallets. The room is the only place the split exists, so it is the right place to show the whole lifecycle: what is agreed, what is signed, what reaches a chain, and who could have learned what.

## 2. What a split is, in muster's lifecycle

Devon paid 1.2 ETH for dinner for four. The split is Ana, JB and you each owing Devon 0.3 ETH, with Devon's own share being what he already paid.

| Step | What happens | Who acts | What is signed |
|---|---|---|---|
| **propose** | Devon proposes the split: the total, who owes how much, the address to pay, the chain. Or a member proposes it on Devon's behalf, paid at the address Devon shared into the room (§4.2). | the creditor, or anyone on their behalf | the proposer's signed claim to have proposed it (not an agreement) |
| **collect** | Each person named reviews **their own share** and agrees. The creditor agrees too: their agreement is their word that the address to pay is theirs. When Devon proposes, his agreement is made then. | each debtor, and the creditor | their room key (Ed25519) signs the split's materialization, with a muster attestation over the context (invariants 2, 10) |
| **executable** | Everyone named has agreed: the split is **agreed**. | — | — |
| **submit** | Each debtor pays their share from their own wallet. Muster builds the payment from the agreed split; the person types nothing. | each debtor | their own wallet signs a normal transfer (EIP-155 on EVM) |
| **settle** | Devon's client reads each reported payment from **its own** chain read and confirms it. Devon can also mark a share "received outside muster" (cash, a bank transfer). | the creditor | an author-signed confirmation in the room |
| **final** | Every share is confirmed. | — | — |

Two things set this apart from every family before it:

- **The parties are named in the effect.** A Safe's threshold belongs to the account; a room threshold belongs to the roster. A split's "who must agree" is *the people it names*, so the threshold comes from the effect.
- **Settlement comes in parts.** There is no single submitter and no single transaction. Each debtor settles their own part, and the split is final when every part is confirmed.

Both are made **driver-described seams** (invariant 6), not split special cases in the core: `describeFor(effect)` and `settlementParts(effect)` (§4.3). "Chip in for a gift", "pay your dues into the treasury" and "settle up across several bills" are the same shape with a different effect.

### Agree first, then pay

A debtor pays only once **everyone named has agreed** (the intent is executable). The alternative, where each person agrees and pays independently, would let Ana pay under one split while JB disputes his share and the proposer revises the split. The revision is a new intent (the id is the content), and Ana's payment would be stranded on the old one. Agree-then-pay keeps the lifecycle's order: contracting, then settlement. The cost is that the slowest person blocks everyone's payment; see §10.

## 3. Why this needs a new locus

The family registry sorts every family by **locus**, meaning where the threshold is enforced: native, contract, vote, aggregate or room. A split fits none of them.

- **Not `room`.** A room family's profile says "Nothing goes to a chain", and every card row derived from it says so too. A split puts N payments on a chain, and on an EVM chain every one of them is public. Calling it a room family would print a false card.
- **Not `vote`.** In a vote-locus family each approval is the approver's own transaction, and *the chain counts them* (lez-multisig executes at k). In a split the chain counts nothing. Each payment is an ordinary, independent transfer, and nothing anywhere enforces that it happens.
- **Not a multisig at all.** There is no account to set up, and no signer set to change.

So the vocabulary gains one value:

> **`each`**: no shared account. The room agrees who owes what, and each party settles their own part with their own transaction. Nothing on the chain counts or enforces the agreement.

It comes with profile rules, held equally by `profile.nim` and `scripts/check-family-registry.py`:

- `each` ⇒ `scheme: shared-bytes` (every party agrees to the same bytes);
- `each` ⇒ `commits: content`;
- `each` ⇒ `approverCost: none` (agreeing is free; each payment's fee is the payer's own settlement);
- `each` ⇒ no account (`account: ""`), a CAIP-2 chain;
- `each` ⇒ `k = 1`, `n = 0` on the profile, because the parties are named per proposal and `describeFor(effect)` carries the real threshold;
- the existing rules still apply: `each` is not `room`, so it settles somewhere and its binding is not `room`.

The registry's `about.what` changes from "a way a group can hold an account and authorize from it" to also cover "…or, for the `each` locus, a way a group agrees who pays what, with no account at all". It stays one registry, and the atlas and the card read it the same way.

**The credibility of settlement is motivational.** This is the most important line on the card, and it is the PriFi axis `action-manifest.md` §2 already uses. The agreement is imperative: nobody's share can change without their signature. The payment is not: the room cannot make anyone pay. Row 0 says exactly that and names the party ("each person who owes"). The room's job is to make it visible who has paid.

## 4. The model

### 4.1 The effect

```json
{"effect": "split",
 "chain":   "eip155:31337",
 "asset":   "ETH",
 "total":   "1200000000000000000",
 "creditor": "<128-hex room identity>",
 "payTo":   "0x…",
 "shares": [{"who": "<128-hex room identity>", "amount": "300000000000000000"}, …],
 "memo":    "Dinner at Tasca"}
```

Schema `muster.effect.split.v1`. The fields:

- **Amounts** are **canonical decimal text** in the asset's smallest unit. dCBOR refuses tags, so there is no bignum, and wei overflows `uint64` above about 18.4 ETH. Canonical means digits only, no sign, and no leading zero. `"030"` is refused rather than normalized, because the same value must always encode to the same bytes (invariant 5).
- **Parties** are named by their **room identity**, the 64-byte encryption identity (Ed25519 ‖ X25519) hex, as members and contacts already are. This is the name the room uses for a person (F-14). It is not a chain address.
- **`creditor`** is the person owed, and **`payTo`** is where they want to be paid. In v1 the proposer is the creditor, so `payTo` is proposer material (`material-and-disclosure.md` §3.2), written into the effect. It is therefore reviewed, signed and replay-bound.
- **`shares`** are sorted by `who`, with no duplicates. The creditor is never a debtor. Every amount is greater than zero, and the sum of the shares is at most `total`. The creditor's own share is `total − sum`, derived and shown, never stored. Sorting is required, not normalized: there is one spelling, so the intent id (`keccak(effect JSON ‖ policy)`) is the same on every host.
- **`memo`** is room-only text.

`signRefusal` refuses a malformed split with its reason. `canonicalize` maps a malformed split to a sentinel that no signature can name, which is the same rule `lez_multisig.nim` uses.

The **materialization** is dCBOR `[domain "muster.split.v1", schemaId, chain, asset, total, creditor, payTo, [[who, amount]…], memo]`, with `chain` taken from the driver instance. The effect must name the same chain, or it is refused.

### 4.2 Agreement: the parties are named in the effect

`describeFor(effect)` is a new base driver method whose default is `describe()`. The core calls it wherever it needs *one proposal's* policy: `startCollection`, the intent views, the activity feed, audit and `coordinate_intents`. For a split it returns `rounds 1, threshold = number of debtors + 1 (the creditor), finality external`.

A **contribution** is a party's Ed25519 signature over the materialization: a debtor's, or the creditor's. It uses the same scheme as the threshold driver, but the signer set is **the parties this materialization names**, decoded from the bytes the driver itself produced, not the room roster. So:

- a room member who is not in the split cannot agree to it;
- a later change to the roster (someone joins) never changes an existing split's threshold (the wart `unanimous` has today);
- `identifyContributor` names the debtor `ed:<hex>`, which is the existing convention, so attestations (`verifyAttestation`'s `ed:` arm), grades, "approved by me" and every view work unchanged;
- in-app agreement is `liveContribute`'s existing Ed25519 branch. There is no new signing path.

**Why the creditor agrees too (exo-770).** A split's content is anyone's to write. When only the debtors agreed, a member could publish "Alice paid — pay 0x‹mine›": the card said Alice paid, the debtors agreed, and they paid whoever wrote the address. The creditor's signature over the materialization, which carries `payTo`, is their word that the address is theirs, so no split is payable without it. Three pieces keep today's flow unchanged and make the on-behalf flow honest:

- **Agreeing by proposing.** A driver seam, `agreesByProposing(effect, proposer)` (default false), says when proposing *is* agreeing. For a split it is true when the proposer is the creditor, and `liveProposeIntent` then contributes that agreement with the proposer's own key. A creditor proposing their own split does nothing new.
- **Signed proposer claims.** Every proposal of every kind now publishes `intent/<id>/proposer/<who>`, an author-signed event (`authorship.nim`). The intent id is content-addressed from the effect and the policy, so the claim vouches for exactly what was proposed. `IntentView.proposers` reads only signed claims, and the card says "Proposed by X on Y's behalf". A claim is attribution, not acceptance: what makes a split payable is still every party's agreement. Proposals from older rooms are unattributed.
- **On someone's behalf.** `coordinate_propose_split` takes `{creditor}`. The split pays the Ethereum address that member last shared into the room (`sharedAddressOf`: their newest address-share, author-signed, so one posted in their name never counts), and it is refused with `no-shared-address` when they have shared none. Before the creditor's client agrees, it checks that it holds `payTo` (`creditorAgreeRefusal`: `payto-not-mine`), so the creditor never vouches for an address they cannot account for. A private split is proposed only by its creditor, because their shielded key node is not shared in the room.

### 4.3 Settlement in parts

`settlementParts(effect)` is a new base driver method whose default is `@[]` ("one member submits the whole", which is every family so far). A split returns its debtors as `ed:<hex>`. A second method, `partAuthor(effect, part, step)`, answers *who may record a step for a part*:

| step | recorded by | means |
|---|---|---|
| `settled` | the part's own party (the debtor) | "I paid my share", with a chain reference |
| `confirmed` | the counterparty (the creditor) | "I received it", from the creditor's own read, or marked received outside muster |

A part event is `intent/<id>/part/<part>/<step>`, with the value `{"author": <128-hex>, "tx": "…", "authorSig": …}`. It is **author-bearing** (`authorship.nim`): its author signs it bound to this room, this exact key and value, and its parents. A forged, edited or replayed-from-another-room report is therefore dropped by `roomEvents` before any fold sees it (invariants 2 and 9). The fold then asks the driver whether that author may record that step for that part. The core never reads the report's bytes beyond passing the author along (invariant 6).

**The fold** (`reduceIntents`) gains a pass after contributions, and only for an intent whose driver declares parts:

- only once the intent has reached **executable** does a part report count;
- the first valid report per `(part, step)` in canonical order wins;
- `confirmed` implies `settled`, since a part paid in cash has no chain report;
- any part settled means executable → **submitted**; any part confirmed means → **settling**; **every** part confirmed means → **final**;
- a bare `intent/<id>/submit` or `/final` event, which names no author and could be written by any epoch-key holder, **never** moves a parts intent. A split's finality is its parts', and nothing else's.

All of this is a pure function of the event set (invariant 4). Convergence under reordering and duplication is a probe.

### 4.4 Paying a share

`coordination/parts.nim` → `liveSettlePart`. It follows the same send / confirm / publish rhythm as `vote.nim`, split into two halves so that a hosted call never waits on a block (exo-3c9):

1. **Gates.**
   - A supported driver that declares parts.
   - The intent is executable (or already settling).
   - *I* am one of its parts.
   - My part is not already settled.
   - The context is not expired. Paying against an expired agreement is refused (invariant 2); confirmations are not, because money received late is still received.
2. **Derive the payment** (invariant 1). `partTransfer(effect, part)` returns `{chain, asset, to: payTo, amount: my share}`. It is read from the log's effect for this intent id, whose materialization I signed, and never from anything the UI sends. The hosted method takes **only the intent id**, so no amount or address crosses the API. A probe holds that a payment built any other way is refused.
3. **Send** through the `PartSeam`: my own wallet, my own key, my RPC (invariants 3 and 8). This returns a chain reference.
4. **Confirm my own transaction landed** (status 1). Until it has, the report stays "unconfirmed" and nothing is published.
5. **Publish** the author-signed `settled` report with the chain reference.

### 4.5 Confirming a share

The creditor's client runs `liveConfirmParts` on the intents tick, as the LEZ and FROST pumps do. For each part that is settled but not confirmed:

1. It reads the reported transaction from **the creditor's own infrastructure** (`PartSeam.checkReceived`). On EVM this is `eth_getTransactionByHash` plus the receipt: `to == payTo`, `value == share`, `status == 1`.
2. It refuses a reference it has **already confirmed for another part**, in any intent in this room. One payment settles at most one share. Otherwise a debtor who paid once could claim the same transaction for two identical splits.
3. It publishes an author-signed `confirmed` report.

`liveConfirmPart(intent, part)` without a reference is **"received outside muster"**. The creditor's word is the only authority on money they received in cash, and the card says so.

The grade is honest about what a confirmation is. It is the creditor's statement that *their* read of *their* RPC showed the payment. That is an external read (F-10, graded attested), and it is disclosed by the only person the debt concerns (invariant 9). Other members can see the chain reference, and on a public rail they can check it themselves. The fold does not ask them to.

### 4.6 A family per rail

One driver (`drivers/split.nim`) implements two families, the way `btc_multisig.nim` implements two:

| family | kind | policy | what the chain learns | status |
|---|---|---|---|---|
| `evm.split` | `evm-split` | `evm-split@eip155:<id>` | every payment: payer, payee, amount. Several payments to one address, close together, **link the group**. | S2 (this epic) |
| `lez.split` | `lez-split` | `lez-split@lez:<zone>` | nothing: shielded payee, private rail, so there is no payer, payee or amount on chain | S8 |

The policy is qualified by the **CAIP-2 chain** it settles on, in the same way an account-bound kind is qualified by its CAIP-10 account (`kinds.nim`). The intent id commits to the policy, so the same split on two chains is two intents. The driver instance then knows its chain, and its profile is complete. The kind list gains `settlesOn` (the CAIP-2 namespaces a kind's qualifier may name), and `driverForPolicy` resolves a chain-qualified kind through the host's room builder with the roster.

`lez.split` is **the private split**: `payTo` must be a shielded key node, and each debtor pays on the private rail. That makes its profile honest and fixed: the chain reveals no policy, no signers, and the effect is shielded. A public LEZ split would just be `evm.split`'s story on another chain. The LEZ rails' disclosure square (`lez-adapter.md`) is exactly why the two families are worth showing side by side.

### 4.7 Confirming a private payment

On the private rail the creditor cannot do what §4.5 does. A shielded note carries no payer and no link to the payer's transaction, and the chain cannot look it up by the payer's reference. What the creditor *can* do is scan their own wallet: a received note is discovered under the key node it was sent to, and it has an amount. The private split is built so that those two facts are enough.

- **Every share is a different amount.** `evenShares(…, distinctAmounts = true)` has the i-th debtor (sorted by who) owe i base units less than the even share, and the creditor absorbs those units too. At 9 decimals that is invisible money, but it makes each share unique. The driver refuses a `lez.split` with two equal shares. Nothing new reaches the chain, because the amounts are shielded.
- **The creditor's scan is the proof, not the payer's report.** The seam's `matchReceived` (`coordination/parts_lez.nim`) looks for a note that arrived at the split's `payTo` key node, of exactly that part's amount, and not already claimed in this room. The confirmed report then carries `note:<16 bytes of sha256(note id)>`. That is enough to claim the note once, and it points at nothing. A debtor's report without a matching note never confirms.
- **Paying is private-rail only.** The seam pays from the debtor's shielded account, and refuses a public source outright. The shield rail would put the payer and the amount on the chain, and a private split quietly degrading to that would make its card lie.
- **The debtor pays from the one note that covers the share.** Money received privately lands at an account the scan *discovers*, a shield to your own key node included, so the shielded account muster created is usually empty. A transfer draws on one note, never several. The seam pays from the created account if it covers the share, else from the largest discovered note that does, and otherwise says that no single note covers it.
- **Neither side acts on a scan that is behind.** A wallet's scan walks toward the chain tip in bounded steps (a fresh wallet starts at block 0, and one jump would outlive the call). Until it arrives, the debtor's payment and the creditor's match both report "still scanning the chain (block N of M)", which is neither a failure nor "nothing arrived". While a private split waits on a member, their scan keeps moving from the proposal on, one step a tick, never while their wallet is proving.
- **The seam generalizes.** `PartSeam.matchReceived` defaults to §4.5's behaviour (the reported transaction, checked by the creditor's own read), so `evm.split` is unchanged. Only a rail that cannot look a payment up overrides it.

This is proven in-process on a shared fake chain, where each member's wallet discovers only the notes sent to its own key node (`split_lez_test`), and on a fake that behaves as the zone does: scans in steps, notes at discovered accounts, proofs in the background (`split_lez_zone_test`).

**It ran on the LEZ testnet on 2026-09-28** (`scripts/split-lez-testnet.sh`, exo-14d): two instances on the live Logos fleet, each with its own real `lez_core` wallet. B claimed the faucet, shielded it to its own key node (a proof of ~6 minutes), paid its 50-unit share on the private rail (~8 minutes), and A's own scan found a note of exactly 50 at its key node and confirmed it. The split was final on both after 25 minutes; the scans took ~2 minutes of work each from block 0. A re-run over the same wallets, relaunched, one proof, went final in under 8 minutes: the creditor's background scan was already at the tip, so it confirmed 2 seconds after the payer's report. So **the real scan does expose a received note's key node and amount**. The run also found six places where the fake had been kinder than the zone; each is fixed, and `docs/labbook/lez-wallet-scan-and-proving.md` records them. Whether a privacy-preserving transaction commits to a zone id was left open by that run and is now answered from LEZ's source (exo-a90.22, labbook §10). It names no zone, but each private input cites a commitment-set root that the zone checks against its own history. A debtor's payment spends their own private account, so it lands only on the zone it was proven for; only a fork or replica sharing that history would accept it.

### 4.8 Paying in a token (ERC-20)

An Ethereum split may be paid in a token as well as ETH (exo-5ab). The effect names the token by its address, `erc20:0x…`, lowercase, in one spelling; a symbol such as "USDC" is never a name, because a token names itself. The amounts stay base units, so nothing the room signs depends on what the token says about itself.

- **Paying** is a `transfer(payTo, share)` call on the token, from the debtor's own key.
- **Confirming** reads the receipt's `Transfer` log from the creditor's own RPC. It must be that token, exactly the share, to `payTo`, in a successful transaction; the right token paid elsewhere, or another token paid to `payTo`, is refused by name.
- **Display.** The token's `symbol()` and `decimals()` are read through the member's own RPC and never signed. The card shows "0.3 MTD" and names the token's address beside it; the composer's "pay in a token" field looks the token up before the total is typed.

`split_erc20_anvil_e2e` holds it on anvil against a test token (`tests/fixtures/MusterTestToken.sol`).

### 4.9 Paying in Bitcoin (btc.split)

A third family, `btc.split` (exo-d17), settles a split in BTC on a Bitcoin chain, `bip122:<genesis prefix>`. The agreement is the same as every split's. Amounts are satoshis in canonical decimal. No share may fall below Bitcoin's 546-sat dust limit, because such an output could never be paid; the driver refuses the split with its reason, and the composer warns before Propose.

- **The payer's own key.** A debtor pays from `wpkh(<their muster key>)`, the P2WPKH address of the keystore's secp256k1 authorization key, which never leaves the keystore. Their client reads their coins at that address from **their own node** (`scantxoutset`), chooses coins and change (`buildSpendFrom`, the multisig composer's), and signs every input with the keystore: DER, `SIGHASH_ALL`, over its BIP-143 sighash. The node broadcasts the spend. The fee rate is the member's own setting, else the node's estimate, else its relay minimum: it is read, never invented. A payment has landed once it is in a block.
- **The creditor's own node.** It confirms a reported txid only when one of its outputs pays `payTo` exactly the share, at the network's confirmation depth (1 on regtest, 6 elsewhere). One satoshi more or less, or the share paid to another address, is refused and named. A node serving another chain is refused before anything is sent or read.
- **payTo** is a segwit address of the split's own network, in its one lowercase spelling: the creditor's own wpkh address when they propose. A Bitcoin split is proposed only by whoever fronted it, because the room's shared addresses are Ethereum ones.
- **What the chain learns.** A Bitcoin payment is public: its inputs name the payer, and the payee and amount are visible once broadcast. The coins it spends bind it to one chain (binding *implicit*). As on Ethereum, nothing on chain says which split a payment settles; the link lives in the room.

`split_btc_test` holds it without a node: BIP-173's P2WPKH vector, every input signed by the payer's key, the exact-output match, and the dust and network refusals. `split_btc_regtest_e2e` holds it on a real Bitcoin Core regtest node: two debtors pay from their own coins, a payment one satoshi short and one sent to someone else are refused, and the creditor's own node confirms both shares. `scripts/split-btc-self-test.sh` drives it through the real runner over the live fleet.

### 4.10 A bill in another currency (a recorded quote)

"1,840 EUR, paid in ETH" needs a rate, and a rate is an external read: exactly what invariant 10 exists for (exo-3a4). The effect carries an optional `quote`:

- **Its fields:** `currency` (ISO 4217, three capitals), `fiatTotal` (the bill in the currency's minor units), `fiatDecimals`, `rateAsset` (the asset's base units per `rateFiat` minor units, so per ONE unit of the currency), `source` (where the rate came from, as the proposer names it) and `at` (unix seconds). All are canonical text.
- **The conversion is exact.** The total must be `fiatTotal × rateAsset ÷ rateFiat`, rounded down. `fiatQuote` builds a quote from what a person types ("1840.00", "0.00031") by string arithmetic. Anything that cannot convert exactly is refused, never rounded: more decimals than the currency has, a rate finer than one base unit, a sign or an exponent, zero, or an overflow. The driver refuses a quoted split whose total is not its conversion, naming the conversion it expected.
- **The quote is signed.** It is the materialization's tenth element, so everyone agrees to the rate as well as the total. A split without a quote is byte-for-byte what it was.
- **The quote is accounted for.** The effect declares it sourced (`"sources": {"quote": "read"}`), and the proposer records the read (`intent/<id>/read/quote`, source `quote:proposer`) in the log **before** their own agreement (`liveProposeIntent(…, reads)`). Proposed without that record, the quote's origin is unaccountable, and nobody's agreement to it counts (`unaccountable-input`).
- **The card names the quote** before anyone agrees: "A bill of 1840.00 EUR, converted at 1 EUR = 0.00031 ETH — Alice's quote, from "ECB reference rate", ‹time›. Agreeing means trusting this rate: check it first." The quote's credibility is exactly who read it and from where. The room shows that and makes no claim of its own.

Settling is unchanged: each share is in the asset. `split_fiat_test` holds the conversion, the refusals, the signed bytes and invariant 10. On a display, a 1840.00 EUR bill was composed at a typed rate and proposed, and the other member's card named the quote.

### 4.11 Settling up (netting several splits)

Dinner (Bob and Carol each owe Alice 300) and a taxi (Alice and Carol each owe Bob 200) make four payments. Settled up, they make two: Carol pays Alice 400 and Bob 100 (exo-3c6). A settle-up is a **second effect of the split families**, `muster.effect.settle-up.v1`, under its own domain. It changes nothing about how a split becomes final.

- **What it covers.** The room's agreed, unpaid split shares on one chain and asset, each exactly as its split says it: intent, debtor, creditor, amount and payTo (`openParts`). None of them may already be covered by another settle-up.
- **The net transfers.** Each member's balance (what they are owed less what they owe) is **conserved**. The largest net debtor pays the largest net creditor until one of them is square, with ties broken by identity, so every member computes the same result (`netTransfers`). Each recipient is paid only at an address a split owing them agreed. The driver refuses anything else, naming whose balance breaks.
- **Who agrees.** Every party the covered shares name, each debtor and each creditor, because netting changes who pays whom. A party proposing it agrees then. Before anyone agrees, their client checks every cover against its split in the log. This is `coordination/covers`, which is generic: the core never knows what a split is. The driver declares what an effect covers through a new seam, `Driver.covers`. A misstated cover gets no agreement (invariant 1 across intents).
- **Paying.** Each net transfer is a part, named for its payer and recipient. The payer pays it from their own wallet, and the recipient's client confirms it from their own read, exactly as a split's share works. A payer owing two people pays two parts; the parts path now finds "my part" through `partAuthor`, which for a split is still the one part named for the debtor. While a settle-up is agreed, a covered share can't be paid directly (`covered-by-settle-up`), so it is never paid twice.
- **Two payments at once (exo-a90.18).** A payment's "settled" report follows only once it lands, so until then the log shows its part unpaid. The host therefore passes what it has in flight to `liveSettlePartSend`, which skips those parts and answers `paying` when nothing else is left: a part is never sent twice, and a payer owing two people can send the second while the first lands. On Bitcoin the second payment is built only from coins no mempool transaction spends (`spendableUtxosOf`); built from the first's coin, it was refused as an underpaying replacement on Core 31, and a larger one would have replaced the first. `part_in_flight_test`, `settle_up_btc_regtest_e2e` (both payments in the mempool at once, each from its own coin) and `settle_up_erc20_anvil_e2e` (a settle-up in a token, two pending transfers at consecutive nonces) hold it. A payment is never forgotten while it might still land (exo-a90.23, `coordination/pending_parts`). Past its seam's pay deadline it becomes *unresolved*: still in flight, still watched, checked every 30 s. It leaves the host's book only when it lands (its report is published), fails on chain, or the chain says it can never land (`PartSeam.partGone`):
  - **Ethereum:** your RPC no longer knows it and its nonce is settled. Either another mined transaction used the nonce, or the nonce is free again, so a new payment takes that same nonce and at most one of the two can be mined.
  - **Bitcoin:** the node, with its transaction index, no longer knows it, and one of its coins was spent by another transaction. Without the index the answer is never "gone".

  The book is saved beside the identity after every outcome and read back on start, so a crash forgets nothing. Checked live: a payer killed with its payment in the mempool and relaunched sent no second payment, reported the first once it was mined, and the split went final on both. A seam is rebuilt only once the room's log names the intent's policy; before that fix, a restart watched a Bitcoin payment through the EVM seam.
- **Expiry (exo-a90.16).** A settle-up's payments are refused past its expiry, like a split's (invariant 2). A cover must not outlive that, or its shares could never be paid at all, so the rule has two sides (`coordination/covers`):
  - A settle-up that **paid nothing** pays nothing more once it expires. A day later (`CoverReleaseGraceS`, longer than any seam's deadline for a payment in flight, so a payment sent just before the expiry is still reported inside it) it covers nothing. Its shares can then be paid directly again, or settled up anew.
  - A settle-up whose **payments have begun** is finished, never abandoned. Its remaining payments go ahead past the expiry, and it keeps covering, because what it already moved replaced the shares it covers, and paying those directly would pay twice.
  - One with nothing to pay is settled on agreement and never lapses.

  The rule is generic: it applies to any intent that covers others' parts, never to a plain split, whose payments stay refused past its expiry whatever has been paid (the typed spec's s1). The card names an expired settle-up and when its shares are released; Home stops asking anyone to pay it, and never asks a debtor to pay a share a settle-up covers.
- **Finishing.** Once the settle-up is final (or agreed with nothing to pay, when debts cancel exactly), each creditor's client marks the shares it covered received (`settleCovered`). That is the creditor's word, the same path as a share received outside muster, so each split goes final exactly as before. The typed spec's guarantees are untouched: one payment reference still confirms one part, because a covered share is confirmed with no reference.
- **The private split is never netted.** Its shares are told apart by amount, which netting would erase.

`settle_up_test` holds the netting, the driver's refusals, the parties and the parts. `settle_up_live_test` holds the whole flow in a room of three: a misstated cover gets no agreement, a covered share can't be paid directly, Carol pays two parts, and both splits go final on every member. `settle_up_expiry_test` holds the expiry: an unpaid settle-up's covers hold through the grace window and then release, the released shares are paid directly or settled up again, a started settle-up finishes past its expiry without paying anything twice, and a plain split past its expiry still refuses payment. On a display over the live fleet with a real anvil, two members' splits were settled up into one payment of 0.1 ETH, confirmed from the recipient's own read, and both splits went final.

### 4.12 Renewing a split past its expiry

A split's agreement is bounded (invariant 2): past its expiry, no share of it is paid. That is right, but it used to be a dead end. Re-proposing the same split gave the same intent id, since the id commits to the effect and the policy, and that id was still bound to its first, spent context (exo-a90.15).

- **A renewal is a settle-up of that one split** (`settle_up.renewalOf`, `coordinate_renew_split`). It covers exactly the split's unpaid, unsettled shares, as the split says them. Each share is paid by its own debtor to the split's payTo, so nothing is netted and nothing changes hands differently.
- **Everyone those shares name agrees again**, under the renewal's own, fresh expiry: each debtor who still owes, and the creditor. Proposing is the proposer's agreement if they are one of them.
- **From there it is the settle-up path, unchanged** (§4.11). Once the renewal is final, each creditor marks the shares it covered received, and the split is final. If the renewal itself lapses unpaid, it releases them a day later (exo-a90.16).
- **Each renewal is a new intent.** Its memo names when it was made ("Renewed 2026-09-30 01:12:00 UTC — Dinner"), so renewing again never lands on a lapsed renewal. The driver accepts a settle-up of a single part for this; the Split composer's Settle up still nets two or more.
- **The private split is not renewed this way.** It is never netted (§4.7), so it is proposed again instead.
- **An identical split that expired in the room** is refused on re-proposal with `expired-duplicate`, never silently re-announced under the old expiry. The composer says to change its note, or to renew it from its card.
- **The card.** An expired split says so and hides Pay my share and Agree, both refused past the expiry. To a debtor or the creditor, while a share is unpaid, it offers "Renew the unpaid shares".

`split_renew_test` holds it:
- a renewal covers only the unpaid share, and everyone it names agrees again;
- the share is paid through the renewal, and the split goes final on every member;
- renewing again after a renewal lapsed is a new intent with its own expiry;
- an identical re-proposal is refused;
- a final split has nothing to renew.

### 4.13 Settling up across assets and chains

A room with an ETH dinner, a USDC taxi and a Bitcoin hotel used to need three settle-ups, one per chain and asset (§4.11). Settling up across them nets all three into one set of payments, at rates the room agrees to (exo-a90.17). It is the same effect, `muster.effect.settle-up.v1`, with two optional additions. A settle-up on one chain and asset is byte for byte what it was, and so are its rules.

- **One payment rail.** A settle-up still pays on one chain, in one asset: the proposer's choice of an Ethereum chain (ETH or a token) or a Bitcoin network (BTC). The shares it covers may be on any public split rail, each named with its own chain and asset. The private split is never netted (§4.7).
- **A rate for every other asset.** For each chain and asset its covers use, other than the payment one, the effect carries a rate: `rate` payment base units per `per` base units of that asset, with its `source` and time `at`. It is the proposer's quote, the same recorded read as a fiat bill (§4.10):
  - it is declared sourced (`"sources": {"rates": "read"}`), and the proposer records the read before anyone's agreement, or no agreement counts (`unaccountable-input`, invariant 10);
  - it is signed, as the materialization's eighth element;
  - the card names it as the proposer's, from where and when, before anyone agrees.

  A cover in an asset with no rate is refused, and so is a rate no cover uses. The composer takes a rate per ONE unit of the other asset ("1 BTC = 21.4 ETH") and signs it in base units on both sides (`per` = 10^decimals, `settleRate`), so the arithmetic never depends on anyone's read of a token's decimals; each member's card converts it back with its own.
- **Each cover converts on its own.** Its payment-asset value is `amount × rate ÷ per`, rounded down: the debtor keeps the remainder, under one base unit of the payment asset per cover. A cover that converts to nothing is refused, and so is one whose product overflows 256 bits: refused, never wrapped, as the fiat conversion is. The cover itself still states its share exactly as its split does, in its own asset on its own chain, and every client checks that against the split before agreeing (`coordination/covers`, unchanged).
- **Conservation, in the payment asset.** Each member's balance across the converted covers equals their balance across the net transfers, and the driver refuses anything else, naming whose balance breaks. What each split says is untouched, so conservation stays checkable per asset: each cover against its split, then each conversion against its signed rate.
- **Where a recipient is paid.**
  - If a covered split on the payment chain owes them, the payment goes to that split's payTo, as in §4.11.
  - If none does, it goes to an address on the payment chain that they vouch for themselves. The composer takes the address they last shared into the room for that chain: an Ethereum address, or a Bitcoin address of that network. If they have shared none, it refuses and names them.
  - Their client refuses to agree to a payTo it does not hold (`payto-not-mine`), as a split's creditor does (exo-770). Every party must agree to a settle-up anyway, so the address is their word.
  - Two Ethereum chains are two chains. An address a split agreed on one is not taken as vouched on another, where it could be a contract that does not exist.
- **Paying and finishing are unchanged.** Each net transfer is a part on the payment chain (§4.11). Once the settle-up is final, each creditor marks the shares it covered received, on whatever chain they were. That is a confirmation with no reference, the creditor's word, and it never reads the covered split's chain. So a Bitcoin share settled by an ETH payment goes final without a Bitcoin transaction.
- **What agreeing means.** Agreeing to a settle-up across assets is also agreeing to a currency exchange between members, at the proposer's rates. The card says so: "Agreeing means trusting these rates: check them first." Nothing in muster makes a rate fair. The room shows whose rate it is and where it came from, and each party's own agreement is the only thing that makes it binding.

## 5. The invariants, one by one

| # | How the split keeps it |
|---|---|
| 1 | The agreement signs the re-derived materialization (the existing gate). The **payment** is derived from the agreed effect by the driver (`partTransfer`), and the hosted method takes only the intent id. The client cannot be told to pay a different amount or address than the one the person agreed to. |
| 2 | Agreements carry the existing attestation over P (context: environment, account = the CAIP-10 of `payTo`, slot = intent id, expiry). Part reports are author-signed and bound to the room, key and value. Paying after the agreement's expiry is refused. On EVM each payment is EIP-155-bound; on the LEZ, a public message commits to no zone (the card's binding row says so, exactly as for `lez.multisig-program`), and a private payment names no zone either but is bound to it by the commitment-set roots its inputs cite (exo-a90.22). |
| 3 | No plugin. The even-shares arithmetic is pure core code (`evenShares`). Plugins arrive in P5, and would emit the same typed effect. |
| 4 | The split's state, including every part, is `reduce(log)`. Parts converge under reordering and duplication (a probe). |
| 5 | Canonical decimal amounts, sorted shares, dCBOR materialization, one spelling. |
| 6 | Threshold (`describeFor`), parts (`settlementParts`) and who may record a step (`partAuthor`) are all driver-described. The core's new pass knows "settled" and "confirmed", never "split". |
| 7 | A split names members of the current epoch. A later joiner reads nothing before their seam, and is never a party to an earlier split. |
| 8 | Every payment goes through the payer's own RPC, and every confirmation through the creditor's. No service tallies anything. |
| 9 | What the card says about a person is only what that person disclosed: their agreement, their payment report, the creditor's confirmation. Readiness grades **my** balance against **my** share, never whether someone else can afford theirs. |
| 10 | The agreement's inputs are the proposal, the policy and the context (peer messages). `payTo` is the creditor's own material: in the effect when they propose, or taken from their author-signed address-share when proposed on their behalf. Either way, the creditor's agreement vouches for it (exo-770). A later FX quote (backlog) is a recorded external read. |

## 6. What each observer learns: the education square

This is what the card's "Who will see what" box and the walkthrough show.

| observer | a payment app with a public feed | `evm.split` | `lez.split` (private) |
|---|---|---|---|
| **room members** | — | the whole split: who, how much, the memo, who agreed, who paid, the chain references | same |
| **store node** | — | topic and timing (FS-9), the baseline rows | same |
| **your RPC provider** | the app's server sees everything | your signed payment before the mempool | your proof and transaction, not its contents (unverified at S8) |
| **anyone reading the chain / feed** | who paid whom, often *why* ("🍕") | payer, payee, amount of every share; N payments to one address in a short window **reveal the group** | nothing that names a payer, payee or amount |
| **the app company** | all of it, forever | — (no server) | — |

The line the walkthrough draws: **the room is the boundary.** Who ate dinner together is in the room and nowhere else. The chain sees money move, and how much it sees is a choice of rail, stated on the card before anyone pays. Tagging each payment on-chain with the split's id would be convenient, and it would publish the group, so muster does not do it. The link between a payment and a share lives in the room's `settled` report.

## 7. The card

The fixed rows (`card_rows.nim`) gain the `each` wording:

| row | `each` |
|---|---|
| Where the rule lives | No shared account: the room agrees who owes what, and each person pays their own share from their own wallet on <chain>. Nothing makes anyone pay; the room shows who has. *motivational, party: each person who owes* |
| What you sign | To agree, your room key signs the split. To pay, your own wallet signs a transfer muster builds from the split (your share, to the address in it) and nothing else. *imperative* |
| Only valid on | from the binding, unchanged |
| Collecting | One agreement from each person named, then one payment from each. |
| What the chain learns | EVM: "Each payment is public: who paid, whom, how much. Payments to one address close together link the group." *exposed, anyone reading the chain*. LEZ private: "Nothing: the payments are shielded." *imperative* |
| Approving costs you | Agreeing costs nothing; paying costs your own transaction's fee. |
| Changing signers | The people are named in each split; a different group is a new split. |
| Ways around the rule | None for the agreement. Paying is up to each person. *motivational* |

The **split body** (S5) shows one row per person: name, amount, and state (*owes* · *agreed* · *paid ↗ tx* · *received ✓* · *received outside muster*). Below that sits "Your share: 0.3 ETH → Devon", then **Agree** (the existing Approve), **Pay my share** (when agreed, you owe, and have not paid), **Mark received** (the creditor), and the existing Deny ("that's not my share"). A split proposed on the creditor's behalf also says "Proposed by X on Devon's behalf" and whether Devon has agreed. Devon's own card offers "Agree — I paid, and ‹payTo› is mine", or, when his client does not hold `payTo`, a warning in its place (exo-770).

## 8. Where it lives

| Seam | Change |
|---|---|
| `intents/materialization.nim` | `describeFor(effect)`, `settlementParts(effect)`, `partAuthor(effect, part, step)`, `partTransfer(effect, part)`: base methods with honest defaults |
| `drivers/driver.nim`, `intents/lifecycle.nim` | `startCollection(driver, descriptor)`; `newIntent` uses `describeFor` |
| `coordination/intent_events.nim` | `effect: "split"` in `effectFromJson` / `effectSchema`; `partEvent` |
| `coordination/authorship.nim` | `part` joins the author-bearing kinds (the value's `author`) |
| `coordination/intents.nim` | the parts pass; `IntentView.parts`; activity ("Ana paid her share", "Devon confirmed JB's share") and provenance (a `settled` is a peer message, a `confirmed` an external read) |
| `coordination/effect_summary.nim` | "a split: 1.2 ETH, 3 people owe Devon" |
| `drivers/split.nim` (new) | the driver: both families |
| `drivers/profile.nim`, `card_rows.nim`, `kinds.nim`, `registry.nim`, `coordination/accounts.nim` | the `each` locus + rules; its rows; `evm-split` / `lez-split` with `settlesOn`; chain-qualified resolution |
| `coordination/parts.nim`, `parts_evm.nim` (new) | `PartSeam` (+ a fake ledger, + the EVM seam), `liveSettlePart` (send / complete), `liveConfirmParts`, `liveConfirmPart` — generic over any parts family |
| `wallet/evm_rpc.nim` | `rpcTransferOf(hash)`: from, to, value, status (nim-web3's `eth_getTransactionByHash` + receipt) |
| `contracts/families/registry.json`, `scripts/check-family-registry.py` | the `each` vocabulary + rules; `evm.split` and `lez.split`, both built (exo-9a4) |
| `api/muster.lidl`, `nim-lib/muster_module.nim` | S4: `coordinate_propose_split`, `coordinate_settle_part`, `coordinate_confirm_part`, the confirm pump, parts in `coordinate_intents` |
| `ui/src/qml/*` | S5 |
| `contracts/actions/family/evm.split.json`, `contracts/claims/registry.json` | S6 |

## 9. Slices

| Slice | Done when |
|---|---|
| **S0** `exo-a90.1` design | this doc |
| **S1** `exo-a90.2` core seams | `describeFor` + parts in the fold; a stub-driver test drives propose → agree → settled → confirmed → final; a bare `final` never finalizes a parts intent; a report by anyone but the allowed author never counts; the convergence probe holds; the whole suite stays green |
| **S2** `exo-a90.3` the split + `evm.split` | refusals (sum, duplicates, order, creditor-as-debtor, canonical form, chain), the threshold from the effect, a non-debtor's agreement never counts; conformance + profile conformance green; registry, kinds and card rows updated with the checker green |
| **S3** `exo-a90.4` pay + confirm | an in-process room of three over a fake seam goes to final; refusals: pay before agreed, pay twice, a non-party pays, pay after expiry, one reference confirming two parts; the payment is always the derived one (probe) |
| **S4** `exo-a90.5` hosted | the lidl methods, the confirm pump, parts in `coordinate_intents`, readiness for my share |
| **S5** `exo-a90.6` UI | the composer verb, the in-room split composer, the split card; offscreen self-test |
| **S6** `exo-a90.7` atlas + claims | `family/evm.split.json` + generated entry; the protects / gap / others-leak claims |
| **S7** `exo-a90.8` e2e | `split_anvil_e2e` green on a live anvil |
| **S8** `exo-a90.9` `lez.split` | the private split on `FakeLezCore`, then the testnet |
| **S9** `exo-a90.10` typed spec | `derived-exo-a90.spec.json` via `discuss-issue` |
| backlog `exo-a90.11` | FX, proposer ≠ creditor, netting, ERC-20, Bitcoin |

## 10. Decisions and open questions

1. **Agree-then-pay, not pay-as-you-agree (decided).** It keeps contracting before settlement, and it means a revised split never strands a payment (§2). *Open:* for large rooms, a proposer-set "anyone may pay once they agree" flag. That would be a second `describeFor` shape, not a core change.
2. **The creditor agrees, whoever proposes (decided, exo-770).** "I paid, split it" is the common case, and there proposing is the creditor's agreement. Proposing on someone else's behalf is request-first (`material-and-disclosure.md` §3.4): the creditor shares an address, the split is proposed with it, and it is payable only once the creditor agrees too (§4.2). The alternative, gating `payTo` on a match with the creditor's disclosure, was set aside, because the creditor's own signature says more than a match does and it closes the forged-creditor hole for every split.
3. **Even shares round down, and the creditor absorbs the remainder (decided).** The creditor's own share is `total − sum(shares)`. It is visible, and at most N−1 of the smallest unit. Any other split (by nights, by item) is just different explicit amounts; the driver only checks the arithmetic.
4. **A new locus rather than stretching an old one (decided, §3).** This is a vocabulary change to the registry, so the atlas and the landscape table regenerate.
5. **Confirmation is the creditor's (decided).** Nobody else can confirm a private payment, and on a public rail the creditor is still the one the debt concerns. *Open:* whether a public-rail read by *another* member should show on the card as a local, unlogged grade ("your RPC also sees it").
6. **Amounts as canonical decimal text (decided).** This avoids `uint64` overflow in wei without dCBOR tags. *Open:* whether the platform's cdCDDLe profile (ADR-009, 5b) will want a bignum form; the `schema-id` field is where that would change.
7. **Fiat bills (decided, exo-3a4, §4.10).** "1,840 EUR" settled in ETH needs a rate. The rate is an external read, exactly the input invariant 10 exists for. It is the **proposer's quote**, typed with its source, recorded in the log before anyone agrees, and signed with the split; the card shows whose quote, from where and when, and that agreeing means trusting it. *Open:* a price plugin (the prototype's "Price quote") that fetches a rate from a user-configured source (invariant 8). It would be the same recorded read, from another reader.
8. **Netting (decided, exo-3c6, §4.11).** A settle-up is a second effect of the split families over the same parts seam. Its effect names the covered shares and the net transfers; every party agrees; each covered share is marked received by its creditor once the settle-up is final, so a split's finality is unchanged. A settle-up that expires unpaid releases its covered shares a day later; one that began paying is finished (decided, exo-a90.16, §4.11). Netting across assets and chains (decided, exo-a90.17, §4.13): one payment rail, a rate per other asset recorded like a fiat quote, each cover converted on its own, and a recipient owed nothing on the payment chain paid at an address they vouch for by agreeing.
