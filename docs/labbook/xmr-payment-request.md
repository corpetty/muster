# The XMR payment request: the module half (exo-dcc.5)

**2026-10-08. Status: built and held over a recording fake wallet backend; not yet run
against a live stagenet payment. The UI is built (below), held offscreen, and was seen on
display in Basecamp 0.3.2 with a real stagenet wallet minting payTo.** ADR-018 (accepted) in
`docs/02-implementation-plan.md`; plan `docs/design/monero-in-rooms.md` §4, §6 Phase 2; typed
spec `contracts/specs/derived-exo-dcc.5.spec.json`, graded 7/7 by
`scripts/grade-specs.sh exo-dcc.5`.

A payee requests XMR in a room. Each payer pays from any wallet through a `monero:` link.
The payee's own wallet confirms the payment: a subaddress per request, the exact share,
10 confirmations. Muster holds no Monero key and never spends.

## Where it lives

| File | What |
|---|---|
| `module/src/drivers/split.nim` | family `monero.split` (kind `monero-split`, policy `monero-split@monero:<ref>`), the payTo, share and asset rules, the profile and the manifest, never netted |
| `module/src/wallet/monero_backend.nim` | the pure half of the creditor's wallet seam: the closed call set, reply parsing, `walletRefusal` |
| `module/src/wallet/monero_backend_lp.nim` | `monero_wallet_backend` over lp_*: the plugin only |
| `module/src/coordination/parts_xmr.nim` | `MoneroPartSeam` and the pure confirm rule `matchXmrPayment` |
| `module/src/coordination/xmr_request.nim` | the live path the module hosts: mint, propose, agree, link, "I paid", the confirm pump |
| `module/src/coordination/parts.nim` | `confirmsUnreported`: a seam whose own read finds payments nobody reported |
| `module/tests/split_monero_test.nim` | unit tests over the fake |
| `module/tests/probes/fake_monero.nim`, `xmr_room.nim` | the recording fake backend, and the room of four over it |
| `module/tests/probes/probe_xmr_*_stepper.nim` | the spec's seven oracles |

## What each guarantee rests on

**s1. The link is derived from the agreed request.**
- `xmrLinks` reads the effect from the log under this intent id: the bytes every party signed.
- It takes the transfer from `Driver.partTransfer`, as every split payment does (invariant 1).
- It writes the link with `makePaymentUri(chain, payTo, share)`: no description and no
  recipient name. The memo stays in the room.
- No link exists until the intent is executable, because the creditor must first vouch for
  payTo.
- Probe `probe_xmr_request_uri_stepper`: 96 cases. The link equals `makePaymentUri` on every
  member's client, and reads back with `parsePaymentUri` as exactly that address and amount.
  Changing the address or the share by one atomic unit changes it. The memo never does.

**s2. payTo is the creditor's own subaddress on the agreed network.**
- The driver's `payToOk` is `acceptablePayTo(payTo, chain)`: a standard address or a
  subaddress on that chain's network. It is never integrated and never has a bad checksum.
  Every client folds with the same rule, so an invalid payTo canonicalizes to a sentinel and
  nobody's agreement to it counts.
- `xmrCreditorRefusal` runs on the creditor's client before they propose (proposing is their
  agreement) and before they agree to a request someone made on their behalf. It refuses
  payTo for another network, an integrated payTo, an invalid one, a wallet that cannot vouch
  (`walletRefusal`), and a payTo their open wallet's `receive_info` does not list.
- Probe `probe_xmr_payto_stepper`: 30 cases. Five payTo kinds × who proposes × three networks.

**s3. Only the creditor's own wallet read confirms a part.**
- `matchXmrPayment` confirms only an incoming transfer that meets all of these:
  - a history row with direction `in`, account 0;
  - `subaddrIndex` exactly payTo's index, and that index alone (a row spread over several
    subaddresses carries their sum);
  - the amount exactly the share;
  - `confirmations ≥ 10`;
  - not `failed`;
  - a txid not already claimed in the room.
- The wallet must be open on the agreed network, and not view-only.
- A busy read or an unanswered one is *pending*: nothing is published, nothing is released,
  nothing is failed.
- A debtor's report never decides. `matchReceived` ignores the reported txid and reads the
  history. The pump (`confirmsUnreported`) reads for every unconfirmed part of an agreed
  request, reported or not.
- Probe `probe_xmr_confirm_stepper`: 864 cases, in 36 states of 24. Grouping them keeps the
  grade near five minutes, since each state is its own `nim r`.

**s4. One transfer settles one part.**
- `matchXmrPayment` skips a claimed txid.
- `liveConfirmPart` also refuses any found reference that is already claimed, whatever the
  seam returns.
- The driver refuses equal shares on one subaddress at proposal: "every share paid to one
  subaddress must differ".
- Probe `probe_xmr_one_ref_stepper`: 8 cases.

**s5. Final only when every part is confirmed, convergent.**
- The generic parts fold (`intents.nim` pass 5): a report moves the request to submitted,
  and only the creditor's confirmations finalize it.
- Probe `probe_xmr_request_convergence_stepper`: all 8! orders, plain and doubled, rotated
  over three clients' driver instances, plus every subset (256) on all three.

**s6. Muster never spends.**
- `monero_backend.call` is the only way to reach a backend. It raises `MoneroRefused` for any
  method outside `MoneroReadMethods`, before anything is sent:
  - `wallet_status`, `receive_info`, `create_subaddress`, `history`;
  - `caller_identity`, `list_networks`, `address_valid`;
  - `list_wallets` (exo-dcc.20), ungated: names and networks, no key. It is read only by
    `xmrUnlockTarget`, to name the wallet a remedy asks Monero Wallet to open, never on a
    request's own steps. The probe's allowed set stays the seven above, so a step that
    asked it would fail s6.
- `MoneroPartSeam.sendPart` refuses.
- Probe `probe_xmr_no_spend_stepper`: 11 cumulative steps, each through the hosted paths,
  with every member's backend recording.

**s7. No confirmation across networks.**
- `walletRefusal` requires the open wallet's `network` to equal the chain's network
  (`networkOfChain`).
- A history names no wallet, so `readMatch` reads `wallet_status` again after `history` and
  requires the same wallet, network and state.
- The lp layer also binds a cached history to the wallet named around it (below).
- Probe `probe_xmr_network_stepper`: 12 cases. The remedy names `monero.wallet.unlock`.

## The backend's replies, as parsed

Every reply arrives as a JSON string holding the document. `moneroReply` unwraps it, and also
unwraps lp's `{success, value}` envelope. `{ok:false, busy:true}` is read as busy;
`ok:false` and no answer as unread.

```
wallet_status()          {ok, state: no_wallet|opening|syncing|ready|closing|failed, wallet, network, watchOnly, lastError, …}
receive_info(0)          {ok, address, subaddresses: [{index, address, label}]}     (index 0 = the primary)
create_subaddress(0, l)  {ok, index, address}
history()                {ok, rows: [{txid, direction, amount (atomic, string), confirmations, pending, failed,
                                      account, subaddrIndex ("3" | "1,4"), …}]}
list_wallets()           {wallets: [{name, network ("" = never opened), label, viewOnly, restoreHeight, address}]}
```

## The lp half (`monero_backend_lp.nim`)

**Two call modes.** A tick never waits on a wallet.
- `cmPump` is used by the confirm pump and the card's projection.
  - It returns the newest reply no older than 15 s.
  - It fires an async call at most every 2 s, and the reply lands in a queue.
  - Nothing fresh reads as unread.
- `cmNow` is used for a person's action: propose, agree, share an address, confirm by hand.
  It is one bounded `lp_invoke`: 5 s for a read, 20 s for `receive_info` and
  `create_subaddress`, which take the wallet lock with no deadline.

**A cached reply is bound to the wallet it came from.** History and `receive_info` are used
only while the wallet `wallet_status` named when they were asked is still the one named, and
only after a status reply read after them says so too. A status naming another wallet or
network drops them all.

**Residual risk.** Switching A → B → A within about 2 s could pass B's history as A's.
Each switch needs a password in the wallet app.

## Hosted JSON shapes (for the UI)

**`coordinate_propose_split(chain, total, shares_json, memo)`** with chain `monero:<ref>`, or
"" when the compose policy is `monero-split`, which means stagenet.
- `total` and the shares are atomic units.
- `shares_json` is any form a split takes: an array of identities, `{parties,
  creditorShares}`, `{shares:[{who, amount}]}`, or `{creditor}` (on their behalf). Even
  shares are made distinct.
- No `fiat` and no `asset` other than XMR.
- On success it mints payTo, labelled `muster:req-<16 hex>`, and returns the intent id.
- On failure it returns `{error, detail, chain}`. Wallet errors add
  `request:"monero.wallet.unlock"` and `install:"monero_wallet_ui"`, and, except while the
  wallet is unread or busy, which wallet to open (`xmrUnlockTarget`, exo-dcc.20):
  `wallet` (the one to name, or ""), `wallets` (several to pick from) and `noWallet` (none
  exists on the network: the UI raises `monero.accounts.manage`). The error codes:
  - `no-wallet`, `wallet-other-network`, `wallet-watch-only`, `wallet-unread`, `wallet-busy`;
  - `payto-not-mine`, `refused` (the driver's rule, e.g. equal shares);
  - `no-shared-address`, `not-admitted`, `bad-shares`, `bad-asset`.

**`coordinate_share_address("monero:<ref>")`** is "Share my Monero address"
(`xmrShareAddress`). It mints a fresh subaddress, labelled `muster:share`, held to the
chain's network and payTo rules, and posts `{kind:"address-share", asset:"XMR", chain,
address, form:1}`, author-signed. It returns `{address, asset, chain}`, or the refusal shape
above, with nothing minted or posted.

**`coordinate_settle_part(intent_id)`** on a Monero request sends nothing. It returns
`{payFrom:"your-wallet", uri, amount, to, chain, detail}`, or
`{error: not-agreed|not-a-party|refused, detail}`.

**`coordinate_report_paid(intent_id, tx)`** is "I paid", with `tx` a 64-hex txid or "".
- It returns `{state}`.
- Or `{error}`: `not-a-party`, `not-agreed`, `already-settled`, `bad-txid`,
  `not-a-monero-request`, `unknown-intent`.

**`coordinate_confirm_part(intent_id, part, tx)`**:
- `tx` "" is Mark received: the creditor's word, recorded with no reference.
- Any other `tx` reads the wallet now.
- It returns `{state}`, or `{error: "unconfirmed: pending: …" | "unconfirmed: wallet-other-network: …" | …}`.

**`coordinate_intents`**: a Monero request's object carries:

```
split: {total, asset:"XMR", payTo, memo, decimals: 12, symbol:"XMR", creditor, iAmCreditor, creditorAgreed,
        payToMine, creditorShare, expired, …,
        xmr: {network: "stagenet", chainLabel: "Monero stagenet", confirmDepth: 10,
              payment: null | {part, ok, uri, amount, payTo, why, reported, confirmed},   // MY share, if I owe one
              wallet:  null | {ready, detail, code, request, wallet?, wallets?, noWallet?}}} // on the creditor's client
parts: [{part, who, name, amount, settled, confirmed, tx, mine, …, uri, confirmations?}]   // uri "" until agreed
```

- `payment.why` is `not-agreed: …` until every party agreed.
- `wallet.request` is `monero.wallet.unlock` when opening a wallet would help; the code is
  `no-wallet`, `wallet-other-network` or `wallet-watch-only`. Then `wallet`, `wallets` and
  `noWallet` say which wallet (read on the tick, cached).
- `parts[].confirmations` (0–9), on the creditor's client only: the confirmations of the
  history row of exactly that share at payTo, while it is below depth
  (`xmrSeenConfirmations`). Absent when nothing is seen, the read is busy or unanswered, the
  wallet is on another network, or the part is confirmed. A count is never invented.
- `parts[].tx` is the confirming txid once confirmed, or the debtor's reported one before.
- `effect_summary` reads XMR in 12 decimals.

**`coordinate_readiness(intent_id)`**:
- The module item `monero_wallet_backend` carries `install: "monero_wallet_ui"`.
- The environment item `monero:<ref>`:
  - For the creditor it is met while their wallet is open on that network. It is missing
    with the `walletRefusal` reason otherwise, or unknown while unread.
  - For a debtor it is met: they pay from any wallet.
  - Not met, it carries `request: "monero.wallet.unlock"`, the remedy "open your Monero
    wallet … in Monero Wallet", and `wallet` / `wallets` / `noWallet`.
- The Connections panel grades the same environment with the same rule
  (`moneroWalletGrade`): the creditor's wallet on the chains they are owed on
  (`xmrOwedOn`), and met for a debtor. An unread or busy status is unknown.

**Settle-up** refuses a Monero chain with `{error: "not-netted"}`. It no longer treats any
non-LEZ, non-Bitcoin chain as EVM.

## Decisions made here

- **The subaddress label is `muster:req-<16 hex>`, not the intent id.** The intent id commits
  to payTo, which is the address being minted. The label hashes chain, total, memo and a
  sequence number.
- **A view-only wallet neither vouches nor confirms**, as the brief asks. It could see
  incoming transfers, but it cannot spend what it receives.
- **A row on several subaddresses is not matched.** Its amount is their sum. The creditor
  can still Mark received.
- **`subaddrIndex` must be exactly `[payTo's index]`, account 0.**
- **`acceptablePayTo` is cached in the driver** (a threadvar, bounded). It decompresses two
  points in pure Nim, and the fold asks the driver about one effect many times. With the
  cache a Monero request folds in ~3.5 ms, the same as an EVM split.

## The UI (exo-dcc.5, second half)

- **Home's "Request a payment" verb** opens the room's split composer under the **Request**
  kind: one person pays, the requester is not in it. It prefers the `monero-split` kind when
  the room offers it; the room's "Settles on" row still picks any split rail.
- **The Split composer on Monero**: the total in XMR, 12 decimals, by string arithmetic. No
  token, no fiat quote, no settle-up and no "who paid" (the module refuses or never nets
  them). payTo is never typed: Propose calls `coordinate_propose_split("", …)`, and the
  module mints it from the proposer's open wallet. A wallet refusal is said in plain words,
  with **Open Monero Wallet** (when `request` is set) and **Install monero_wallet_ui** (when
  the wallet did not answer at all).
- **The card**, for the debtor: `split.xmr.payment.uri` as a QR code (`QrCode.qml`, pure
  QML/JS, decoded back by `ui/tests/qrcode-test.sh`), as text, and **Copy link**; then
  **I paid** with an optional 64-hex txid, the new backend slot `reportPaid` →
  `coordinate_report_paid`, landing on `splitJson {op: "report"}`. For the creditor: each
  part's state (reported, confirmed by their wallet at 10, or marked received), their
  wallet's state from `split.xmr.wallet`, Open Monero Wallet, and Mark received as before.
- **Readiness**: the module item's Install names `monero_wallet_ui`; an environment item
  carrying `request: "monero.wallet.unlock"` shows Open Monero Wallet instead of Open
  settings.
- **Which intent opens the wallet.** `monero.wallet.unlock` needs `{wallet: <registry
  name>}`; Monero Wallet answers `bad_request` without one. Since exo-dcc.20 the module
  names it (above). The UI raises `monero.wallet.unlock {wallet}`; with several, the card
  and the room's remedy show one **Open <name>** button each; with none at all, **Set up a
  wallet in Monero Wallet** raises `monero.accounts.manage`, as does a list that did not
  answer. Both are in `ui/metadata.json`'s `uses`.
- **n of 10.** The creditor's card shows "seen, n of 10 confirmations" for a part their
  wallet sees below depth, and "says they paid (…) — seen, n of 10 confirmations" once
  reported.
- **Seen on display (2026-10-09, Basecamp 0.3.2 on Xvfb, with the Monero stack and a fresh
  stagenet wallet; the second member a standalone runner window on the same local
  network).** Home's verb opens the room on Request and Split (Monero). With the wallet
  closed, Propose is refused with `no-wallet`; Open Monero Wallet raises
  `monero.accounts.manage`, Basecamp asks "Use this app? Muster wants to
  monero.accounts.manage" and opens Monero Wallet. With the wallet open, Propose mints a
  real stagenet subaddress; the debtor's card shows the QR (zbarimg reads it back as the
  projection's `uri`, byte for byte), the link and I paid; the creditor's card shows "says
  they paid", then, with the wallet closed, the warning, Open Monero Wallet, and the
  readiness row's Open Monero Wallet; Mark received makes it final on both.
- **Two fixes the display found.** `coordinate_set_policy("monero-split")` took the EVM
  RPC's chain and refused (`splitChainFor` now defaults a Monero kind to stagenet), and the
  room snapped a fresh request room back to "Split (Ethereum)" before the module's answer
  arrived (`Room.requestedPolicy`).
- **The rough edges the display found, fixed in exo-dcc.20** (module test
  `xmr_request_edges_test`, the offscreen harness 116/116):
  - The wallet to unlock is named (above).
  - n of 10 (above).
  - **"Share my Monero address."** The address-request card asks for a Monero address on its
    chain and its button reads Share my Monero address; the module mints it. A refusal says
    why under the room, with Open Monero Wallet naming the wallet. A Monero address-share
    offers no "Use as recipient", since muster never sends Monero. The Split composer on
    Monero offers "Who paid the bill?". For someone else it is paid at the Monero address
    they shared for the room's chain, with **Ask <name> for a Monero address** (an
    address-request of them alone) until they have, and Propose off meanwhile. Their client
    agrees only while their wallet lists it (`payto-not-mine`), as the EVM and BTC splits do.
  - The Connections panel's Monero row is graded from `wallet_status` (above), not "this
    host cannot read a Monero wallet".
  - Room history: a Monero debtor's report reads "Bob says they paid" ("You said you paid")
    until the creditor's wallet confirms the part, then "settled their part". Another
    family's report is unchanged.
  - The wallet note ("Monero Wallet is open: …") expires. A newer split or share answer, or
    a change in a request's wallet state, makes it stale, and an answer over two minutes
    old is not shown.

## Not built yet

- **A live stagenet run**: two runners in Basecamp, a stagenet
  wallet in Monero Wallet, a payment from another wallet, and 10 confirmations. Still unknown:
  whether an incoming transfer appears in `history()` before it confirms (the 10-block rule
  does not depend on it), and what lp actually delivers for `history()` at size.
- **Paying from Basecamp's own wallet** (`exo-dcc.6`), after the upstream review intent.
- **Mainnet** (`exo-dcc.8`). The driver accepts the mainnet CAIP-2 already; the hosted
  default is stagenet.
- **The audit file for split families** (Phase 4).
