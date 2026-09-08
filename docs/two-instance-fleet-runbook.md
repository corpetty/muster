# Two-instance live run over the Logos delivery fleet

Two muster instances converging on one real intent, over encrypted transport, across two
separate hosts — the last-mile proof of P3 (R-4/R-6). Discovery is handled by piggybacking
off the public **Logos delivery fleet** (`infra/fleets/`), so there's no bootstrap node to
run. Each instance is its own identity + wallet; together they coordinate one Safe intent,
and — with anvil up — settle it on-chain from an in-app Approve.

> Runs on any box with a display (the standalone runner is a GUI app). Needs internet to
> reach the fleet. `make build` once first (minutes; caches).
>
> **Status (2026-09-08):** the membership half — join → ask → admit → both at two members —
> **works over the live fleet.** The Safe-txn half (propose → Approve in-app → settle) works
> too: `make run-fleet` now **auto-seeds** alice/bob as anvil Safe owners 0/1 (exo-001), so
> an in-app Approve recovers to a real owner and the 2-of-3 settles on-chain. Cross-host
> delivery rides **store catchup**, tightened to a ~1s poll, so a request/message shows up in
> **about a second** — chat cadence. Tune with `MUSTER_CATCHUP_MS` (default 1000, floor 200).
> The six transport fixes that got us here, and every gotcha, are in
> `docs/labbook/two-instance-live-wire-blockers.md` (read the SOLVED box before touching the
> transport). For a no-GUI convergence check, `./scripts/two-instance-proof.sh`.

---

## 0. One-time build

```bash
make build
```

Minutes on a cold cache, seconds after. Do this once; `make run-fleet` reuses it.

## 1. (For on-chain settlement) bring up anvil + the Safe fixture

Skip this if you only want to prove membership + coordination. Needed for step 8 (Settle).

```bash
infra/anvil/devnet.sh
```

Leave it running in its own terminal. It starts anvil and deploys the MiniSafe at
`0x5FbDB…` with owners = anvil accounts 0/1/2 and threshold 2-of-3. muster talks to it over
the default RPC (`http://127.0.0.1:8545`); change it in **Settings → RPC endpoint** if yours
differs.

## 2. Launch two peers on the fleet

Two terminals. Each boots already pointed at the fleet (`MUSTER_DELIVERY_CONFIG`, seeded
from `infra/fleets/logos.test.json`) **and** seeded as an anvil Safe owner:

```bash
make run-fleet PEER=alice
```

```bash
make run-fleet PEER=bob
```

`alice` auto-seeds as owner 0, `bob` as owner 1 (well-known anvil dev keys — never real
funds). Any other `PEER` gets a fresh random identity; pass `SEED=0x…` to seed it explicitly.
`FLEET=logos.dev` selects cluster 3 instead. `infra/fleets/refresh.sh` re-pins the node list
when peer ids rotate (silent discovery failure is the symptom).

> **Re-seeding.** Seeding is honoured only when minting a *fresh* identity. If a peer already
> ran unseeded (random identity), wipe it first: `make clean-peer PEER=alice`, then relaunch.

**No-rebuild alternative** (already on the built runner, don't want the fleet baked in): start
plain peers and paste the fleet config by hand — see *Appendix: Settings paste* below.

Give each window ~20–40s after launch to find fleet peers before starting the flow.

---

## The flow

### 3. Both open the SAME room

Type the **same topic string** in each window. Any string works — muster normalizes it to a
valid Waku content topic (`/muster/1/<name>/proto`) internally, so a bare word (`demo-1`), a
dotted name, or an already-valid `/app/ver/name/enc` topic all route, **as long as both sides
type the same thing**. (Hard-won: raw dotted/bare topics silently don't shard — see the
labbook.) Each instance boots its delivery node on first join and connects to the fleet.

Note: each side starts its *own* single-member room on that topic — they can't read each
other until one admits the other (the handshake, next).

### 4. Alice founds, Bob asks in

Pick one side as founder — say **Alice** — and leave her be. In **Bob's** scope panel (right),
click **"Ask to join this room"** — Bob announces his encryption key on the topic. *(Only the
joiner asks. Don't have both sides admit each other — one admitter keeps a single shared
epoch.)* The backend re-announces every ~5s until admitted.

### 5. Alice admits Bob

Within a second or two (store poll) Bob appears under **"Waiting to join"** in Alice's scope
panel (`· owner` if his binding recovers to a Safe owner, F-9, advisory). Alice clicks
**Admit** — admission follows *"a member decides"*: any **valid** binding is admitted, not only
Safe owners. This re-keys the room forward (epoch 1 = {Alice, Bob}); Bob gets only the new
epoch, never Alice's earlier lineage (F-16). **Both rosters now show two members — this is the
working two-instance proof.**

### 6. Alice proposes a Safe payment

In Alice's composer, propose a Safe transaction (the walkthrough's default is fine). The
propose event is sealed under epoch 1 and relayed through the fleet. Her room shows a proposal
card at `0 / 2` approvals.

### 7. Both approve in-app — no paste

Within a second or two Bob's room shows the **same intent** — same id, same effect, same
re-derived `safeTxHash`, `0 / 2`. *This is the cross-host proof: the encrypted intent crossed
two real nodes and both folded it identically (`state = reduce(log)`).*

Now **each** side clicks **Approve** on the card. Approve signs the re-derived `safeTxHash`
with your own keystore key in-app — no signature to copy or paste. Because alice/bob are
seeded owners 0/1, each signature recovers to a real Safe owner (the driver refuses a
non-owner — that's F-9 working). At 2 of 3 the card folds to **Ready** on **both** instances.

> Pasting is still available as an *advanced* fallback (a Safe owner signing off-app, on
> another device): the **"Paste a signature instead"** toggle under the card.

### 8. Settle on-chain → Paid

On the **Ready** card, click **Settle on-chain** (present only while the intent is executable).
muster re-derives the `safeTxHash`, assembles the Safe `execTransaction` from the two folded
owner signatures, submits it through the RPC, and reads finality from the receipt (R-8, never
asserted). The card reports honestly, and the outcome line **stays on screen** through the
state change:

| you see | it means |
|---|---|
| **✓ Paid — settled on-chain.** + `✓ Settled on-chain (final)` + tx hash | the `execTransaction` mined, status 1. The card advances to **paid**. |
| **Submitted — awaiting finality…** | submitted, receipt not seen within the bounded poll (~4s). It'll converge as the fold catches up. |
| ⚠ **On-chain execution reverted — the Safe rejected it** | the tx mined but reverted (e.g. bad nonce, `checkSignatures` failed). |
| ⚠ **Not enough owner signatures — have N of M…** | fewer than the threshold of *real-owner* signatures folded — usually a peer wasn't seeded as an owner (see step 2 re-seeding), or someone hasn't Approved yet. |
| ⚠ **Couldn't reach the chain (RPC). Is your node running?** | anvil/your RPC is down or the endpoint is wrong (step 1, or Settings → RPC). |

That last column is the point of the exo-837 fix: Settle **always tells you why**, and the
result no longer vanishes the instant the state moves off executable.

---

## Resilience (R-4/R-6)

After step 6, **kill Alice** (close her window) mid-collection, then relaunch her on the same
user-dir (`make run-fleet PEER=alice`) and rejoin the topic. Her log rebuilds from the keystore
+ the fleet's store, and Bob's contribution still lands — the intent converges regardless of
who was online when.

## If it doesn't converge

All six known transport blockers are fixed in the runner (token, store catchup, request retry,
topic normalization, admit model, fleet discovery). If it still stalls:

- **Bob never sees the proposal / Alice never sees the join request:** first give it longer —
  cross-host is store-catchup-paced (~1s per poll, but fleet peering can take 30–60s on a cold
  node before the first message can arrive). Then confirm both are on the same `FLEET`/cluster
  and typed the **same topic string**, and re-pin with `infra/fleets/refresh.sh` (rotated peer
  ids are the usual cause). With `MUSTER_LP_DEBUG=1` the runner logs
  `MUSTER-LP pending=N members=M` — that's the tell.
- **Admit does nothing / "unverified":** the binding failed to verify (expired, or malformed
  over the wire). Have Bob click **Ask to join** again — bindings carry an expiry, and the
  backend re-announces every ~5s, so a fresh ask should land.
- **Node never boots (no fleet traffic):** confirm the delivery config actually took — Settings
  → **delivery** should show the fleet config, not `{}`. On the `make run-fleet` path the target
  echoes the fleet. If it boots but never connects, the embedded-lp module **token** didn't save
  — check the `lp_token_save` path in `muster_gen.nim` (a regen drops it; see the labbook).
- **Settle says ⚠ Not enough owner signatures:** a signer isn't a real Safe owner. Confirm both
  peers were seeded (step 2 echoes "seeding … as an anvil Safe owner"); if one ran unseeded,
  `make clean-peer PEER=<x>` and relaunch. And confirm **both** clicked Approve (2-of-3 needs
  two real-owner signatures).
- **Settle says ⚠ Couldn't reach the chain:** anvil isn't up (step 1) or the RPC endpoint is
  wrong (Settings → RPC).
- Background on the original blockers and why the fleet closes discovery, plus every gotcha and
  the self-test rig: `docs/labbook/two-instance-live-wire-blockers.md`. The owner-seed mechanism
  is `docs/labbook/safe-in-app-onchain-seed.md`.

---

## Appendix: Settings paste (no-rebuild path)

If you're on the currently-built runner and don't want the fleet baked into the launch, start
two plain peers and set the fleet config by hand. (This path does **not** auto-seed owner keys —
pass `MUSTER_DEV_SECP_KEY` yourself, or use `make run-fleet` above for the seeded path.)

```bash
make run RUN_DIR=$PWD/.run/alice
```

```bash
make run RUN_DIR=$PWD/.run/bob
```

In **each** window: open **Settings**, either click **"Use the logos.test fleet"** or paste the
delivery config into the **delivery** field, then **Save**. (It persists to that peer's
`settings.json`, so it's one-time per user-dir.) To paste the exact value — don't hand-copy it,
peer ids rotate:

```bash
python3 -c 'import json; print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))'
```

It looks like `{"mode":"Core","preset":"logos.test","entryNodes":["/dns4/node-01.…","…"]}` — the
six `logos.test` fleet nodes. Re-pin with `infra/fleets/refresh.sh` if it's stale.
