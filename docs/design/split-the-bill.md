# Split the bill: the room agrees who owes what, and each person pays their own share

**Status:** design, 2026-09-28. Epic `exo-a90` (pebbles; `pb dep tree exo-a90` for live status; slices `exo-a90.1`–`.11`). **S0–S4 landed** (2026-09-28): the core seams, the `evm.split` driver, paying and confirming (end to end on anvil, `split_anvil_e2e`), and the hosted methods. The UI (S5, §7's split body) is next; `lez.split` is S8.
**Reads with:** `multisig-landscape.md` (families, profiles, the card's fixed rows; this adds one locus to its vocabulary), `action-manifest.md` (the manifest and the credibility axis), `material-and-disclosure.md` (who supplies what; request-first), `lez-adapter.md` (the four LEZ rails and what each discloses), `docs/00-vision.md` (the education mission), FURPS F-3 / F-4 / F-5 / F-10 / F-16 / F-20 / FS-7 / FS-9.
**Prototype:** `ui/prototype/coordination-prototype-v2.html`, the "Split the Lisbon offsite costs" room ("four wallets, no shared account — the room is the only thing holding this together") and the `split` plugin ("even shares, settles to personal wallets").

## 1. What was asked

A room action for splitting a bill: one person fronted it, the others each owe a share, and everybody settles up. Build it as "a family of drivers, or whatever is appropriate".

It is the first muster action with **no shared account**. Every family built so far is a multisig, where a group holds an account and authorizes spending from it. In a split there is nothing to hold. Four people pay from four wallets. The room is the only place the split exists, so it is the right place to show the whole lifecycle: what is agreed, what is signed, what reaches a chain, and who could have learned what.

## 2. What a split is, in muster's lifecycle

Devon paid 1.2 ETH for dinner for four. The split is Ana, JB and you each owing Devon 0.3 ETH, with Devon's own share being what he already paid.

| Step | What happens | Who acts | What is signed |
|---|---|---|---|
| **propose** | Devon proposes the split: the total, who owes how much, the address to pay, the chain. | the creditor (v1: the proposer *is* the creditor) | nothing yet |
| **collect** | Each person named reviews **their own share** and agrees. | each debtor | their room key (Ed25519) signs the split's materialization, with a muster attestation over the context (invariants 2, 10) |
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

`describeFor(effect)` is a new base driver method whose default is `describe()`. The core calls it wherever it needs *one proposal's* policy: `startCollection`, the intent views, the activity feed, audit and `coordinate_intents`. For a split it returns `rounds 1, threshold = number of debtors, finality external`.

A **contribution** is a debtor's Ed25519 signature over the materialization. It uses the same scheme as the threshold driver, but the signer set is **the debtors this materialization names**, decoded from the bytes the driver itself produced, not the room roster. So:

- a room member who is not in the split cannot agree to it;
- a later change to the roster (someone joins) never changes an existing split's threshold (the wart `unanimous` has today);
- `identifyContributor` names the debtor `ed:<hex>`, which is the existing convention, so attestations (`verifyAttestation`'s `ed:` arm), grades, "approved by me" and every view work unchanged;
- in-app agreement is `liveContribute`'s existing Ed25519 branch. There is no new signing path.

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

## 5. The invariants, one by one

| # | How the split keeps it |
|---|---|
| 1 | The agreement signs the re-derived materialization (the existing gate). The **payment** is derived from the agreed effect by the driver (`partTransfer`), and the hosted method takes only the intent id. The client cannot be told to pay a different amount or address than the one the person agreed to. |
| 2 | Agreements carry the existing attestation over P (context: environment, account = the CAIP-10 of `payTo`, slot = intent id, expiry). Part reports are author-signed and bound to the room, key and value. Paying after the agreement's expiry is refused. On EVM each payment is EIP-155-bound; on the LEZ, a public message commits to no zone (the card's binding row says so, exactly as for `lez.multisig-program`). |
| 3 | No plugin. The even-shares arithmetic is pure core code (`evenShares`). Plugins arrive in P5, and would emit the same typed effect. |
| 4 | The split's state, including every part, is `reduce(log)`. Parts converge under reordering and duplication (a probe). |
| 5 | Canonical decimal amounts, sorted shares, dCBOR materialization, one spelling. |
| 6 | Threshold (`describeFor`), parts (`settlementParts`) and who may record a step (`partAuthor`) are all driver-described. The core's new pass knows "settled" and "confirmed", never "split". |
| 7 | A split names members of the current epoch. A later joiner reads nothing before their seam, and is never a party to an earlier split. |
| 8 | Every payment goes through the payer's own RPC, and every confirmation through the creditor's. No service tallies anything. |
| 9 | What the card says about a person is only what that person disclosed: their agreement, their payment report, the creditor's confirmation. Readiness grades **my** balance against **my** share, never whether someone else can afford theirs. |
| 10 | The agreement's inputs are the proposal, the policy and the context (peer messages). `payTo` is the proposer's own material, in the effect. A later FX quote (backlog) is a recorded external read. |

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

The **split body** (S5) shows one row per person: name, amount, and state (*owes* · *agreed* · *paid ↗ tx* · *received ✓* · *received outside muster*). Below that sits "Your share: 0.3 ETH → Devon", then **Agree** (the existing Approve), **Pay my share** (when agreed, you owe, and have not paid), **Mark received** (the creditor), and the existing Deny ("that's not my share").

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
| `contracts/families/registry.json`, `scripts/check-family-registry.py` | the `each` vocabulary + rules; `evm.split` (partial → built at S4/S5), `lez.split` (next) |
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
2. **The creditor is the proposer in v1 (decided).** "I paid, split it" is the common case. Proposing on someone else's behalf is request-first (`material-and-disclosure.md` §3.4): the creditor shares `payTo`, then the complete split is proposed.
3. **Even shares round down, and the creditor absorbs the remainder (decided).** The creditor's own share is `total − sum(shares)`. It is visible, and at most N−1 of the smallest unit. Any other split (by nights, by item) is just different explicit amounts; the driver only checks the arithmetic.
4. **A new locus rather than stretching an old one (decided, §3).** This is a vocabulary change to the registry, so the atlas and the landscape table regenerate.
5. **Confirmation is the creditor's (decided).** Nobody else can confirm a private payment, and on a public rail the creditor is still the one the debt concerns. *Open:* whether a public-rail read by *another* member should show on the card as a local, unlogged grade ("your RPC also sees it").
6. **Amounts as canonical decimal text (decided).** This avoids `uint64` overflow in wei without dCBOR tags. *Open:* whether the platform's cdCDDLe profile (ADR-009, 5b) will want a bignum form; the `schema-id` field is where that would change.
7. **Fiat bills (open, backlog).** "1,840 EUR" settled in ETH needs a rate. The rate is an external read, and it is exactly the input invariant 10 exists for: the card shows whose quote, from where, and that the room is trusting it (the prototype's "Price quote" plugin).
8. **Netting (open, backlog).** "Settle up" across several splits is a second effect over the same parts seam. Its effect names the net transfers, and every original split's parts are confirmed by reference.
