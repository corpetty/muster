# State of the app: audit of 2026-11-17

Issue: exo-863. Tree: `eaec424` (main). Read-only: nothing was built, run or launched for the
audit itself.

Six reviews ran in parallel, one per dimension, each reading source, runbooks and the tracker.
Every finding is marked:

- **checked**: re-read in the code a second time, after the review reported it.
- **reviewed**: one review read the code path; not re-read.
- **inferred**: reasoned from structure; nobody read the whole path or measured it.

The scaling figures in §5 are estimates. No UI finding was seen on a display.

**This is the public copy.** The coordination-path security findings are withheld until they
are fixed; they are tracked, with neutral titles, under epic exo-ad5c. The full report is kept
outside the repository by the operator.

## 1. Summary

The signing core is sound: effect and id are content-bound, the signer re-derives, and no path
around re-derivation was found. The weak part is everything that decides who is in a room and
who may write into it. That gets one design (exo-ad5c), because each piece of it changes the
wire format.

Five themes, in the order they should be worked:

1. **Room membership and authorship** (§2): one design, one wire break (exo-ad5c, P0).
2. **Keys at rest and identity** (§3): file permissions were the keyfile's only protection, no
   backup, one secp key for Ethereum and Bitcoin.
3. **No safety net** (§4): no test gated a merge, the catalogue is unsigned, no wire version.
4. **The backend runs on the UI's clock** (§5): pumps on a read call, global room state, no
   fold cache.
5. **The first five minutes and the long waits** (§6).

## 2. Security: the signing and coordination path

Withheld in detail until fixed. Tracked under exo-ad5c:

| Issue | Scope | Severity |
|---|---|---|
| exo-ad5c.1 | ADR and typed spec: membership and authorship as signed log state | covers critical |
| exo-ad5c.2 | What a room-native approval's signature commits to | high |
| exo-ad5c.3 | Ceremony and lifecycle events bound to author and content, never sort order | high |
| exo-f12 | A substitute intent context is folded (already open; its proposed fix is not enough) | high |
| exo-b75 | A joiner seals its request to any beacon, including a squatter's (already open) | medium |

Fixed in this round:

| # | Finding | Status | Fix |
|---|---|---|---|
| S8 | Non-constant-time FROST had no mainnet gate; the "production gate" was a comment | checked | `frostNetworkRefusal`: no FROST account derived, no ceremony opened, no step taken on Bitcoin mainnet (`frost_mainnet_gate_test`) |

Sound, per the review: propose/policy substitution, signature attribution and dedup, author
signatures binding room and parents, join requests, provenance by content id, part reports, the
Safe hash (chain id, Safe, nonce), the invoke allowlist, the keystore exposing operations only.

## 3. Privacy

| # | Finding | Severity | Status | Issue |
|---|---|---|---|---|
| P1 | The keyfile is sealed under a constant from the source unless `MUSTER_KEY_PASSPHRASE` is set; the lock error printed it | high | checked | exo-24a2.7; printing fixed |
| P2 | One secp key is the Ethereum address and the Bitcoin pay-from key, in every room | high | checked | exo-ad5c.8 |
| P3 | No forward secrecy; only LEZ multisig rooms can remove a member or re-key | high | checked | exo-ad5c.5; claim corrected |
| P4 | Identity is one per keystore, the same in every room | medium | reviewed | exo-1b1 |
| P5 | The inbox topic is a permanent public pseudonym | medium | reviewed | exo-487; gap claim corrected |
| P6 | A typed room name goes on the wire as typed; composer topics use `Math.random` | medium | reviewed | exo-ad5c.7 |
| P7 | Frames are unpadded; the kind byte is in the clear | medium | reviewed | exo-ad5c.6 |
| P8 | Settings (with bitcoind credentials), contacts, room lists, split book and journal were written with the default umask | medium | checked | **fixed**: owner-only from the first byte |
| P9 | LEZ defaults to a public sequencer | low | reviewed | — |
| P10 | A file's provider set approximates the room's membership | low | inferred | exo-4d0.9, in part |

Claims corrected: "Removal rotates the epoch immediately" (there is no general removal);
"Nothing on the room's topic says who is in it" (true for rooms Muster makes, not for typed
names); the store-node gap now names the inbox topic and the fetch schedule.

Sound: grants sealed whole, no epoch number on envelopes, the journal stores only sealed frames,
no hardcoded EVM/BTC/XMR endpoints, no telemetry.

## 4. Verification, release and supply chain

| # | Finding | Status | Issue |
|---|---|---|---|
| A1 | No test gated a merge: no workflow ran the suite, `main` is unprotected | reviewed | **fixed** by `checks.yml`; exo-24a2.1 to require it |
| A2 | The catalogue is unsigned (`trustedSigners: []`); index and assets share one repo and account | reviewed | exo-24a2.2 |
| A3 | No wire, envelope or journal version; an incompatible peer is dropped silently | reviewed (two reviews) | exo-ad5c.4 |
| A4 | Flake locks git-ignored; delivery pinned by tag; the lgx merge tool unpinned | reviewed | exo-24a2.3 |
| A5 | `lez_msig_module` built on one workstation | reviewed | exo-24a2.4 |
| A6 | The Pages deploy failed from 2026-11-13 (stale diagrams index) | checked | **fixed** |
| A7 | The python gates ran only in an opt-in pre-commit hook | reviewed | **fixed** by `checks.yml` |
| A8 | "Invariant tests are append-only" was enforced by nothing | reviewed | **fixed**: `check-invariant-tests-append-only.py` |
| A9 | No fuzz test on any decoder of peer bytes | reviewed | exo-24a2.5 |
| A10 | CLAUDE.md was behind the tree (release 0.3.5, not 0.3.3) | checked | **fixed** |

Correction to the release review: it said nothing records that the suite ran for a release.
For 0.3.3 the gates are recorded on exo-bfd (suite 277/277, ui-parity 12/12); what is missing is
a record attached to the release itself.

Sound: 11 hash-pinned Nim packages, rev-pinned flake inputs, both `Cargo.lock` files committed,
the Basecamp AppImage pinned by sha256, no `curl | sh`.

## 5. The kernel: architecture, efficiency, scaling

| # | Finding | Bites at | Status | Issue |
|---|---|---|---|---|
| K1 | All ten pumps run inside `coordinate_intents`, for the open room only | any background room | checked | exo-ff5.9, exo-d4d.4 |
| K2 | `gSession` (338 references) makes every method implicitly room-scoped | multi-room | reviewed | exo-ff5.1 |
| K3 | `driverFor` re-folds the room's accounts on every call inside the intent fold | ~10 intents, 500 events | checked | exo-ff5.4 |
| K4 | No fold cache; each intent re-sorts the log about five more times; 8 synchronous calls a second | intents × events ≈ 10⁵ | reviewed | exo-ff5.4 |
| K5 | `causalOrder` is quadratic and the activity feed calls it every second | 2–3k events | checked | exo-ff5.11 |
| K6 | Chain reads block the module thread, up to 5 s each, inside the same call | one slow endpoint | reviewed | exo-14f.1, in part |
| K7 | `coordinate_messages` returns every message every tick; QML rebuilds the model | ~5k messages | reviewed | exo-ff5.3 |
| K8 | One delivery client per room; each message copied and parsed once per room | 50 rooms | reviewed | exo-ff5.12 |
| K9 | Relaunch replays every room synchronously; the store read stops at 20,000 frames, oldest first | long-lived rooms | reviewed | exo-ff5.13 |
| K10 | `muster_module.nim`: 6,281 lines, ~105 globals, ~2,000 lines of logic, 8 of 216 test files reach it | every feature | reviewed | exo-ff5 |
| K11 | Invariant 6 holds in the fold and leaks around it: 19 of 47 coordination files import a concrete driver; a new family touches ~14 places | each family | reviewed | exo-1ec.4, in part |
| K12 | The Driver seam: 25 methods, 11 with one overrider, plus three parallel seams | each family | reviewed | — |
| K13 | 131 methods returning JSON in a string; three error shapes; `muster.lidl` says 0.1.0 | UI/module skew | reviewed | exo-ff5.14 |
| K14 | 114 UI slots implemented twice (C++ and Nim) | every feature | reviewed | exo-ff5.15 |
| K15 | 26 environment variables read by the module, several security-relevant | release builds | reviewed | exo-ff5.16 |

What a ten-person room that lives a month meets first (estimate): the one-second tick outruns
itself. Cards update seconds late, then one slow endpoint inside the same call makes the app look
frozen. Nothing fails. Measure first: exo-ff5.10.

Leave alone: `log/`, `dcbor/`, `hashing/`, `drivers/kinds.nim`, `wallet/rpc_budget.nim`,
`transport/inbound_queue.nim`, `drivers/conformance.nim`, and the `Keystore`, `Transport`,
`ConversationCrypto` and `ChainAdapter` seams.

## 6. Usability

All from source; none seen running. Tracked under exo-2c6.

| Finding | Hurts | Issue |
|---|---|---|
| No identity backup step; the restorable option is in Advanced and closes at first join | everyone | exo-2c6.1 (Settings now says it is not backed up) |
| The room code is a raw topic; a typo founds an empty room and waits forever | newcomers | exo-2c6.2 |
| Two invite artefacts that travel in opposite directions | newcomers | exo-2c6.3 |
| Deny, Pay my share, Approve and Settle fire on one click | everyone | exo-2c6.4 |
| Raw reason codes and environment-variable names reach the user | everyone | exo-2c6.5 |
| Waits do not say what they wait on, how long, or whose app must be open | everyone | exo-2c6.6 |
| No notification outside the window | returning members | exo-2c6.7 |
| Start and the + picker list everything; readiness shows only after picking | newcomers | exo-2c6.8 |
| Base units, hex keys, JSON arrays and CAIP ids in everyday forms | newcomers | exo-2c6.9 |
| No single "is my setup OK" view | Monero arrivals | exo-2c6.10 |
| One act has five verbs; three sets of status words | everyone | exo-2c6.11 |
| Getting started offers an Ethereum account to a Monero arrival | Monero arrivals | exo-2c6.12 |
| Keyboard and accessibility thin outside the shell | some | exo-2c6.13 |

Protect: card faces carry almost no jargon; the educational layer is collapsed by default; the
claim-versus-confirmation copy; Monero's "seen, n of 10, about 20 minutes"; the Leave dialog;
Home's needs-you grouping.

## 7. Order of work

1. **Done in this round:** CI gates, suite, append-only guard and Rust cores on every pull
   request; the Pages index; owner-only files beside the keystore and a refused foreign data
   directory; the passphrase no longer printed; FROST refused on mainnet; three claims corrected;
   Settings says the identity is not backed up; CLAUDE.md's release facts.
2. **Next: require the checks on main** (exo-24a2.1), once they are green there.
3. **One wire break, designed once** (exo-ad5c): ADR and typed spec first.
4. **The kernel (exo-ff5), measured first** (exo-ff5.10): explicit room context and a
   module-side tick, then one cached fold per room, then split the hosted file, then close the
   driver seam.
5. **Three journeys** (exo-2c6).
6. **Before real funds or the campaign:** sign the catalogue, the platform keystore by default,
   a re-key action, fuzzed decoders, an upgrade test.
