# Monero multisig, coordinated in the room (exo-dcc.34)

Status: **built, and run on Monero's stagenet through the real UI (2026-10-17); shipped in every
release since Muster 0.3.3 (2026-10-23). Stagenet only, labelled experimental and pre-FCMP++
(ADR-020).** Family `monero.multisig-coordinated`, kind `xmr-msig`; actions `setup` and `spend`
(`contracts/actions/family/monero.multisig-coordinated.json`). The registry calls it `partial`,
on purpose: it stays so while upstream calls the scheme experimental and FCMP++ is ahead
(§9). §6 maps the design to the code, §7 is what a person sees, §8 where it has run. The how-to
is `docs/runbooks/xmr-multisig.md`.

## In short

A **room treasury in XMR.** Three people (any M of N) set up a Monero multisig wallet together
from a Muster room, fund it, and spend from it once enough of them agree.

- **Each person's own Monero wallet holds their key.** It is their own `monero-wallet-rpc`,
  pointed at by a setting. Muster holds no Monero key and no multisig state, and never signs a
  Monero transaction.
- **The room does the coordination,** which is the hard part of Monero multisig. It carries the
  setup rounds, the sync data and the partly signed transactions between the wallets, in order,
  encrypted to the members, with each step signed by whoever sent it.
- **Every co-signer's own wallet checks the spend before it signs.** The room agrees the payment
  first: recipient, amount and a fee cap. Each signer's wallet then reads the transaction it is
  asked to sign (`describe_transfer`), and signs only if it pays exactly what was agreed.
- **It is a feature, not a product.** It shows what Logos makes possible: private, authenticated
  coordination among people who hold their own keys. There is nothing here to sell.

It is for stagenet only, until Monero's own multisig is no longer experimental (§9).

## 1. Why this note exists

`monero.multisig` stays `reject`. ADR-018 gives four reasons:
- Upstream calls the scheme experimental and warns a malicious member can steal funds.
- Basecamp's Monero wallet stack exposes no multisig, so Muster would have to run its own wallet2 as a second key holder.
- It fights invariant 2: a signature has no expiry.
- It fights invariant 4: each wallet keeps secret sync state.

We re-assessed on 2026-10-16 against three sources: Monero's multisig docs, the Multisig Messaging System (MMS) guide, and monero-multisig-gui. The rejection holds; the docs' warning is unchanged since the 2022 fixes (PR 8149).

The two tools point at a different role for Muster. The hard part of Monero multisig is coordination: passing setup data, sync blobs and partly signed transaction sets between people, in order and privately.
- **MMS** (2018) carries them over PyBitmessage.
- **monero-multisig-gui** (2025) embeds wallet2, so it holds the keys itself, and runs one HTTP API per peer over Tor onion services.

A Muster room is already an end-to-end encrypted channel among authenticated members. This note made the case for **the room as the coordination layer, with each member's own multisig wallet holding the keys.** ADR-020 accepted it on 2026-10-16.

## 2. The shape

The on-chain scheme is the same as `monero.multisig`; only Muster's role differs. It mirrors seam S8, the Bitcoin "sign outside Muster" PSBT path.

- **Keys.** Each member runs their own Monero multisig wallet: `monero-wallet-rpc` today (setting `xmr-msig-rpc`); `monero-wallet-cli` and monero-multisig-gui share the format but are not driven by Muster; the platform's once `monero_wallet_backend` exposes multisig (§5).
  - Muster holds no key and no multisig state.
  - That is why this variant does not hit ADR-018's second-key-holder objection.
- **Setup.** The room agrees on the network, M and the N members. Each wallet then runs:
  - `prepare_multisig`;
  - `make_multisig`;
  - `exchange_multisig_keys`, once or twice.

  The room carries each round's output to the others, in order, and records who sent it. Setup ends when all N wallets show, and disclose, the same address.
- **Spend.**
  1. The room agrees the payment first: recipients, amounts and a fee cap.
  2. The signers' wallets re-sync with `export_multisig_info` and `import_multisig_info`, with the room carrying the blobs.
  3. One wallet builds the transaction set (`transfer`).
  4. Each signer's wallet runs `describe_transfer` on the set and signs with `sign_multisig` only if the recipients and amounts are the agreed ones. `describe_transfer` takes a `multisig_txset`, per the wallet RPC docs.
  5. Any wallet submits it with `submit_multisig`.
  6. One spend at a time.
- **Invariant 1** moves into the member's wallet. Muster cannot decode a Monero transaction set without view keys, so each member's own wallet does the "re-derive and refuse on mismatch" check. This is the same way the payee's wallet confirms receipt in `monero.split`.

## 3. What it cannot fix

- **The warning.** A malicious member may be able to steal funds. Stagenet only, with the warning on the card, until upstream drops it.
- **Serial spends.** Every spend needs a fresh sync, and the docs say "only do it for 1 transaction at a time". The card shows one spend in flight.
- **No expiry.** This is invariant 2: a collected partial signature stays usable until the inputs are spent. The room can only bound it socially: an agreed deadline, and re-syncing after a cancel invalidates stale sets.
- **Membership change** means a new wallet and moving the funds.

## 4. The questions the ADR answered

1. **Does `describe_transfer` on a part-signed `multisig_txset` report what the signers will sign? Yes (2026-10-16).** On a regtest 2-of-3 with monero-wallet-rpc v0.18.5.1, both co-signers' wallets reported exactly the agreed recipient, amount, fee and change, unsigned and signed, and the chain paid exactly that. From the source, a co-signer signs a transaction rebuilt from the same construction data `describe_transfer` reads (`docs/labbook/monero-multisig-describe-transfer.md`, `infra/monero/multisig-regtest.py`).
   - A set whose amount or recipient differs from the agreement is refused before signing. This is held against a fake wallet that tampers with the set (`xmr_msig_spend_test`); no real wallet has been made to produce one.
   - monero-multisig-gui's sets are untested.
2. **What sizes and timings does the room carry? Measured 2026-10-16** (`docs/labbook/monero-multisig-describe-transfer.md` § Sizes):
   - setup is negligible;
   - a sync blob is about 360 B per output, per member;
   - a transaction set is about 2.6 KB per input.

   Delivery caps a message at 150 KiB, so every blob is carried in parts of 90,000 hex characters (45 KB), each part signed by its author, and read once every part is in (`blobEvents` / `readBlob`, `coordination/xmr_msig_spend.nim`).
3. **The members run their own wallet software, outside Basecamp, until the platform exposes multisig. Acceptable for the campaign? Yes, for now (operator, 2026-10-16), with in-room warnings** that say how this differs from Muster's other accounts. The member's own wallet holds the key and the multisig state; upstream calls the scheme experimental; spends go one at a time.
4. **Does FCMP++ change the multisig steps enough to wait for it? Don't wait (ADR-020).** FCMP++ forked on stressnet on 2026-10-05, with no mainnet date. The scheme-specific part (the wallet calls and the per-spend sync) is redone when FCMP++ multisig is defined; the room plumbing, the agreement and the describe-check stay. The UI says so on every setup: "Built before FCMP++: the wallet will need re-creating after Monero's upgrade."

## 5. Upstream

Two requests are open, unanswered as of 2026-10-30:

- **[logos-co/logos-monero-wallet-backend#8](https://github.com/logos-co/logos-monero-wallet-backend/issues/8)** (2026-10-16): expose multisig in `monero_wallet_backend`, gated like sends: the approver role, with a review in the wallet app. Muster would then use the platform's wallet, as it does for `monero.split`, and people would not need to bring their own. The setting `xmr-msig-rpc` would gain a platform option; the room plumbing is unchanged.
- **[logos-co/logos-monero-wallet-ui#10](https://github.com/logos-co/logos-monero-wallet-ui/issues/10)**: the wallet app reviews a send another module prepared (`monero.wallet.review_send`). This pairs with #8.

## 6. As built

| Step | Code | Held by |
|---|---|---|
| The effect, the refusals, the two rounds, the describe-check | `module/src/drivers/xmr_msig.nim` | `xmr_msig_test`; conformance |
| The member's own wallet: setup, sync, build, describe, sign, submit, confirmations. A busy wallet, or one whose node went away, waits; it is never refused | `module/src/wallet/xmr_msig_wallet.nim` (setting `xmr-msig-rpc`) | `xmr_msig_regtest_e2e` (real wallets) |
| Setup over the room: open with the members picked, consent, each round in order, each member's disclosure | `module/src/coordination/xmr_msig_setup.nim`; `xmr_msig_setup_open` / `_join` / `xmr_msig_setups` | `xmr_msig_setup_test`; `xmr_msig_setup_regtest_e2e` |
| The account acted from only once every member disclosed it; its check says what it rests on (every member's own wallet reports the address; no chain read can check a Monero multisig) | `xmrMsigAccountOf`, `xmrMsigDisclosureCheck` in `coordination/accounts.nim` | `xmr_msig_setup_test` §4 |
| A spend: signer set, sync, build, check-then-sign, round 2, submit, final at 10, one in flight. Blobs in signed parts | `module/src/coordination/xmr_msig_spend.nim`; `coordinate_propose_xmr_msig` / `xmr_msig_spends` | `xmr_msig_spend_test`; `xmr_msig_spend_regtest_e2e` |
| The UI: Settings → Monero multisig wallet; the room's Monero multisig section (the four warnings, the member picker, set up, join, Send from the multisig); the card's Monero multisig block, with the no-expiry caveat | `ui/src/qml` (the room's accounts section, `MusterCard`) | the UI run on stagenet (§8); `scripts/ui-parity.sh` |

Two rounds. Round 1 is the agreement, by M members' room keys; the first M the fold counts are the signers. Round 2 is each signer's word that its wallet signed after the describe-check, signed under the driver's own tag, so a round-1 signature never stands in for it. Round 2 is published by the spend's own step, after the wallet signs, and never on the intents tick (`Driver.laterRoundsInApp`).

The run against real wallets on regtest is `infra/monero/regtest.sh up 4`, then `module/tests/run-suite.sh e2e xmr_msig_spend_regtest_e2e`. It takes about a minute. Traps found while building it: `docs/labbook/monero-multisig-in-the-room.md`.

## 7. What a person sees

Three people, each with their own `monero-wallet-rpc` on stagenet and a fresh, empty wallet, are in one room (the runbook's §0–§1).

1. **Point Muster at your wallet:** Settings → Monero multisig wallet.
2. **Set it up.** One member opens the room's details, then Add an account → Monero multisig. The section shows the four warnings, each on its own line:
   - "Your own Monero wallet holds the key, outside Basecamp."
   - "Monero multisig is experimental upstream: a dishonest member could take the funds. Stagenet only."
   - "One spend at a time, about 20 minutes each (10 blocks)."
   - "Built before FCMP++: the wallet will need re-creating after Monero's upgrade."

   They pick who takes part (they always do), set M, and press **Set up a 2-of-3 Monero multisig**. The others press **Join**. No wallet is asked anything until all have joined; then each member's round count rises, and the setup ends with one address, **disclosed by 3 of 3**.
3. **Fund it** from any stagenet wallet, and wait 10 blocks: Monero locks a received output for 10 blocks.
4. **Spend.** Any member presses **Send from the multisig**: recipient, amount, fee cap (0.001 XMR by default), memo. The card says what it pays, for example *a Monero multisig payment: 0.0005 XMR → 57VT…, fee at most 0.001 XMR*. Two members press **Approve**: the first two the room counts are the signers.
5. **The rest happens by itself.** The card's Monero multisig block counts up: **Synced**, **Signed** (each signer's wallet only after its own check), **Submitted**, then "Your wallet: seen n of 10" until final. Every member's card reads **Settled**.

## 8. Where it has run

| When | What | Result |
|---|---|---|
| 2026-10-16 | regtest, three real wallets, the room code in process (`xmr_msig_*_regtest_e2e`) | setup in five steps of every member; a spend in four to five steps, then 10 blocks |
| 2026-10-16 | stagenet, three fresh wallets against public nodes, the room code in process (`xmr_msig_stagenet_live`) | setup **149 s**; spent 0.001 XMR, fee **0.00003036**; final on every member about **13 minutes** after submitting |
| 2026-10-17 | stagenet, **through the real UI**: three runners, each with its own wallet and node, driven on virtual displays | set up, funded with 0.002 XMR, spent 0.0005 XMR; **Settled** on all three cards; the recipient's wallet saw it |

The 2026-10-17 run found five things, all fixed: a count printed as an id, a card that did not say what it pays, an account check that said "couldn't check", "Signers: 0 of 2 fixed" before anyone approved, and run-together warnings. A member who has gone away blocked a setup that named every member, so the setup form now picks its members (exo-dcc.34.6). Two transient node failures were treated as final on 2026-10-16; both now wait (§6). Details: `docs/labbook/monero-multisig-in-the-room.md` §7–§8.

## 9. Not done, and what mainnet needs

- **Mainnet waits** on Monero multisig losing its experimental status (in practice, FCMP++ multisig) and on Muster's mainnet gate for the Monero stack (`exo-dcc.8`).
- **The platform wallet:** until #8 lands upstream, members bring their own `monero-wallet-rpc`; Basecamp's Monero Wallet does not take part.
- **Untested:** sets from monero-multisig-gui, and a tampered set from a real wallet (the refusal is held only against a fake, §4).
- **A wallet's node going away** shows as the wallet's own message under "Your wallet:"; the UI cannot yet tell the member that their node is the problem (labbook §7).
- **Rework at FCMP++** of the wallet calls and the per-spend sync (§4.4).
