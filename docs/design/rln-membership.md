# RLN membership for logos.test (exo-eb6.3)

Status: **research, waiting on decisions** (2026-10-01). Nothing here is built. The
questions in §5 decide what is.

## 1. Why it is needed

Since Testnet v0.3, `logos.test` rate-limits every message with RLN (Rate-Limiting
Nullifiers). A delivery v0.3.0 node on that preset:

- loads `liblogos_rln_module` ≥ 0.10.0 and `liblogos_lez_rln_module` ≥ 4.2.1;
- **does not start** until its RLN membership is `active` (or `grace_period`);
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
