# RLN membership for logos.test (exo-eb6.3)

Status: **two of four decided (2026-10-01); R1 built and checked live (2026-10-01).**
§6 records the decisions, the design they lead to, and what R1 found; §5's questions 1
and 3 are still open.

## 1. Why it is needed

Since Testnet v0.3, `logos.test` rate-limits every message with RLN (Rate-Limiting
Nullifiers). A delivery v0.3.0 node on that preset:

- loads `liblogos_rln_module` ≥ 0.10.0 and `liblogos_lez_rln_module` ≥ 4.2.1;
- runs without a membership, but **sends nothing** until its RLN membership is `active`
  (or `grace_period`): it holds each message and retries ("Failed to attach RLN proof,
  retrying next round"), while its `rlnState()` reads `Ready`, which describes the RLN
  subsystem, not a membership. (The modules' docs read as "does not start"; R1's live run
  showed otherwise, §6.)
- attaches an RLN proof to everything it sends.

Proof *validation* is off at launch. The Logos blog says it switches on "roughly two
weeks after release", so about 2026-10-14. After that, a node without proofs, muster's
old delivery v0.2.0 client included, cannot publish on `logos.test`.

`logos.dev` runs no RLN, so muster now defaults to it (exo-eb6.2). It is the
bleeding-edge fleet, "redeployed freely and may break at any time", and on Testnet v0.3's
first day five of its six nodes were unreachable from here. `logos.test` is the fleet its
module's docs tell applications to build against.

## 2. How membership works (from the modules' own docs)

- **Two modules.** `liblogos_rln_module` manages membership: it generates credentials,
  keeps an encrypted keystore, registers, and makes proofs. `liblogos_lez_rln_module`
  talks to the on-chain RLN registry: chain reads, the Register transaction, and a faucet
  claim for the registry's payment token.
- **A registry on its own LEZ zone.** The `logos.test` preset names registry
  `logos:testnet:841312e9…c893`, on a zone with sequencer `http://209.38.241.182:3240/`
  and its own channel. That is **not** `testnet.lez.logos.co`, the zone muster's wallet
  uses.
- **Its own wallet.** The lez-rln module holds a LEZ wallet of its own, in-process,
  default home `<instance persistence path>/wallet-home`. It does not use `lez_core`,
  because a host has exactly one `lez_core` wallet handle.
- **Funding.** The node's wallet registers itself once its payer holds ≥ 2×10⁸ *native*
  LEZ on that zone (about 1.8×10⁸ at base fee 8, most of it refunded). Activation takes
  1–3 minutes after the funds land. Native balance enters an account only at genesis,
  over the bridge from the Logos blockchain testnet, or by transfer from an account that
  already has some. `LEZ_RLN_PAYER_KEY` imports one funded key at bring-up.
- **A keystore with a password.** Credentials live in an Argon2id-sealed keystore that
  must be unlocked (`unlock_keystore(password)`); proof generation then needs no
  password.
- **A membership app already exists for Basecamp.** `logos-rln-membership-ui` walks a
  person through it: a password, wallet setup, getting tokens, then registering. Its
  docs treat membership as the host's concern: one node, one membership, shared by every
  app on that host.

Sources: `logos-delivery-module` v0.3.0 `docs/pages/{rln,networks,run-node}.md`;
`logos-rln-modules` (main, 2026-10-01): its README, `logos-lez-rln-module/README.md`,
`logos-rln-module/README.md`, `logos-rln-membership-ui/README.md`.

## 3. What the chain and the fleet learn (invariants 8 and 9)

To be confirmed against the registry program before anything ships:

- **The registry chain** learns that a membership was registered at some time, its
  identity commitment, and the account that paid. RLN proofs are designed to hide which
  member sent a message, unless a member exceeds its rate, which reveals its secret.
- **The funding transfer** links whoever funded the payer to that payer. If one person
  funds every muster peer, the chain shows one funder behind many memberships.
- **Nothing here names a muster room.** The membership belongs to the delivery node, not
  to a room or a member identity. muster's room-level guarantees are unchanged: what the
  store node sees per message is still topic, timing and size (FS-9).

The walkthrough would gain a claim like: *"Sending on logos.test needs an RLN membership.
The registry learns that this node registered and which account paid; your messages carry
a proof that does not say which member sent them."* Its credibility row depends on the
registry's actual disclosure, read from source, as every other claim is.

## 4. Options

- **A. Stay on `logos.dev`.** No RLN, works today, nothing to fund. muster is exposed to
  a fleet that breaks without notice, and `logos.test` is where every other application
  is.
- **B. Leave membership to the host.** In Basecamp, the RLN membership app owns the node's
  membership; muster only reads `rlnState` and says why it cannot send yet. In the
  standalone runner, muster bundles the two RLN modules, and a person (or a dev script)
  unlocks the keystore and funds the payer. This matches how the modules are designed.
- **C. muster drives membership itself**, unlocking, funding and registering from its own
  UI. This duplicates the membership app, and muster would be handling a second
  password and wallet.

For demos and self-tests, under A or B: a script that funds each peer's RLN payer from
one funded account via `LEZ_RLN_PAYER_KEY`. That needs a funded native-LEZ key on the
registry's zone.

## 5. Questions for the operator

1. **Default fleet.** Stay on `logos.dev` (A) until something forces the move, or move to
   `logos.test` with membership (B) before validation turns on, about 2026-10-14?
2. **Who owns membership?** B (the host's membership app; muster reads state only) or C?
3. **Funding.** Is there a funded native-LEZ account on the registry's zone
   (`209.38.241.182:3240`) that demo peers and self-tests may draw on? If not, how should
   one be made: the bridge, or a request to the Logos team?
4. **Disclosure.** Is one funder behind all of a person's (or a demo's) memberships
   acceptable, or should each peer be funded so the chain cannot group them?

## 6. Decisions (2026-10-01) and the design they lead to

**Q4, disclosure: one funder behind several memberships is acceptable.**

**Q2, who owns membership: muster facilitates it.** The operator's framing: a host manages
membership, but every muster user runs a node and starts conversations, so every one of
them hosts, and every one needs a membership. muster therefore helps each member get one
for their own node. The membership still belongs to the node, and muster drives the RLN
modules' own flow rather than inventing one.

What that flow already does by itself, from the modules' contracts (`liblogos_rln_module`
0.10.0):

- **The keystore unlocks itself.** At init the module self-provisions a 32-byte secret, keeps
  it in a 0600 file beside the keystore, and resumes on every restart with no unlock call.
  Nobody types a password (`unlock_keystore_auto`; `LOGOS_RLN_DISABLE_AUTO_UNLOCK=1` opts
  out). That answers option C's worry about a second password.
- **Registration runs itself once funded.** A membership `start()` provisions waits for its
  payer to hold the price plus a fee reserve (~1.8×10⁸ native at base fee 8), then
  registers; `get_membership_state` and `membership_state_changed` report pending → active.
- So the only step a person must take is **getting the payer funded**.

**Funding, three paths:**

1. **Self-funded.** muster shows the node's RLN payer (`liblogos_lez_rln_module.wallet_status`)
   and its native balance (`get_native_balance`). Anyone sends it native LEZ on the
   registry's zone. That zone is its own chain: sequencer `209.38.241.182:3240`, at block 961
   on 2026-10-01, while `testnet.lez.logos.co` was at 381. It is **not** the zone muster's
   wallet uses.
2. **Gifted within the room.** `logos-co/logos-rln-gifter` (LIP-158) lets a funded
   *gifter* node register memberships on behalf of authenticated clients. The client never
   holds funds, and its identity secret never leaves its machine. Authentication is a
   pluggable vector, and one reference vector, `eth-auth-module`, checks an EIP-191
   signature over the identity commitment against an allowlist. Every muster member
   already has a secp256k1 authorization key and discloses its address in the room
   (F-14). So a funded member can serve as the room's gifter with the room members'
   addresses as the allowlist, and each member requests a membership by signing with
   their muster key. One funder behind several memberships is what Q4 accepted. It needs
   `rln_gifter_module`, `eth-auth-module` and `libp2p_module` (the gifter protocol runs
   over libp2p custom streams), and the gifter's node must be dialable by the others.
3. **A public gifter**, if the Logos team runs one for the testnet: the same `request`,
   another peer. Unknown; worth asking.

**Slices**, each one verifiable before the next:

- **R1:** bundle `liblogos_rln_module` and `liblogos_lez_rln_module` in the runner (delivery's
  flake re-exports both as `.lgx`). Show the node's RLN state, membership state, payer and
  balance in the connectivity panel and Settings. On `logos.test`, check it live up to
  "awaiting funding". Needs no funds.
  **Built (2026-10-01, exo-4a7a).** The runner bundles both modules (muster_ui declares
  them: the July host predates delivery's `optional_dependencies`). `rln_status` and, on
  `logos.test` only, a connectivity row (`transport/rln_status.nim`, pure;
  `transport/rln_probe.nim` reads delivery's `rlnState`, the lez-rln `wallet_status`
  locally, and the payer's balance and the membership state async, so the module thread
  never waits on a chain); Settings shows the row with the payer to copy, and off
  `logos.test` says RLN is not needed. `scripts/rln-self-test.sh` checked it live: within
  25 s of joining a room the keystore auto-unlocked, the wallet was provisioned on the
  registry's zone, a payer derived, its balance read as 0, and the row read "awaiting
  funding", naming the payer, the zone and the amount. No funds were needed.
- **R2:** self-funding (path 1). Verified once any payer is funded (Q3).
- **R3:** the room gifter (path 2). A spec first: what the allowlist proves, what the chain
  and the gifter learn, and whether a gifter may refuse a member.
- **R4:** switch the default fleet to `logos.test` (Q1) once a membership has gone active
  end to end.

**Still open:** Q1, the default fleet, stays `logos.dev` until R4. Q3 asks who funds the
first payer or gifter: a funded native-LEZ account on the registry's zone, the bridge, or a
public gifter.

## 7. For the Monero campaign (exo-dcc.2): which network the demo runs on

Status: **options for the operator, 2026-10-08.** The campaign promises no new token, so a participant must never need LEZ to chat.

**Facts:**
- Muster already defaults to `logos.dev` (no RLN). Proof validation on `logos.test`, from about 2026-10-14, changes nothing for Muster unless we move.
- No public RLN gifter runs today. The standalone allocation service is an open Logos deliverable: logos-co/anoncomms-pm#81.
- `logos-rln-gifter` exists. A funded gifter registers memberships on clients' behalf. A client authenticates with a pluggable vector (Keycard, or an EIP-191 signature against an allowlist), never holds funds, and keeps its identity secret.
- A registration spends about 7.5×10⁷ native LEZ on the registry's zone ("LEZ classic", `209.38.241.182:3240`). The rest of the 1.8×10⁸ reserve is refunded.

**Options:**

1. **Demo on `logos.dev`.** It works today, and nothing needs funding.
   - Risk: the fleet is "redeployed freely and may break at any time" (§1). A broken fleet on demo day is the failure.
   - Mitigation: a dry run the day before. `MUSTER_FLEET=local` is a fallback for a demo on one machine.
2. **Demo on `logos.test`, with a gifter the campaign team runs.** Each participant's node requests a membership.
   - Our gifter pays for it: about 7.5×10⁷ LEZ per participant, bridged onto LEZ classic.
   - Strangers can't be allowlisted ahead of time, so a public campaign gifter needs an open vector with a rate limit, which the gifter does not have today. Otherwise the gifter's allowlist is people who announced an Ethereum address (EIP-191).
   - The chain shows one funder behind every campaign membership, which §6 Q4 accepted.
   - Needs R2 (one membership active end to end) and R3 (the gifter request from Muster) built first.
3. **Demo on `logos.test`, with a public Logos gifter.** It needs anoncomms-pm#81 shipped, on a date we don't control.

**Recommendation:**
- Option 1 for the demo (the plan's day 25–40).
- Ask the Logos team about #81's date.
- Build R2/R3 after the demo, so the handover (day 40–60) can move to `logos.test` if a gifter exists by then.

Campaign copy says "on Logos's development network" until then.

**Decided (2026-10-08, by the operator): option 2, `logos.test` with a gifter we run.**
- The design is R3's room gifter (§6): our funded node is in every demo room and serves as its gifter, with the room members' disclosed secp256k1 addresses as the EIP-191 allowlist. Participants never hold LEZ.
- The gifter's funding lands on LEZ classic, about 7.5×10⁷ per membership. That is the campaign team's cost and is recorded as such.
- Slices: R2 (one membership active end to end, self-funded), then R3 (the room gifter), then R4 (the default fleet moves to `logos.test`).
- Campaign copy says "on the Logos testnet" once R4 lands.
