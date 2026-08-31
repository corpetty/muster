# Two-instance live run over the Logos delivery fleet

Two muster instances converging on one real intent, over encrypted transport, across two
separate hosts — the last-mile proof of P3 (R-4/R-6). Discovery is handled by piggybacking
off the public **Logos delivery fleet** (`infra/fleets/`), so there's no bootstrap node to
run. Each instance is its own identity + wallet; together they coordinate one Safe intent.

> Runs on any box with a display (the standalone runner is a GUI app). Needs internet to
> reach the fleet. `make build` once first (minutes; caches).

## A. The frictionless path — `make run-fleet`

Each peer boots already pointed at the fleet (`MUSTER_DELIVERY_CONFIG`, seeded from
`infra/fleets/logos.test.json`). Two terminals:

```bash
make run-fleet PEER=alice
```

```bash
make run-fleet PEER=bob
```

`FLEET=logos.dev` selects cluster 3 instead; `infra/fleets/refresh.sh` re-pins the node
list when peer ids rotate (discovery silently failing is the symptom).

## B. The no-rebuild path — Settings paste

If you're on the currently-built runner and don't want to rebuild, start two peers the
plain way and set the fleet config by hand:

```bash
make run RUN_DIR=$PWD/.run/alice
```

```bash
make run RUN_DIR=$PWD/.run/bob
```

In **each** window: open **Settings**, paste the fleet delivery config into the **delivery**
field, Save. (It persists to that peer's `settings.json`, so this is one-time per user-dir.)
Generate the exact value to paste — don't hand-copy it, peer ids rotate:

```bash
python3 -c 'import json; print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))'
```

It looks like `{"mode":"Core","preset":"logos.test","entryNodes":["/dns4/node-01.…","…"]}`
— the six `logos.test` fleet nodes. Re-pin with `infra/fleets/refresh.sh` if it's stale.

## The flow

Do this once both windows are up (give each ~20–40s after joining to find fleet peers).

1. **Both** — open (or create) the **same room**: identical topic string in each, e.g.
   `/muster/live/demo-1`. Each instance boots its delivery node on first join and connects
   to the fleet. Note: each side starts its *own* single-member room on that topic name —
   they can't read each other until one admits the other (this is the handshake below).
2. **Alice founds, Bob asks in.** Pick one side as founder — say **Alice** — and leave her
   be. In **Bob's** window, in the scope panel (right), click **"Ask to join this room"** —
   Bob announces his encryption key on the topic. *(Only the joiner asks. Don't have both
   sides admit each other — one admitter keeps a single shared epoch.)*
3. **Alice admits Bob.** Within a few seconds Bob appears under **"Waiting to join"** in
   Alice's scope panel (`· owner` if his binding recovers to a Safe owner, F-9). Alice
   clicks **Admit**. This re-keys the room forward (epoch 1 = {Alice, Bob}); Bob gets only
   the new epoch, never Alice's earlier lineage (F-16). Both rosters now show two members.
4. **Alice proposes an intent.** Propose a Safe transaction (the walkthrough's default is
   fine). The propose event is sealed under epoch 1, relayed through the fleet.
5. **Bob receives it.** Within a few seconds Bob's room shows the **same intent** — same id,
   same effect, same re-derived `safeTxHash`, `0/​2` approvals. *This is the cross-host
   proof: the encrypted intent crossed two real nodes and both folded it identically
   (`state = reduce(log)`).*
6. **Collect signatures → executable.** Each owner signs the `safeTxHash` on their own
   device and contributes the 65-byte signature; the driver refuses a non-owner. At the
   threshold (2 of 3) the intent folds to **executable** on **both** instances — they've
   converged.
7. **(Optional) Settle on-chain.** From the room, submit the executable intent — muster
   assembles the Safe `execTransaction` from the folded signatures and sends it through the
   configured RPC. (Needs the anvil/Safe fixture up — `infra/anvil/devnet.sh`.)

## Resilience (R-4/R-6)

After step 4, **kill Alice** (close her window) mid-collection, then relaunch her on the
same user-dir and rejoin the topic. Her log rebuilds from the keystore + the fleet's store,
and Bob's contribution still lands — the intent converges regardless of who was online when.

## If it doesn't converge

- **Bob never sees the proposal / Alice never sees the join request:** discovery hasn't
  established. Give it longer (fleet peering can take 30–60s), confirm both are on the same
  `FLEET`/cluster and the exact same topic, and re-pin with `infra/fleets/refresh.sh`
  (rotated peer ids are the usual cause).
- **Node never boots (no fleet traffic):** confirm the delivery config actually took — the
  Settings **delivery** field should show the fleet config, not `{}`. On path A, confirm
  `MUSTER_DELIVERY_CONFIG` was exported (the target echoes the fleet).
- Background on the two original blockers and why the fleet closes discovery:
  `docs/labbook/two-instance-live-wire-blockers.md`.
