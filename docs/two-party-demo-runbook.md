# Two-party demo runbook — Safe + FROST with a second participant

The end-to-end demo: two participants coordinate a real transaction inside a shared
room and watch how the coordination policy changes what leaks. It has **two tracks**,
and they need different setup:

| Track | What it shows | Needs anvil? | Needs seeded keys? |
|---|---|---|---|
| **Safe** (on-chain 2-of-3) | An Ethereum multisig settling on chain — every owner's signature is disclosed on the public ledger | **Yes** (the MiniSafe fixture) | **Yes** — each peer must BE a real Safe owner |
| **threshold / FROST** (k-of-n Ed25519) | The same coordination reaching finality with a roster endorsement — the disclosure contrast (one aggregated key, not every signer) | No | No — any two peers who join the room *are* the roster |

The teaching beat is the contrast: **the room reaches the same decision two ways — settle
it on-chain as a Safe payment, or endorse it off-chain as a FROST statement — and you point
at what each one put on the wire.** (A payment *is* the on-chain settle, so it only goes
through the Safe; FROST doesn't touch Ethereum, so its version is the decision itself — a
statement the roster endorses. The composer enforces this: pick the **kind** and it offers
only the policies that fit it, so "an ethereum payment via FROST" — which never meant
anything — can't be built.)

Everything below uses the **public AppImage** (`result-appimage/logos-basecamp.AppImage`,
built with `make appimage`). Nothing here needs the nix build toolchain, so a colleague
only needs the AppImage file.

---

## Why seeding is needed (Safe track only)

The room's Safe is the anvil MiniSafe fixture: **2-of-3, owners = anvil accounts 0/1/2**,
at `0x5FbDB2315678afecb367f032d93F642f64180aa3` (hardcoded in
`module/nim-lib/muster_module.nim`). In-app approval reaches **executable** for any room
member, but the on-chain `execTransaction` only accepts signatures that recover to the
**real** owners — so to *settle*, each participant's in-app account must be one of anvil
0/1/2. The `MUSTER_DEV_SECP_KEY` env var seeds that account when the keystore is first
minted. The wrapper `scripts/demo-peer.sh` sets it for you:

| Peer | Seeds anvil owner | Address |
|---|---|---|
| `alice` | account 0 | `0xf39Fd6…2266` |
| `bob` | account 1 | `0x70997970…79C8` |
| `carol` | account 2 | `0x3C44Cd…93BC` |

Two seeded peers = 2 of the 3 owners = the 2-of-3 threshold. (Verified: each key derives
to exactly that owner.)

The **FROST/threshold track needs none of this** — its roster is built from whoever is in
the room, so the two peers' own identities are the signer set automatically.

---

## Scenario A — one machine, two instances (most reliable; use this for recording)

Local anvil, two isolated peers. Nothing crosses a network except the room itself (over
the public `logos.test` fleet, the default).

**1. Start anvil + deploy the MiniSafe** (one command; needs foundry):

```bash
infra/anvil/devnet.sh
```

Leave it running. It prints `SAFE_ADDR=0x5FbDB…0aa3` and `RPC=http://127.0.0.1:8545`
(the module's default — no RPC change needed on one machine). It must be a **fresh**
anvil for the Safe address to match; re-run it on a restarted anvil if in doubt.

**2. Launch two seeded, isolated peers** (two terminals):

```bash
scripts/demo-peer.sh alice --isolate --fresh
```
```bash
scripts/demo-peer.sh bob --isolate --fresh
```

`--isolate` gives each a separate `$HOME` (so two basecamp data dirs / two identities on
one machine); `--fresh` wipes that peer's prior identity so the seed key takes (the seed
is honored only when minting a new keyfile). On first launch each basecamp installs its
bundled modules — that's normal.

**3. In BOTH windows, open Muster and join the same room.** Click **Muster**, create /
join a room with the **same name** in both (e.g. `demo`). Give it a few seconds — the two
peers meet over the fleet and the roster shows **2 members** (ScopePanel). This is the
membership handshake.

Then run the two tracks (§ *Running the tracks* below).

---

## Scenario B — two machines, with a colleague ("doing it live")

Each person runs the AppImage on their own machine, so isolation is free (no `--isolate`).
Discovery is the public fleet, so **the FROST track works with zero shared infrastructure**.

**FROST track (no infra):**
1. Both: `scripts/demo-peer.sh alice` on one machine, `scripts/demo-peer.sh bob` on the
   other. (The seed key is unused by FROST, but harmless.)
2. Both open Muster and join the **same room name**. Wait for 2 members.
3. Run the FROST track below. Done — no anvil, no RPC.

**Safe track (needs a shared anvil):** the two machines must reach the same chain.
1. On **one** machine (the "chain host"), expose anvil on the LAN:
   ```bash
   ANVIL_HOST=0.0.0.0 infra/anvil/devnet.sh
   ```
   It prints `LAN_RPC=http://<host-LAN-IP>:8545`. (Firewall must allow 8545.)
2. The chain host runs `scripts/demo-peer.sh alice` (RPC default `127.0.0.1:8545` is fine
   for it). The **other** machine runs `scripts/demo-peer.sh bob`, then in Muster opens
   **Settings → Infrastructure → RPC endpoint**, pastes the `LAN_RPC` URL, and clicks
   **Save** (it persists). Now both peers act on the same Safe.
3. Run the Safe track below.

> If exposing anvil across machines is inconvenient, do the **Safe track single-machine
> (Scenario A)** and the **FROST track two-machine** — you still show both, and the
> FROST/no-infra contrast is the stronger teaching point anyway.

---

## The transaction pipeline — what you're watching

Both tracks drive the **same lifecycle**. Knowing the states makes the demo legible: you
can say exactly where you are and what each step put on the wire.

**Before the room — check the account.** Open **Muster → Account**. The **SAFE ACCOUNT**
card should show the 2-of-3 Safe you're coordinating (`0x5FbDB…0aa3`) and your own owner
address. If it says **"account not loaded"**, your keystore didn't open — fix that first
(see Troubleshooting), because nothing downstream will settle.

Then, inside the room, every proposal moves through these states — the proposal card shows
the current one on its status rail:

| State | What it means | On screen | Your move |
|---|---|---|---|
| **draft** | Composing a payment (amount + recipient), not yet shared | the composer / "Propose" form | fill it, click **Propose** |
| **proposed** | The effect is shared; your client **re-derived** the bytes to sign (the `safeTxHash` for Safe) | a card in the thread, `0/N` approvals, the re-derived hash | read the hash aloud — *your* client derived it, it wasn't handed to you (F-4) |
| **collecting** | Approvals are coming in | `k/N` approvals tick up as peers approve | **each peer clicks Approve** — auto-signs with its own key, no pasting |
| **executable** | Threshold met — enough valid signatures to act | the card flips to *executable*; **Submit** appears (Safe track) | Safe: click **Submit**. FROST: the round advances / the card completes |
| **submitted** | The on-chain `execTransaction` was sent (Safe only) | *submitted*, watching the receipt | wait ~1–2s |
| **final / paid** | Settled — Safe: receipt confirmed on chain; FROST: the k-of-n roster endorsement completed | *paid* / *complete* | narrate the disclosure contrast |

**Watch the disclosure, not just the state.** The card's **"What this needs / who will see
what"** box (open it with **Needs**) is the teaching surface: under **Safe** it names the
chain plus **both owner addresses and both signatures** as disclosed to the public ledger;
under **FROST** it's a single roster endorsement with **nothing on a public chain**.
Running the same payment under each policy and opening that box side by side *is* the demo.

---

## Running the tracks (same in both scenarios, once 2 members are in the room)

### FROST / threshold track

FROST endorses a **statement** — a decision the roster ratifies — not an on-chain payment
(it never touches Ethereum). So the FROST version of "pay 0.1 ETH to X" is the *decision*
to do so, phrased as a statement. That's the honest contrast with the Safe track's on-chain
settle.

1. Open the composer with **+**. For **Kind**, click **Statement**. The **"Endorse with"**
   row now offers only the roster policies — **Threshold · FROST · Attest · Unanimous** (no
   Safe: a statement settles nothing on chain). Click **FROST**. (Threshold is the
   single-round variant; FROST is the 2-round one.)
2. In **"what the room ratifies…"**, type the decision — e.g. `pay 0.1 ETH to 0x…70997970…
   from the group fund`. Click **Propose**. A proposal card appears inline in the thread,
   showing **round 1 of 2**.
3. **Both peers click Approve** on the card. No pasting — Approve auto-signs with each
   peer's own key. When both have approved, round 1 closes and the card advances to
   **round 2 of 2**.
4. **Both peers click Approve again** (round 2). The card reaches **complete**.
   → *Talking point:* the room reached the same decision as the Safe track, but finality
   here is a k-of-n **Ed25519 roster endorsement** — the coordination structure of a
   threshold Schnorr/FROST signature. Contrast with Safe: no per-owner secp signatures, no
   chain transaction, nothing on a public ledger. Same decision; one leaks every signer to
   the chain, the other leaks nothing.

   *(4 Approve clicks total for 2 members — once each per round. The card's
   "round R of N (M of 2 this round)" tells you where you are.)*

### Safe track (on-chain 2-of-3)

1. In the composer policy row, click **Safe**.
2. **Propose** the payment. The card shows the re-derived `safeTxHash` (F-4 — your client
   re-derived it, it wasn't handed to you) and 0/2 approvals.
3. **Both peers click Approve.** Each auto-signs the `safeTxHash` with its seeded owner
   key; the driver verifies each recovers to a real owner. At 2/2 the card goes
   **executable**.
4. Click **Submit** (the on-chain step). The module assembles `execTransaction` from the
   two owner signatures and sends it through the RPC; it watches the receipt and the card
   advances **submitted → paid**.
   → *Talking point:* that transaction is now on the public chain, and it disclosed **both
   owner addresses and both signatures**. Every participant in an Ethereum multisig is
   visible forever. That's the leak FROST closes.

---

## Troubleshooting

- **Account view says "account not loaded" (Safe/wallet do nothing).** The module's
  keystore couldn't open — almost always a **stale keyfile from an earlier run** whose
  passphrase doesn't match `demo-peer.sh`'s (`muster-demo`). And a keyfile that *does*
  exist makes the seed a no-op anyway (`MUSTER_DEV_SECP_KEY` is honored only on a fresh
  mint), so even if it opened you wouldn't be the anvil owner. Fix by launching with a
  fresh identity: `scripts/demo-peer.sh <role> --isolate --fresh`, or delete
  `~/.local/share/Logos/LogosBasecamp/module_data/muster_module/*/identity.mks` and
  relaunch. The module now reports this as a clear `keystore locked (…): … passphrase …
  does not match` line in the terminal instead of silently blanking the account.
- **Peers never reach 2 members.** They must use the **same room name** and both be on the
  same delivery config (default `logos.test` — leave it). Cross-host receive rides store
  catchup (~1s), so allow a few seconds. Check Settings → Infrastructure shows the same
  delivery config on both.
- **Safe Submit fails / card stuck at executable.** The signatures didn't recover to real
  owners: either a peer wasn't seeded (relaunch with `--fresh` so the seed mints a new
  identity), or the RPC isn't pointing at the anvil that has *this* Safe. Confirm the
  Safe exists: `cast code 0x5FbDB2315678afecb367f032d93F642f64180aa3 --rpc-url <rpc>` is
  non-empty. If the address is wrong, anvil wasn't fresh — restart it and re-run
  `devnet.sh`.
- **Seed didn't take (wrong owner).** `MUSTER_DEV_SECP_KEY` is honored only when a *new*
  keyfile is minted. Relaunch that peer with `--fresh` (Scenario A) or delete its
  `~/.local/share/Logos/LogosBasecamp/module_data/muster_module/*/identity.mks` and rejoin.
- **FROST card won't advance past round 1.** Both members must approve in round 1 before
  it advances; then both must approve again in round 2. Watch the "M of 2 this round"
  counter.
- **Two instances on one machine collide.** Always use `--isolate` (separate `$HOME`).
  Without it they share one basecamp identity.

---

## What's not covered / known limits

- **FROST here is a coordination-layer scaffold**, not production Schnorr aggregation —
  it models the 2-round k-of-n *structure* faithfully with Ed25519 roster signatures
  (`module/src/drivers/frost.nim` states the boundary). The disclosure contrast it
  demonstrates is real; the on-the-wire bytes are a stand-in for real FROST shares.
- **Repeated Safe settles work** (fixed 2026-09-11). Room proposals commit to the Safe's
  *live* on-chain nonce (`safeNonce`), read at propose time, so sequential settles each use
  the right nonce — no anvil restart needed between them. (Was: hardcoded nonce 0, only the
  first settle worked; verified fixed by `coordinate_submit_anvil`'s two-settle step.)
- **Safe address is fixed** to the anvil fixture; there's no in-app Safe-address setting,
  so the Safe track requires the anvil MiniSafe (not an arbitrary chain).
