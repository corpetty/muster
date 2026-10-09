# Monero in Muster rooms: the plan (exo-dcc)

Status: **planned 2026-10-07. ADR-018 accepted 2026-10-08; the demo runs on `logos.test` with a gifter we run (exo-dcc.2, `rln-membership.md` §7); the catalogue lives in this repo (`catalog/`, exo-dcc.3). As of 2026-10-09 (day 2): Phases 0 and 2 are done, ahead of the calendar; two things wait on funds (§0).** Epic `exo-dcc`, with its children `exo-dcc.1`–`.23`.
`pb dep tree exo-dcc` shows live status, and `pb ready` shows what can start next.

## 0. Where it stands (2026-10-09)

Read from the pebbles on 2026-10-09. The pebbles win over this table.

| Phase | Pebble | State |
|---|---|---|
| 0 Ground truth | `exo-dcc.1` | **Done** (2026-10-08). Basecamp 0.3.2 and delivery 0.3.2; Muster reaches `monero_wallet_backend`, attested as `muster_module`; ADR-018 accepted. Two spike questions are still open, because they need a funded stagenet wallet: whether an incoming transfer shows in `history()` before it confirms, and how long a first sync takes. `exo-dcc.19` answers them |
| 1 Messaging with no LEZ | `exo-dcc.2` | **Decided, not built.** `logos.test` with a room gifter we run. Slices R2, R3, R4 (`rln-membership.md` §7). **Waits on funds**: native LEZ on LEZ classic for the gifter |
| 1 An installable Muster | `exo-dcc.3` | **Published.** Version ranges and 0.2.0; `catalog/` and `scripts/catalog-release.sh`; a fresh Basecamp 0.3.2 installed Muster from a locally served copy; release `muster-v0.2.0` published 2026-10-09 with `catalog/index.json` on `main`. Ahead: CI builds, the fork exit, macOS |
| 1 The mixnet | `exo-dcc.4` | **Done** (2026-10-08). An opt-in `mix` setting, off by default, sends only. Untested on `logos.test` |
| 1 Install what's missing | `exo-dcc.10`, `.11` | **Done** (2026-10-08). Seen on display in Basecamp 0.3.2 |
| 2 The XMR payment request | `exo-dcc.5`, `.20` | **Done, except the live payment** (2026-10-09). Spec `derived-exo-dcc.5`, 7/7. The UI was seen on display in Basecamp 0.3.2 with a real stagenet wallet, up to the payment. The live two-machine run is `exo-dcc.19`, which **waits on funds**: stagenet XMR for the payer. Detail: `docs/labbook/xmr-payment-request.md` |
| 3 Pay from Basecamp's own wallet | `exo-dcc.6` | **Not started.** Waits on the upstream review intent (§8, ask 2) |
| 4 The deal-desk demo | `exo-dcc.7` | **Not started.** Needs `.2`, `.3` and `.19`. `audit.nim` still refuses the split families |
| 5 The mainnet gate | `exo-dcc.8` | **Not started** |

Smaller follow-ups, all open: a local copy of each room's log (`exo-dcc.14`, P2); a 0.3.2 catalogue file for the Basecamp harness (`.15`); readiness under `--access-policy enforce` (`.16`); the `frost_ceremony_room_test` flake (`.17`); upstream asks from the catalogue run (`.18`), the mix path (`.13`) and Monero Wallet's `failed` answer to `monero.wallet.unlock` (`.21`); a grader leftover (`.22`); a spec wording fix (`.23`).

**Waiting on funds.** Both are the operator's to fund. The public addresses are in `docs/06-session-handoff-2026-10-09.md` §4; the wallets themselves live outside the repo.
- **`exo-dcc.19`, the live XMR payment:** stagenet XMR for the payer's wallet, from a stagenet faucet.
- **`exo-dcc.2`, the gifter:** native LEZ on LEZ classic (`209.38.241.182:3240`), about 7.5×10⁷ per membership, for the gifter's RLN payer.

## 1. The goal

Muster's development now aims at one outcome: people in the Monero community use XMR from
inside Muster rooms, on their own machines. A community campaign is built around it, the
team's *Monero Activation Plan*. That plan has three stages: an essay, then a demo people
install and finish a deal with, then a public handover with a backlog credited to the
community's critics.

The pitch is that Logos builds the infrastructure around the money:

- **Settlement stays on Monero.** Monero is already private there by default.
- **Muster covers the rest of the transaction's lifecycle.** The demo is a deal room:
  - people agree terms in a private room;
  - the payee issues an XMR payment request;
  - the payer pays from their own wallet;
  - the payee's own wallet confirms the payment.
- **The promises:** no new wallet apps, no custody, no new token.

## 2. What the platform gives us

Basecamp's default catalogue ships a Monero wallet stack. It is **catalogue-only, not
bundled**, at 0.1.0. Upstream has not changed since the 2026-09-30 publish, as of
2026-10-07. The full reference is the logos-module-atlas plugin,
`stacks/monero-wallet.md`.

The stack's modules:

- `monero_wallet_core_module`: wallet2 via monero_c. It is the only holder of keys.
- `monero_wallet_backend`: the coordinator a third-party module calls.
- `monero_node_module`: endpoint and proxy policy, with Tor-ready, fail-closed
  `proxyRequired`.
- `monerod_module`: a local monerod.
- `monero_wallet_ui` and `monerod_ui`: the two apps.

What Muster can use without changing anything upstream:

- **`create_subaddress(0, label)` needs no role.** So a payee mints a fresh subaddress for
  each request.
- **`history()` rows carry `subaddrIndex`, exact atomic amounts and confirmations.** So the
  payee's own wallet confirms that a request was paid, with no third party involved.
- **`prepare_send` builds and signs a transaction for review.** `confirm_send` broadcasts it,
  and calling it requires the approver role.
- **Default network is stagenet.** Default remote nodes are `*.monerodevs.org`.

What it lacks, with no upstream work in progress anywhere:

- no multisig;
- no tx proofs (`get_tx_proof` / `check_tx_key`);
- no payment id or integrated addresses;
- no cold signing;
- one send in flight per device;
- no way for the wallet GUI to review a send another module prepared.

The backend's role gate is not a security boundary against co-loaded modules either. While
a wallet is open, the core is ungated.

## 3. What shaped this plan

1. **The critical path is not Monero code.** Two things a stranger needs come first:
   - **an installable build.** The last public AppImage (`v0.2.0-demo`) cannot share a room
     with today's builds, and Muster is in no catalogue.
   - **messaging that needs no LEZ.** From about **2026-10-14**, `logos.test` rejects
     messages without RLN proofs. Each node then needs about 2.5×10⁸ native LEZ on the
     "LEZ classic" zone (logos-docs#519, `rln-membership.md`). The campaign promises no
     new token.
2. **The XMR atomic swap is already funded elsewhere.** It is RFP-003 milestone M4
   ([rfp#124](https://github.com/logos-co/rfp/issues/124), gateway-fm, open, after M3).
   Its code talks to `monero-wallet-rpc`, not to the Logos modules. Muster integrates the
   swap; it does not build one.
3. **Monero multisig stays `reject`** (`contracts/families/registry.json`). Upstream calls it
   experimental, and the platform backend does not expose it anyway. Every Monero action
   starts on the `each` locus, the split's model: each person pays their own part.
4. **Muster never enrols itself as approver.** This is the posture `exo-149` set for
   `keystore_module`. Paying from the Basecamp wallet therefore waits on an upstream review
   intent, and Phase 2 must not need one.

## 4. v1 in one paragraph

v1 is a family **`monero.split`**, a fourth family of the split driver. The `monero.*`
prefix is what groups it in the atlas. Its first use is a **payment request**: a split
with one debtor, where the creditor is "not in it (chip in)".

1. The creditor mints a subaddress for the request. They agree to it in the room, and their
   agreement vouches that the address is theirs.
2. The debtor pays from **any wallet**, through a `monero:` URI or a QR code: Cake, Feather,
   or Basecamp's own.
3. The creditor's own wallet confirms it. `history()` shows a row on that subaddress, of
   exactly the share, with at least 10 confirmations.
4. Until Phase 2b lands, the creditor confirms by hand with "Mark received", which already
   exists.

No new card type is needed: it is an intent card (F-13).

## 5. The seven links in an XMR deal room

All seven links are Muster's scope (`docs/runbooks/explaining-muster.md` §4c). This is what
the demo at the end of Phase 4 can show truthfully for each link, and what stays ahead.

| Link | The demo shows | Ahead |
|---|---|---|
| Discovery | People who found each other elsewhere (Matrix, XMRBazaar) move the deal into a room by invite. Nothing on the room's topic names its members | An offer board that no platform watches |
| Diligence | Each member's identities are bound to each other (F-14). What a counterparty discloses is all the client says about them (invariant 9) | Checks beyond what they disclose |
| Negotiation | The encrypted room, with no coordination server | Offer/counter (F-11) |
| Contracting | Signed terms ("Decide something") and an XMR request both parties agree to; the client re-derives what it signs | — |
| Ordering | The payer broadcasts through their own wallet and node. A local monerod (`monerod_ui`) or a proxy keeps the remote node from learning the wallet's IP. Readiness grades local versus remote. Room messages can go out through the mixnet (an opt-in `mix` setting, sends only, `exo-dcc.4`) | Hiding who reads a room: reading is a store query from the reader's own address |
| Settlement | Monero: the chain shows no sender, receiver or amount; a subaddress per request is unlinkable to the payee's other addresses. This is Monero's guarantee, and the card says so | — |
| Enforcement | Monero is mined by a permissionless proof-of-work set, not a named sequencer. The payment counts only when the payee's own wallet sees it. The room's record exports as a receipt the member chooses to share | Escrow; the swap (RFP-003 M4); a chain-side receipt (tx proofs, upstream) |

## 6. Order of work

Children of `exo-dcc`. Phase 1 starts on day 0, alongside Phase 0.

**Phase 0: ground truth, days 0–5 (`exo-dcc.1`)**
- **Bump to Basecamp 0.3.2.** Pin delivery 0.3.2, record the Monero stack in
  `real-use-basecamp.md`, and correct `monero.multisig`'s `infra` and `why` (the platform
  backend has no multisig).
- **Spike.** `muster_module` calls `monero_wallet_backend` over lp_* on stagenet. Answer in
  the labbook:
  - Does `caller_identity` attest `muster_module`?
  - Do replies arrive double-encoded?
  - Do incoming transfers appear in `history()` before they confirm?
  - How long does the first sync take?
- **ADR.** It records:
  - the `each` locus only;
  - CAIP-2 references by bip122's genesis-hash convention;
  - the invariant-2 binding call (`implicit`, or `none` plus `exposure`);
  - stagenet first;
  - no self-enrolment as approver.

**Phase 1: the critical path, from day 0**
- **`exo-dcc.2`: messaging with no LEZ.** Decide before 2026-10-14. Ask the Logos team for
  a public testnet gifter. As fallback, build R2 and the room gifter, R3 (`exo-eb6.3`). If
  neither is ready, demo on `logos.dev` and say so.
- **`exo-dcc.3`: an installable Muster.** Design: `docs/design/catalogue-install.md`.
  - The official catalogue is for apps by the Logos team (logos-modules-release#98), so
    Muster runs **its own catalogue**.
  - Basecamp resolves dependencies across every enabled catalogue, so ours publishes only
    `muster_module` and `muster_ui`.
  - For linux-amd64 this does **not** wait for `exo-d4d.8`. The forked builder's bundler
    does drop `optional_dependencies` from the manifest, which matters for the Monero
    modules.
  - Steps: version ranges, a Forum-style catalogue repo, acceptance on two fresh
    profiles, then the install page (about a week). CI, the fork exit and macOS follow.
- **`exo-dcc.4`: the mixnet.** Try `anonymityLevel: Preferred` on delivery 0.3.x. If it
  works, ship it with a claim; if not, the copy says "specified, not on".
- **`exo-dcc.10`: install what's missing, from the card and the proposal form.** A stranger
  installs Muster, and Muster helps them install whatever a proposal needs. This works for
  every driver, not only Monero. Today the fresh-install runbook has people install about
  13 catalogue packages by hand before starting.
  - **Muster asks; the person confirms.** Basecamp's Package Manager provides the
    `packages.install` intent, in 0.3.1 and 0.3.2 alike. Muster raises
    `logos.request("packages.install", {name})`. Package Manager opens on that package, the
    catalogue resolves its dependencies, and the person confirms in Basecamp's own install
    dialog. Muster installs nothing itself.
    - Before every request, Basecamp asks "Use this app? Muster wants to
      packages.install", and it does not remember the answer. A Cancel there reaches
      Muster as `cancelled`.
    - Seen on display in Basecamp 0.3.2 (2026-10-07). Installing `monero_wallet_backend`
      took 4 packages and about 51 s, including the pre-ticked optional `monerod_module`.
      It installed no app.
  - **Readiness grades a module in three states:** not installed, installed but not
    running, and running.
    - It reads them from Basecamp's `modules_state` registry. `module_record(name)` is
      null for a core module the host doesn't know; otherwise its `state` is `unloaded`,
      `loading` / `loaded`, `ready` or `error`.
    - It never calls into a module whose record isn't `ready`. A call to an installed but
      stopped module blocks for the caller's whole timeout (20 s by default) and then
      fails.
    - Measured on logosctl 0.3.0 and Basecamp 0.3.2, 2026-10-07.
  - **The driver names what to install,** which can differ from the module it needs.
    Monero needs `monero_wallet_backend`, but the package to install is `monero_wallet_ui`:
    it pulls in the backend, core and node, and holds the wallet roles the backend's
    defaults name.
  - **The card.** A missing module shows an "Install …" button. The reply means "Package
    Manager is open", not "installed", so the card then re-reads readiness until the
    module is installed.
    - **An install does not start the module.** Neither does a Basecamp restart or a
      call to it.
    - **Basecamp starts core modules when an app that depends on them opens:** its
      required dependencies, and any optional ones that are installed. Closing the app
      leaves them running.
    - So "installed but not running" says to close and reopen Muster, which starts
      Muster's own optional dependencies, or to open the app that uses the module. For
      Monero, `monero.wallet.unlock` opens the wallet app, which starts the backend,
      core and node.
  - **When the install can't run:**
    - The package isn't in any enabled catalogue (the request fails after 8 s): the card
      offers the catalogue settings.
    - There is no Package Manager, as in the standalone runner: the card keeps today's text.
    - Only one request runs at a time.
  - **The room's proposal form.** Each kind on the "Settles on" list carries its needs,
    graded the same way. A kind whose module is missing shows "Install …" rather than
    disappearing. Propose waits only on what the proposer's own part needs.
  - **Metadata.**
    - `muster_ui` declares `uses` for `packages.install` and `packages.show`.
    - The Monero modules become **optional** dependencies of `muster_module`.
      - They are never a reason Muster fails to load, and they start along with Muster
        once installed.
      - Basecamp's install dialog lists optional packages pre-ticked, so a default
        install of Muster brings the Monero stack, and the person can untick it.
      - The atlas guide says optional dependencies are "never auto-loaded"; the probe
        found otherwise.
    - Open: whether `--access-policy enforce` counts optional dependencies as declared.
  - **Muster must declare every module it calls.** On display, a module Muster does not
    declare stayed silent to Muster for five minutes after Basecamp started it. The cause
    is not yet found. Reopening Muster starts only the modules it declares. So:
    - the Monero modules become optional dependencies of `muster_module` (Phase 2b);
    - an installed module's remedy is "close and reopen Muster" only for a declared module,
      and otherwise "open the app that uses it, or load it in Basecamp's Modules tab".
    - The investigation is a child of `exo-dcc`.

**Phase 2: the XMR payment request (`exo-dcc.5`, after `.1`)**
- A typed spec via `discuss-issue`, with tests failing first:
  - the payment is derived from the agreed effect;
  - only the creditor's own read confirms it;
  - one reference settles one part;
  - the network is bound.
- **`monero/address.nim`.** A pure Monero address parser that maps the network byte to
  CAIP-2. It needs no keys.
- **`monero.split`.** In `split.nim`, plus kinds, registry, profile, manifest, the
  12-decimal label, the family registry, the action corpus and claims. Settle-up refuses
  Monero explicitly: today the code treats any chain that is not LEZ or Bitcoin as EVM
  (`muster_module.nim` ~1610 / 1709).
- **2a, by hand.** A `monero:` URI and QR code on the card. The payer says they paid, and
  the creditor marks it received.
- **2b, automatic.**
  - `wallet/monero_backend{,_lp}.nim`: the pure-plus-lp pair, as `tx_sender` does it. Reads
    are async, and "busy" is never read as zero.
  - The `metadata.json` dependency and a flake pin.
  - A readiness remedy that raises `monero.wallet.unlock`.
  - `MoneroPartSeam.matchReceived` over `history()`.
- **UI.** "Request a payment", XMR in the Split composer, and "Share my Monero address".
- **Tests.** A fake backend for the probes, and `split-xmr-self-test.sh` on stagenet.

**Phase 3: pay from Basecamp's own Monero wallet (`exo-dcc.6`, after `.5` and the upstream
intent)**
- Muster calls `prepare_send`, then checks the preview against the agreed part:
  - the destination is exact (Monero addresses are case-sensitive);
  - the amount, in atomic units;
  - one transaction;
  - a fee cap;
  - the network;
  - the request is Muster's own.
- It raises the wallet's review only if every check passes, and cancels on any mismatch. A
  send in state `unknown` may have been broadcast, so it is never retried.
- The wallet engine signs during `prepare_send`, so Muster gates the broadcast, not the
  signing.

**Phase 4: the deal-desk demo (`exo-dcc.7`, after `.2`, `.3`, `.5` and `.10`)**
- **The flow.** Terms → XMR request → pay → confirm → a receipt the member chooses to share.
  This needs `audit.nim` extended to the split families, which it refuses today.
- **Education.**
  - The room's request and txid never leave the room.
  - The default remote node sees the wallet's sync, unless you run `monerod_ui`.
  - FlowView rows come from the manifest.
  - Fix stale claim [14].
- **A runbook from install to deal**, and a recorded run.
- **Acceptance:** two fresh installs on two machines, stagenet, nothing seeded.

**Phase 5: the mainnet gate (`exo-dcc.8`, after `.7`)**
- Address the stack's threat model:
  - raise the ungated core and `configure` upstream;
  - recommend `--access-policy enforce`;
  - disclose the co-loaded-module exposure in the manifest.
- Then mainnet becomes an opt-in, with a warning on small amounts.

**After the campaign, by demand**
- tx proofs upstream, for a chain-side receipt;
- the swap, with RFP-003 M4, with a Muster room as the negotiation front end;
- escrow, revisited after FCMP++;
- a subaddress per share (a new effect version) if distinct amounts prove awkward;
- macOS.

## 7. Against the campaign's 60 days

Day 0 is 2026-10-07. Today, 2026-10-09, is day 2.

| Campaign window | Engineering |
|---|---|
| Days 0–10 (to 10-17) | Phase 0; messaging decided before 10-14; Phase 2's spec written |
| Days 10–25 (to 11-01) | Phase 2, 2a first; the installable build, and installing from the card (`exo-dcc.10`); the essay uses §5's columns |
| Days 25–40 (to 11-16) | Phase 4 and the two-machine acceptance; Phase 3 if the upstream intent has landed |
| Days 40–60 (to 12-06) | Phase 5; the backlog from critics; a Lambda prize opened |

**On day 2:**
- **Ahead of the plan.** Phase 0 is done. Phase 2's spec, module and UI are done, which the plan put in days 10–25. `exo-dcc.10` is done, and the catalogue's tooling is.
- **Behind it, for want of funds.** Phase 2's live payment (`exo-dcc.19`) needs stagenet XMR. The messaging decision was made on day 1, well before 10-14, but R2–R4 are not built, and the gifter needs native LEZ.
- **The date that matters next is about 2026-10-14**, when `logos.test` starts rejecting messages without RLN proofs. Muster still defaults to `logos.dev`, so nothing breaks then. What changes is that the demo cannot move to `logos.test` until the gifter runs.
- **Phase 4 can start** once the catalogue release is up and `exo-dcc.19` has run. It still waits on the gifter for the network it is meant to run on.

## 8. Asks of other teams

1. **The Logos team:** a public testnet RLN gifter, so campaign participants never hold LEZ.
2. **`monero_wallet_ui`:** a review intent for a send another module prepared, such as
   `monero.wallet.review_send {requestId}`.
3. **`monero_wallet_backend`:** tx proofs (`get_tx_proof` / `check_tx_key`).
4. **The Monero stack:** gate the core's `commit_transaction` and the backend's
   `configure`.
5. **gateway-fm, RFP-003 M4:** run the XMR leg over the Logos Monero modules. This is a
   better target for the campaign's Lambda prize than the "monerod module" it proposed,
   which already exists.

## 9. Corrections for the campaign doc

- **"Basecamp ships Monero" is not quite right.** It is a catalogue install, not bundled.
  Muster's card offers that install the first time a proposal needs it (`exo-dcc.10`).
- **Claim all seven links as Muster's scope, with §5's columns.** Never present the
  "Ahead" column as shipped.
- **The mixnet, in these words only** (`exo-dcc.4`, `docs/labbook/mixnet-on-delivery-03.md`): "Muster can send a room's messages through the Logos mixnet. It is an opt-in setting, built on Logos Delivery 0.3's sender anonymity. It hides which participant sent a message, not who reads a room: reading still asks a store node for the room directly."
  - Never "mixnet integrated" without that qualifier.
  - Never "metadata-private", never on by default, and never that it protects against the network operator.
- **"No new token" holds only if `exo-dcc.2` lands.**
- **"The user chooses to share a receipt" fits.** In v1 the receipt is the room's signed
  record. A Monero tx proof is upstream ask 3.
- **Paying from Cake or Feather is the v1 path,** not a fallback.

## 10. Decisions

All three were open when this plan was written. Each is now decided.

- **Demo network: stagenet.** ADR-018: stagenet first; mainnet waits for `exo-dcc.8`.
- **Messaging: `logos.test` with a room gifter we run** (2026-10-08, `rln-membership.md` §7).
  Not a public gifter, and not `logos.dev`.
- **Paying from the Basecamp wallet: wait for the upstream review intent.** ADR-018: Muster
  never makes itself approver, not even for demos.

Sources: the logos-module-atlas plugin `0.1.202610071320` (Basecamp 0.3.2:
`stacks/monero-wallet.md` and the module cards); logos-docs#519; `docs/design/rln-membership.md`;
RFP-003 and rfp#124; the team's *Monero Activation Plan [WIP]*.
