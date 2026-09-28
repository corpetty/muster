# A real LEZ wallet: scanning, proving, saving, and naming its accounts (2026-09-28)

Found running the private split on `testnet.lez.logos.co` across two instances
(`scripts/split-lez-testnet.sh`, exo-14d), with `lez_core` 0.4.0 (the runner's bundle)
over the `lp_*` host. The fake LEZ core modelled the zone's shape correctly, and in each
place below it was kinder than the zone. Each finding has a fix and a red-first test
(`split_lez_zone_test`, `wallet_lez_test` §8).

## 1. A fresh wallet scans from block 0, and one jump to the tip does not fit a call

`create_new` starts `get_last_synced_block` at **0**. The testnet was at block ~29,100
(about one block a minute during the run). The scan's cost, from `lez_core`'s own
"Synced to block N in Xs" lines:

| | steps (500 blocks) | total scan time, 0 → tip | per step |
|---|---|---|---|
| creditor A | 59 | 122.8 s | 1.6–4.6 s (first steps slowest) |
| debtor B | 59 | 132.9 s | 1.6–7.4 s |
| a bare wallet, no runner (a C probe on `wallet_ffi`) | — | — | 250 blocks ≈ 1–2 s; 5,000 in one call 13.6 s |

`lez_core` writes `storage.json` after **every** block it syncs ("Stored persistent
accounts at …" once per block), which is most of the cost.

So `sync_to_block(tip)` from a fresh wallet takes ~2 minutes, far over the 15 s read
budget, and a timed-out call leaves the wallet busy behind it (`lez-core-error-conventions.md`
§4). **Walk in bounded steps** (`walkSync`: 250 blocks, a 3 s budget per call) and report
"still catching up (block N of M)" as its own state: it is neither a failure nor
"nothing arrived", since a note may sit in a block not yet read.

**Pacing is what makes it slow, not the work.** B's scan took 7 minutes of wall time for
133 s of scanning, because it only advanced when a pay attempt retried (every 10 s). The
fix is a pump that keeps a member's scan moving while a private split waits on them
(exo-270a), never while their wallet proves (the wallet is serialized, and a scan queued
behind a proof times out).

## 2. Proving: minutes, the whole machine, and nothing else meanwhile

| proof | from → landed | duration |
|---|---|---|
| shield (public → own key node), 150 units | ~15:43 → 15:49:14 | ~6 min |
| private transfer, 50 units | 15:56:00 → 16:03:55 | ~8 min |

While proving, the `lez_core` host process held **~10 cores and ~9 GB RSS**. Anything
else on the machine slows it: do not rebuild the runner or run the suite in parallel.
The transfer returns only when the proof and submission are done (`lp_invoke_async`,
900 s budget); the result's `tx_hash` is the zone's transaction.

## 3. Money received privately lands at a discovered account — including your own

A shielded send picks a random identifier for the recipient, so the note lands at an
account id the recipient never created and finds by scan (`list_accounts` after
`sync_to_block`). That is also true of **a shield to your own key node**: B's faucet money
ended up in a discovered account, and the shielded account muster had created stayed at
0. A payer must therefore spend from whichever single note covers the amount (a transfer
draws on one note), not from "its" shielded account (exo-9b7).

What the creditor's scan sees — **verified by the run**: a discovered private account
whose `get_private_account_keys` is the key node the payer sent to, with a balance of
exactly the amount. That is what the private split matches a share by.

## 4. The wallet is in memory until you say `save`

After `wallet_lez_setup` created, registered and funded B's public account — the
sequencer showed 150 in it — `.run/lez-split/B/lez/` held only `config.json`. `lez_core`
writes the wallet (keys included) only on `save` or as a side effect of a sync; a crash
before then loses the keys of a funded account. Save after every change: account
creation, a faucet claim, a landed transfer (exo-2ce).

## 5. Labels: the wallet's own names, and `add_label` always says yes

A persisted wallet outlives the adapter over it, so muster must find the accounts it made
before, or each launch mints (and, for a public account, **registers on chain**) a new
pair and moves a creditor's payTo. `lez_core` 0.4.0 has persistent labels. Read from its
source (`src/lez_core_module.cpp`), because the LIDL says only `-> tstr` / `-> int`:

- `resolve_label(label)` returns `"Public/<hex>"` or `"Private/<hex>"`, and `""` when the
  label is unknown;
- `add_label(label, id, is_private)` returns **0 even when the wallet refused**. It logs
  the FFI error to stderr and then `return SUCCESS;`. This contradicts the int-convention
  table in `lez-core-error-conventions.md` §1 for this one method.

So a label counts only once it resolves back to the account (`LpLezCore.labelAccount`,
exo-884).

## 6. The faucet

The pinata lives at hex `cafecafe…cafe` (base58 `EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7`),
held ~1.48M units, and pays **150 per claim**. Its challenge is 33 bytes of `data`:
difficulty (3 zero bytes on the day), then a 32-byte seed that rotates per claim.
`get_account_public` returns `data` as **hex**, while the sequencer's `getAccount` returns
it as an array of byte values. `pinataSolve` found a solution in 7.5 s, on the module
thread and inside the UI's 20 s call. An unlucky seed can outlast that call while the
claim still goes through, so treat an empty answer as "in flight", not "retry".

## 7. Where the logs are

The UI backend's `qInfo` lines do not reach the runner's log; the module's `MUSTER-LP` /
`MUSTER-LEZ` lines (stderr, under `MUSTER_LP_DEBUG`) do, and so do `lez_core`'s own.
An offscreen self-test must read what it asserts from the module's lines.
