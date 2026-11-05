# module/tests

## Run them

One command runs every test that needs no chain — 99 unit tests and the 55 invariant
probes under `probes/`, in parallel:

```bash
tests/run-suite.sh                  # unit tests + probes
tests/run-suite.sh probes           # the probes only (unit: the unit tests only)
tests/run-suite.sh frost lez_tx     # the tests whose path contains any of these substrings
tests/run-suite.sh e2e <name>       # one chain-bound test, by name (below)
```

The runner materializes the Nim closure at the revs `../metadata.json` pins
(`codegen.nim.packages`) with [`../tools/nim-closure.sh`](../tools/nim-closure.sh),
into `~/.cache/muster/nimpkgs`, so a local run compiles against the same sources the
`.lgx` does. It takes libsodium from nixpkgs, libopus from the builder's nixpkgs, the one
the `.lgx` ships, 1.5.2 (on Linux too since PR 340's review, where it had linked nixpkgs'
1.6.1; not yet run there, and `run-suite.sh` says why the pin's runs under nixpkgs' gcc),
and, for the host-return probe, secp256k1 and `g++`. It builds every test with one flag set: the
union of the `$SECP`, `$STINT`, web3, SDK, libsodium, libopus and miniaudio flags below. An extra
`--path` is harmless to a pure-Nim test. Each test's log lands in `$OUT` (a fresh temp
dir unless set), and the summary names every failure. Env: `JOBS` (8), `TEST_TIMEOUT` (900 s),
`TEST_ARGS` (appended to each selected test's command line, for an e2e test's own
arguments), `MUSTER_NIMPKGS` (the closure dir), `MUSTER_SODIUM` / `MUSTER_OPUS` (a
libsodium / libopus prefix in place of the default; on Linux `MUSTER_SODIUM` needs
`MUSTER_OPUS` beside it, and the run stops without it, since a host libsodium means the
host's compiler, which cannot link nixpkgs' glibc).

**On macOS** (arm64) the same command runs under the stock `/bin/bash` 3.2, given Nix
and a working `git` and `python3` (the closure fetch needs both; `/usr/bin`'s are the
Xcode Command Line Tools'). It links nixpkgs' `libsodium.dylib` and `libopus.dylib` at
the builder's nixpkgs, 1.5.2 at `e9f00bd`, the `.lgx`'s (no glibc to match, so no nixpkgs
gcc); `voice_codec_test` §1 prints the version it ran on. With no `nim` on `PATH` it takes
the nim and the clang the `.lgx` compiles with: `nixpkgs#nim` and `#stdenv.cc` at the nixpkgs `../flake.lock` pins under
`logos-module-builder` (in a fresh clone, which has no `flake.lock` until a first build,
the builder's own lock, read with `nix flake metadata`), the clang first on `PATH`, since
nim runs `clang` from there. With no `timeout` it uses nixpkgs coreutils'.

**Chain-bound tests never run by default.** Bring the chain up first
([on-chain tests](#on-chain-tests)), then run one by name:

| test | chain | arguments (defaults) |
|---|---|---|
| `safe_anvil_e2e`, `safe_real_anvil_e2e`, `coordinate_submit_anvil` | anvil + the Safe fixture, `infra/anvil/devnet.sh` | `<safeAddr> [rpcUrl]` (`http://127.0.0.1:8545`) — the Safe address is required |
| `btc_regtest_e2e`, `phase_d_exit_test` | a **fresh** Bitcoin Core regtest, `infra/bitcoind/regtest.sh` | `[rpcUrl] [user] [password]` (`http://127.0.0.1:18443`, `muster`, `muster`) |
| `lez_multisig_live_e2e`, `lez_frost_account_e2e`, `lez_frost_room_e2e` | a LEZ v0.2.4 sequencer, `infra/lez/localnet.sh`, or the public testnet | `[sequencerUrl] [blockSeconds]` (`http://127.0.0.1:3040`, `15`); `lez_multisig_live_e2e` also reads `MUSTER_LEZ_MULTISIG_BIN` |
| `lez_frost_v030_e2e`, `lez_frost_room_v030_e2e`, `lez_multisig_live_v030_e2e` | a local LEZ **v0.3.0** zone, `infra/lez/localnet.sh`, or the testnet (`https://testnet.lez.logos.co 40`) once its funder holds LEZ: every account the tests use is funded by the zone's funder, `infra/lez/funder.sh`, `MUSTER_LEZ_E2E_FUND` base units each (default 1 LEZ; on the testnet 50000000 for the multisig, 200000000 for FROST) | `[sequencerUrl] [blockSeconds]` (`http://127.0.0.1:3040`, `15`); `lez_multisig_live_v030_e2e` takes the deployed v0.3 multisig's program account as a third argument or `MUSTER_LEZ_MULTISIG_V03_PROGRAM`, or deploys the port's guest first when `MUSTER_LEZ_MULTISIG_V03_BIN` names it (`localnet.sh deploy`) |
| `split_anvil_e2e` | any fresh anvil (chain id 31337, its default funded accounts; no Safe) | `[rpcUrl]` (`http://127.0.0.1:8547`) |
| `settle_up_across_anvil_e2e` | any fresh anvil (chain id 31337, its default funded accounts); the Bitcoin split it covers needs no node — it goes final by its creditor's word | `[rpcUrl]` (`http://127.0.0.1:8545`) |
| `voice_device_e2e` | no chain: this machine's own microphone and speaker, and only with `MUSTER_VOICE_REAL` set (see Voice notes, below); otherwise it skips | none; `MUSTER_VOICE_REAL=1` (both legs), `mic` or `speaker`; `MUSTER_VOICE_REAL_AUDIBLE=1` for a quiet tone in place of silence |

```bash
SAFE=$(infra/anvil/devnet.sh | grep -oE '0x[0-9a-fA-F]{40}' | tail -1)   # from the repo root
TEST_ARGS="$SAFE" module/tests/run-suite.sh e2e coordinate_submit_anvil
TEST_ARGS="https://testnet.lez.logos.co 40" module/tests/run-suite.sh e2e lez_multisig_live_e2e
```

The exophial spec oracles under `probes/` are graded the same way the runner runs
them (`scripts/grade-specs.sh` drives exophial's oracle over `contracts/specs/`).

## What the tests cover

Most tests are named for what they check. These carry more than their name says,
grouped by the phase that added them; the "needs" notes are the flags a hand run
wants (below), which the runner supplies.

**Signing path, log, and the room.**

- `dcbor_golden_test` (known-answer bytes for invariant 5, hand-computed from RFC 8949: width boundaries, the CDE-vs-length-first ordering discriminator, hash-input framing; it catches a byte-order flip the property probes pass)
- `manifest_test`
- `schema_coverage_test` (the card recognizes every effect a built driver canonicalizes, under the schema id the driver signs over — so no built family's card is schema-unknown with its Approve hidden; found: LEZ-FROST's lez-call)
- `manifest_precision_test` (exo-ec8 — every generated manifest says exactly what its action needs, touches and discloses: unique touches, chains in CAIP-2 and accounts in CAIP-10, the environment requirement named as environment(); a Safe payee only on a transfer, an amount on a transfer (even a template), on a call only when ETH moves, never on a delegatecall; a Safe's signers, policy, nonce and gas public; a LEZ action naming every account it passes and the program it calls; `lez-rpc`, not `lez_core`, on the live LEZ paths)
- `distinct_signer_test` (exo-a5a — a k-of-n decision needs k distinct signers: a contribution counts only under the name of the signer the driver identifies, checked before dedup; one signature under two names is one approval, a forgery never takes a member's slot, governance cannot be completed alone; threshold and Safe; `$SECP` + `$SODIUM`)
- `card_words_test` (exo-59c — the card and the room history say what each family's intent does, over every generated (kind, variant): no proposal reads as "a payment: 0 →"; a Bitcoin spend names its payment output (change excluded) in sat, a LEZ transfer its amount in token units, a module action its call; submit/final lines follow the family's settlement; contributors are named from the address book by identity, Ed25519 key or secp address; "approved by me" is read from the log + this member's keys, and a key binding counts only when its own signer is that approver)
- `store_node_view_test` (exo-661.7 — what a store node reads off a room's topic: over the app's join-by-name flow (two founders, one admits the other, a non-founding member admits a third), no member's Ed25519 key, X25519 key, secp256k1 address or binding signature appears in any retained frame, no data or grant frame carries an epoch tag at either end, and each asker still reads from its own epoch on, F-16)
- `founder_restart_test` (exo-7b3 — invariant 4 across a restart, over the app's join-by-name flow with keyfile keystores reopened from disk: a founder's message and proposal from before the first admit come back after a restart, and its state digest is unchanged, because epoch 0's key is the keystore's founding key for the room (`Keystore.foundingKey`), not a random one; F-16 still holds for a restarted joiner and a later one; a replay shows no admitted member as asking to join; every launch announces a join key the topic never carried, so a store node cannot link one member's launches)
- `authorship_test` (exo-f76 — an author-bearing event counts only when its author signed it: forged, wrong-key, cross-room, tampered and malformed author events are dropped, genuine ones count, over the wire included; §11: a voice note's part names its author in its key, every `voice` shape author-bearing; §12: a re-announced account disclosure re-seals the copy whose `after` its author signed, not a copy another member planted that the log keeps, and every member, a later joiner included, reads it with the author's order (`publishAuthored`, for every author-signed kind); `$SECP` + `$STINT` + `$SODIUM`)
- `parts_fold_test` (exo-a90.2 — settlement in parts, over a test driver that is not the split: the threshold comes from the parties the effect names (describeFor); a part is settled by its party and confirmed by the counterparty; any settled → submitted, any confirmed → settling, all confirmed → final; a report by a disallowed author, or before agreement, never counts; a bare submit / final never moves a parts intent; 200 reorder + duplicate trials converge)
- `split_driver_test` (exo-a90.3 — the split's one spelling and every refusal, only a named debtor's room key agrees, the parts, conformance, the each-locus profile and card rows, evm-split@<CAIP-2> resolution, even shares, the room fold to final on the real driver)
- `split_live_test` (exo-a90.4 — paying and confirming on the live room path over a fake ledger: no payment before agreement, the payment is the derived share, the report waits for the payer's tx, the creditor confirms only what her read shows, one tx settles one share, received outside muster, expiry refuses a payment)
- `log_proof_test`
- `malformed_sig_test` (exo-cf7 — a malformed signature is never fatal: the verifiers, both owner-signature drivers, the fold with a hostile approval in the log, join-request bindings, authorizations; needs `$SECP` + `$SODIUM`)
- `decline_test`
- `provenance_all_test`
- `flow_test`
- `room_infra_test` (exo-428 — the room's infrastructure is dictated by its drivers; also needs `$SECP` for the real Safe driver)
- `rpc_url_redaction_test` (exo-14f.2 — a configured RPC URL never reaches text whole: `wallet/redact.nim` shows scheme, host and port, `***` for userinfo and for any path, query or fragment; the split composer's "your RPC did not answer", the room's RPC connectivity row (which the MUSTER-LP debug log prints) and the readiness card's details carry neither `user:pass@` nor a `/v3/<key>` path, against an endpoint that refuses and one that answers; web3 + `$SECP` + `$SODIUM`)
- `materialshare_test` (exo-45e K5)
- `schema_unknown_test` (exo-1ec.3 — the schema-driven rendering gate)
- `action_corpus_test` (exo-661 A2 — the action atlas's generated half: `contracts/actions/generated.json` must equal what `tools/action_corpus.nim` reads off the running drivers — describe / environment / profile / manifest / signRefusal for each fixed (kind, variant) — byte for byte; regenerate with `TEST_ARGS=--write tests/run-suite.sh action_corpus`; `$SECP` + `$STINT` + web3 + `$SODIUM`)

**Phase A — Safe and the family profile.**

- `phase_a_exit_test` (exo-a50.1.7 — Phase A exit: two Safes, two chains, two rooms, no globals, card rows only from the profile; needs `$SECP` + `$STINT`)
- `settlement_test` (exo-a50.1.5 — the settlement seam: chosen by profile, assembled from the log, submitted through the ChainAdapter; needs `$SECP` + `$STINT`)
- `safe_fidelity_test` (exo-a50.1.4 — every SafeTx field reaches the signed hash, the real ten-argument execTransaction, delegatecall disclosed + refused unless allowlisted, modules/guard decoding; needs `$SECP`)
- `accounts_test` (exo-a50.1.3 — accounts disclosed by members into the room; two Safes on two chains in one room; the chain check; needs `$SECP`)
- `kinds_test` (exo-a50.1.2 — the one list of driver kinds; an unknown kind refuses, never a silent Safe; needs `$SECP`)
- `profile_test` (exo-a50.1.1 — every driver declares its multisig family profile, held to describe() and to contracts/families/registry.json both ways; needs `$SECP`)

**Phase B — Bitcoin through PSBT.**

- `btc_outside_signer_test` (exo-a50.2.6 — signers outside muster, seam S8: a Bitcoin intent exports as a PSBT, an outside signer's PSBT imports as counted + unattested, another spend's refused; readiness asks the Bitcoin node which chain it serves; needs `$SECP`)
- `btc_settlement_test` (exo-a50.2.5 — the Bitcoin settlement: a spend built from UTXOs, only driver-accepted signatures, P2WSH + tapscript witnesses finalized in script key order, the reviewed tx broadcast; needs `$SECP` + `$STINT`)
- `btc_inapp_test` (exo-a50.2.4 — a member signs Bitcoin in-app through the keystore, attested; an outside signature counts, unattested; needs `$SECP`)
- `btc_driver_test` (exo-a50.2.3 — the Bitcoin multisig driver: P2WSH sortedmulti + tapscript multi_a accounts, sighashes, contributions, conformance, signRefusal, kinds, PSBT both ways; needs `$SECP`)
- `psbt_test` (exo-a50.2.2 — PSBT v0 + BIP-371 against the BIP-174/371 vectors; the canonical form never hashes PSBT bytes; pure Nim)
- `bitcoin_primitives_test` (exo-a50.2.1 — Bitcoin primitives pinned to the official BIP-143 / BIP-340 / BIP-341 / BIP-350 vectors in `tests/vectors/`; needs `$SECP`)

**Phase C — the LEZ multisig.**

- `lez_multisig_rebuilt_test` (exo-3c9 — the rebuilt program's account-ids layout: target accounts committed + bound at execute, checked on the S5 re-read; the card names no bypass; count-only keeps #40; §5 holds the decoder and PDA derivation to real chain bytes, from a local LEZ v0.2.4 sequencer (`vectors/lez-multisig-v024/`) and from the public testnet deployment (`vectors/lez-multisig-testnet/`); the room accepts the testnet multisig as a `lez:testnet` account)
- `lez_tx_test` (exo-3c9: LEZ v0.2.4 public transactions byte for byte against LEZ's own crates, `vectors/lez-tx-v024/` + its generator: instruction words, message borsh + hash, BIP-340 witnesses, sendTransaction payload, deployment, base58 ids; needs `$SECP`)
- `lez_member_keys_test` (exo-3c9: fresh LEZ member keys per label, derived in the keystore, never exported; `$SECP` + `$SODIUM`)
- `lez_multisig_live_e2e` (exo-3c9: the room drives the program on a REAL v0.2.4 chain: `infra/lez/localnet.sh`, or the public testnet with `https://testnet.lez.logos.co 40`; args `[sequencerUrl] [blockSeconds]`, `MUSTER_LEZ_MULTISIG_BIN` deploys first; needs the web3 closure (chronos, json-rpc, bearssl) + `$SECP` + `$SODIUM`)
- `phase_c_exit_test` (exo-84f — the Phase C exit: the LEZ multisig vote locus against the program model: disclose + verify, propose on chain, a member's own vote after an S5 re-read, a mismatched pointer refused before any vote, settle on the chain's count, the card; needs `$SECP`)
- `lez_settlement_test` (exo-0c9 — count the votes on chain, re-read at settle, Execute, final when Executed)
- `lez_vote_test` (exo-12a1 — voting in the room: S5 read, cast, confirm, receipt + room-key attestation; refusals cast and publish nothing; needs `$SECP`)
- `lez_multisig_driver_test` (exo-6cbe — the vote-locus driver: disclosure with config, pointer effect, receipts, S5 checkRead, profile/conformance; needs `$SECP`)
- `lez_multisig_chain_test` (exo-946 — the chain seam + FakeLezMultisig, the program's handlers in process; pure Nim)
- `lez_multisig_model_test` (exo-a26 — lez-multisig's borsh state/proposals, SPEL seeds, versioned PDAs; pure Nim)
- `lez_readiness_test` (exo-44b L1)

**Phase D — FROST.**

- `frost_dkg_sign_test` (Phase D — a 2-of-3 ChillDKG key signs under FROST as one BIP-340 signature libsecp accepts; recovery; needs `$SECP` + `$STINT`)
- `frost_keystore_test` (S7: host keys, the ceremony steps, nonces consumed before use, shares recovered from public recovery data, a restart aborts; `$SECP` + `$STINT` + `$SODIUM`)
- `btc_frost_driver_test` (the btc.frost-bip445 driver: account from recovery data, key-path sighashes, round-tagged contributions, aggregation into one witness signature, the profile)
- `frost_ceremony_room_test` (the ceremony and both rounds over a three-member room's log)
- `phase_d_exit_test` (Phase D exit on a FRESH regtest bitcoind: in-room ChillDKG, then a spend Core cannot tell from single-sig)
- `lez_frost_account_e2e` (a FROST key owns a LEZ public account on a real v0.2.4 sequencer; web3 closure)
- `lez_frost_room_e2e` (exo-55e: a FROST group acts on LEZ from the room — in-room ceremony on lez:local, a lez-call at the chain-read nonce, both rounds, settled; a stale nonce refused; web3 closure + a local sequencer)
- `frost_chilldkg_test` (exo-fae — ChillDKG against all 249 draft vectors in `tests/vectors/chilldkg/`)
- `frost_signing_test` (exo-d7e — BIP-445 FROST signing against all 266 draft vectors in `tests/vectors/bip-0445/`)
- `frost_group_test` (exo-b9c — points with infinity, scalars mod n; BIP-340 in those operations agrees with libsecp)

**Voice notes (`docs/design/voice-notes.md`).**

- `voice_clip_test` (§3.2, §5 — the clip record: a round trip re-encodes byte for byte, one small record held to hand-computed CDE bytes; every refusal a value naming why (codec settings, packet lengths 1..1275, samples over 60 s, a packet count other than ceil((samples + preskip) / 960), the shape, a 3,000-mutation fuzz); `maxClipBytes` is 126,119 at 60 s and 1,166 at 500 ms, and refuses a negative or over-cap length; pure Nim, no libopus)
- `voice_codec_test` (§3.1 — libopus at the fixed settings: every ctl read back (a fixed-arity `opus_encoder_ctl` turns §1 red on Apple arm64); every packet 40 B for a tone, silence and a mix, none padded; a 1 kHz tone back at exactly its length, in phase, its power kept; a packet that does not carry 20 ms of audio (960 samples by its TOC), or bytes that are not a record, refused before libopus decodes; the 60 s cap; prints `opus_get_version_string`; `$OPUS`)
- `audio_io_test` (§9 — the device seam with no device, on `SyntheticAudioIo` and `FileAudioIo`, through the `captureInto` / `playFrom` the device callback runs: a capture paced 48 frames a millisecond, its write index monotone, exactly the cap then `capped`, frames past it dropped; the peak, reset on read (32768 for int16.low); playback consumed whole, zeros past the end, then `done` once the buffer's `tail` of silence followed the last sample (0 for these sinks; 1,200 pinned on `playFrom` itself); a WAV source paced by the clock, refused unless 48 kHz mono s16 (`wav-format`) or when cut short (`wav-truncated`); the PCM sink exactly the samples played; `busy`; a nil buffer refused as `no-buffer` before anything opens; a start held on its start thread by a `StartGate` (§7–§9): it returns at once, `starting`, and is stopped after the pump saw it run, let go before it returned (its own thread then freeing the buffer), stopped after it returned but before any pump saw it (§8b: the module thread finishes it), or failed, and past four in flight it is `device-start-slow`; pure Nim)
- `audio_io_null_test` (§9 — `MiniaudioIo` on miniaudio's null backend: a real device thread, no device, no permission prompt, at most about 1 s a block: capture frames within 1 s, all zero, stop and close idempotent; every stream read back as 48 kHz mono s16 (`streamFormat`; otherwise `device-format`); a 0.2 s cap stops at 9,600 frames and sets `capped`; playback 48,000 frames a second ±5%, measured between two reads; a short buffer `done` only after the device's 1,920-frame tail of silence; a second start while one runs is `busy`, a nil buffer `no-buffer`; `backendNames`: abNull is Null alone, abSystem never Null and never empty; starts on their own start thread: 80 stopped or closed at once, each let go before it returned (§6), and starts that returned before any pump, whose running device the stop or close then closes (§6b); `$MA`)
- `session_pad_test` (§4, §5 — fixed-size sealed frames, over `LocalTransport` with every frame on the topic recorded: every `voice/` frame is exactly 90,153 B (1 + 24 + 16 + `VoiceFrameBytes` 90,112) with no pad passed, for a 1 KB and a worst-case 84 KB value with 0, 1 and 8 heads and on the held path, the JSON followed by spaces only; prints the worst case's measured JSON (85,257 B, 4,855 B to spare); a padded frame decodes through the unchanged ingest path, live and from the journal, into the same event; FrameTooLarge, and a wrong or negative pad, raise before the log, the journal or the transport see anything; padTo 0 is today's frame byte for byte, held to literals; a padded author-signed event keeps both signatures; `$SECP` + `$SODIUM`)
- `voice_test` (§3.3, §6, §7 — voice events, the fold and thread rows, over `LocalTransport` with synthetic CDE clips (40-byte packets: the fold checks structure and digest and never decodes audio, so no libopus): the note id is 16 bytes of a `muster.voice.note-id.v1` record over (author, clip digest, ts), the clip digest a `muster.voice.clip.v1` record; `voiceEvents` is exactly two `voice/<nid>/<author>/<i>/2` parts, integers only, the record's halves as canonical base64; a member folds another's note complete, the clip byte for byte; every voice frame 90,153 B at 0.5, 10 and 60 s; forged, unsigned, cross-room, edited and squatted parts drop out (over the wire too); a malformed key or value is dropped, never raised (whitespace in a part's base64 above all, which std/base64's decode reads past the end of, and a durMs no clip has), and any string at all is a part's half only as canonical base64; arriving, broken (parts that disagree, either one the odd one, a digest miss, a bad record or length) and the first copy in canonical order standing; any order and duplication folds the same (invariant 4); `threadRows` merges messages and notes by (ts, id), either kind first at one ts, a voice row's body empty and its `voice` field metadata under 300 B, the newest row's ts counting a note, and a `message/` whose body claims `voice-note` stays its author's plain row (§7); a member admitted later folds no earlier note (F-16); a `VoiceMemo` of verdicts keyed by the standing parts' ids changes no fold, and a part that comes to stand in another's place is judged afresh; the memo's part headers, by event id, change no fold output either (`reduceVoice`, `threadRows`, `threadLastTs`, `voiceStanding`, `voiceRecordOf`, `voiceNoteOf`, byte for byte, in any order, duplicated and as the set grows), each part is parsed once and a new part alone (`voiceParses`), and a later copy or a key of no part's shape never is (§16); `reduceFlow`, `logProvenance` and `reduceRoomGraph` take the memo too, each output the memo-less one in any order, a cold memo parsing each part once across the three and a warm one none, the map's content of a part read off its header and only an entry under `voice/` that holds no part's value parsed again, for its content (§17); `threadLastTs`, from the header pass alone, is the newest row's ts; disclosure (§10, S6), where a part is one the fold stands (`voiceStanding`, the header pass) in every view: `reduceFlow` gives each part exactly `voice-note` and `voice-note-length` to its epoch's key holders and `timing`, `topic` and `fixed-size` to the store node, nothing to anyone else, and an entry under `voice/` that is no note's part (a key the fold refuses, a value it refuses, an equivocating later copy, a squatted note id) the store node's three rows alone; in the room map each part is an author-signed `voice` entry credited to the member its key names, counted exactly when the fold names it in a note's parts (of two copies of one part, only the first by canonical order), its store-node facet naming the one fixed size, its content `v`, `ts`, `durMs` and `digest` at most, field by field, and no 48-character stretch of any half, at every 24-character step and at its end, anywhere in the map `toJson` serves (coordinate_graph); `logProvenance` lists each part as a peer message in its author's name at the epoch that opened it; an entry that is no note's part stays its signer's in the map, uncounted, with a facet that says both (as `swarm_test` §8 now pins for `file/` entries), and is not in provenance; `$SECP` + `$SODIUM`). The probes `probe_voice_fixed_size_stepper` (0.5–60 s × 0, 1, 8 heads × two epochs, and the held path: every frame 90,153 B), `probe_voice_author_stepper` (six part forms × either part, the forged `voice-note` row, and five strings with whitespace that std/base64's decode reads past the end of × either part) and `probe_voice_order_stepper` (every order, duplication and subset of a note's parts with an equivocating copy) are stepper oracles over the shared fixture `probes/voice_room.nim`, for a spec the maintainer has not yet assigned an exo id. `probe_voice_fixed_size_stepper` is also the test the claims registry names for "A voice note's length does not show in its size" (FS-9, `contracts/claims/registry.json`), so `scripts/check-claims-registry.py` fails if it moves
- `voice_live_test` (§8, §9 — the hosted half, `VoiceRecorder`, the state machine the seven voice methods run, with two members over `LocalTransport`, each recorder on `SyntheticAudioIo` and a virtual clock, libopus encoding and decoding for real: a 3 s 1 kHz tone recorded, stopped into a draft of 3,000 ms, sent as two 90,153 B frames, folded complete by the other member, whose playback sink holds exactly the clip's samples with a 1 kHz Goertzel peak, idle again once the pump sees `done`; the 60 s cap ending a 70 s source at 60,000 ms with `capped`, released by the pump alone; an all-zero recording refused at Send as `silent` with the platform note (the macOS words on macOS) and nothing on the log or the topic; 499 ms `too-short`, 500 ms sent; `busy`, `no-draft`, `not-recording`, `not-joined` with nothing opened; play's `unknown-note`, `incomplete` and `broken`, a note the fold calls complete but libopus refuses included; incremental encoding (after 59 s of pumps Stop encodes 0.5 s); discard, of a draft or a recording; one memo of verdicts per room, served on the second read; the room's memo keeps each part's header too, so over an unchanged log the rows and `lastTs` parse 0 parts, a new part alone is parsed and the part that completes a note reads its other half back once (`voiceParses`, `voiceHalfReads`), Play reads its note in one pass and reads back the two halves it decodes, and `forgetRoom` (coordinate_leave) drops a room's memo (§27); the recorder procs coordinate_flow, coordinate_graph, coordinate_provenance and coordinate_conversations call (`flowRows`, `graphOf`, `provenanceOf`, `lastTs` over the events the method read) give the memo-less folds' output over the room's memo, each part parsed once across them and none on the next poll, or at all once the thread's rows have read the room (§28); `voiceIoChoice` (MUSTER_VOICE_SOURCE / _SINK, MUSTER_VOICE_BACKEND) and `FileAudioIo` end to end, a WAV in and the clip's samples in the PCM sink; miniaudio's null device, whose zeros Send refuses, its context released when the stream ends; close, idempotent; a Send refused between its parts keeps the draft, the sender's own fold already calling the note complete, and its retry re-sends both parts held, the same note; a recording of nothing, or of 300 ms of zeros, `too-short`, not `silent`, with no microphone note; Start, Play and Send each pump first, so a playback heard to its end is not `busy` and Send finds the draft the cap made; a draft sent through another room's session `room-changed`, nothing published, kept; Send and Discard while the draft plays, a sink that refuses a write past a file-size limit (`sink-write`), a start the device refuses and close, each releasing the device; the rows `coordinate_messages` serves (`messagesJson`); `coordinate_proof`'s refusal (`roomProof`) for a room whose view holds a part the fold stands, a note arriving, complete or broken, and a proof that accounts for every raw entry for a room whose log holds only junk under `voice/` (unsigned, a forged author, a malformed value, a squatted note id, keys of the wrong shape); a member's long, unsigned copy of part 0 that the author's log keeps does not block the author's retry, which re-seals the copy the author signed; both parts logged and journalled before the first frame reaches the transport, for a 1 s and a 59 s note alike (the two sends back to back); `voice_record_start` and `voice_play` answering at once while a `StartGate` holds the device's start (`starting`), and Stop, Discard and close around a start in flight, before it returned and after it (§29–§31); and every reply, in every state, carries no `part`, no base64 run over 64, no float and under 1 KB; `$SECP` + `$SODIUM` + `$OPUS` + `$MA`)
- `voice_device_e2e` (§9, S11 — the real microphone and speaker, `MiniaudioIo` on the system backend; gated behind `MUSTER_VOICE_REAL`, in run-suite's E2E list, so never in the default run: below; `$OPUS` + `$MA`)

No test in the default run opens a real audio device: miniaudio runs on its null backend,
with no microphone, no speaker and no permission prompt. Which `AudioIo` the hosted module
makes is `voice_live.voiceIoChoice`'s, read from the environment and held by
`voice_live_test`: `MUSTER_VOICE_SOURCE` (a 48 kHz mono s16 WAV) or `MUSTER_VOICE_SINK` (a raw
PCM file) give `FileAudioIo`, `MUSTER_VOICE_BACKEND=null` the null device, anything else the
platform's own backends. A real device means a real microphone and, on macOS, a permission
only the person can grant.

So the real-device test, `voice_device_e2e` (S11), is in run-suite's E2E list and gated
behind `MUSTER_VOICE_REAL`. It runs by name only, never by default, and its microphone leg
only with the person's consent. Without `MUSTER_VOICE_REAL` it prints a `SKIP` line and
exits 0, and the runner counts it as skipped, not passed. Only a test in the runner's E2E list
may skip: any other test that prints a `SKIP <name>:` line FAILs, with a message saying so, so
a skip cannot hide a test that never ran.

```bash
MUSTER_VOICE_REAL=1 module/tests/run-suite.sh e2e voice_device_e2e         # both legs
MUSTER_VOICE_REAL=speaker module/tests/run-suite.sh e2e voice_device_e2e   # the speaker only
```

- It opens `MiniaudioIo` on the system backend (Core Audio on macOS; PulseAudio, then ALSA,
  on Linux) through the same `AudioIo` seam the module uses. Nothing is mocked.
- **The microphone leg** (`mic`, or `1`) captures 2 s. The stream must read back as 48 kHz
  mono s16, and frames must arrive at 48 a millisecond, ±5%. The write index must only grow,
  and the 2 s cap must stop it at exactly 96,000 frames with `capped` set, as on the null
  device. The capture then goes through the module's own libopus path at the fixed settings
  and back, and its length must be kept. Audio never leaves the process: nothing is written
  to a file, and the only numbers printed from it are its peak and RMS. A capture of nothing
  but zeros fails, with a message naming the likely cause: on macOS, the microphone
  permission of the app macOS holds responsible (the terminal app, or the app that started
  the shell), or a default input that hears nothing (muted, its volume at zero, or a virtual
  loopback device such as BlackHole, which gives frames of silence while nothing plays into
  it). A start that gives no frame at all within 5 s fails apart from that. That has not been
  seen, so its message names no cause for certain and asks for another input.
- When the microphone's start stalls, the message gives the tccd log command that shows
  which app macOS asked: the microphone prompts, and the lines naming this test's binary,
  where `responsible=` is that app. It spells out `/usr/bin/log`, since zsh's own `log`
  builtin refuses those arguments.
- `MUSTER_VOICE_REAL` must name a leg: `1`, `all`, `mic`, `speaker`, or a comma list of
  those. Any other value fails, and so does one of separators alone (`,`), which used to pass
  with nothing run.
- **The speaker leg** (`speaker`, or `1`) plays through the real output device: 48,000
  frames a second, ±5%, and `done` only after the device's own tail of silence, as
  `audio_io_null_test` §3 does. By default it plays digital silence (zeros), so nothing can be
  heard. Only `MUSTER_VOICE_REAL_AUDIBLE=1` plays a short quiet tone: 0.5 s of 440 Hz at
  about -30 dBFS.
- A device start returns at once and the device starts on a thread of its own, so the test
  pumps until the start lands. A start that never lands, or a stop or close that never
  returns, is caught by a watchdog thread, which prints what it waited on and exits 1. A
  microphone permission prompt nobody answers does this on macOS. A start call that takes
  100 ms or more to return fails the leg.
  That ends the whole test, so a leg after the one that stalled does not run: run it alone
  (`MUSTER_VOICE_REAL=speaker`). A leg that fails a check is recorded, and the next leg
  still runs.
- The speaker leg's "`done` only after the device's own tail" holds by `audio_io`'s rule,
  which sets `done` only past that tail: it guards the rule, and measures nothing of when the
  sound is heard. The tail it reads back is miniaudio's buffer and periods (1,920 frames on
  Core Audio, as on the null device), not the output's own latency.

What its first run found (2026-10-22, on a Mac): see `docs/design/voice-notes.md` §17 S11. The traps
the audio tests guard are in
[`docs/labbook/voice-notes-audio-stack.md`](../../docs/labbook/voice-notes-audio-stack.md).

**Monero (epic exo-dcc, ADR-018).**

- `monero_address_test` (exo-dcc.5 — `src/monero/address.nim` held to monero-project/monero at `24272e4`: block-wise base58 against `tests/unit_tests/base58.cpp`; every network's standard, subaddress and integrated address from `tests/functional_tests/validate_address.py`, with the keys and payment ids the functional tests state; `check_address`'s key refusals, including a point outside the prime-order subgroup; the CAIP-2 references re-derived from `cryptonote_config.h`'s genesis constants; `acceptablePayTo`'s refusals; `make_uri` / `parse_uri` and their amount and percent-encoding rules; `$STINT`)

## Running one test by hand

Materialize the closure once (or let the runner do it), then build the flag groups
from it. Every command below runs from `module/`.

```bash
D=$(tools/nim-closure.sh)     # ~/.cache/muster/nimpkgs, at metadata.json's pins
SECP="--path:$D/nim-secp256k1 --path:$D/nim-stew --path:$D/nim-results --path:$D/nimcrypto"
STINT="--path:$D/nim-stint --path:$D/nim-stew --path:$D/nim-results --path:$D/nim-intops/src"
W3="--path:$D/nim-eth --path:$D/nim-web3 --path:$D/nim-chronos --path:$D/nim-chronicles \
    --path:$D/nim-bearssl --path:$D/nim-faststreams --path:$D/nim-json-rpc \
    --path:$D/nim-serialization --path:$D/nim-json-serialization --path:$D/nim-http-utils"
SODIUM="--passL:$(nix build nixpkgs#libsodium --no-link --print-out-paths)/lib/libsodium.so"
OPUS="--passL:$(nix build "$(tools/builder-nixpkgs.sh)#libopus.out" --no-link --print-out-paths)/lib/libopus.so"   # the .lgx's 1.5.2
MA="--path:$D/miniaudio"      # C source only: src/audio/miniaudio.nim finds it and compiles it
nim r -d:release --threads:on $SECP $STINT $SODIUM tests/epoch_crypto_test.nim
```

Which group a test needs:

- **None** — pure Nim: `dcbor_golden_test`, `manifest_test`, `log_proof_test`,
  `psbt_test`, `lez_multisig_chain_test`, `lez_multisig_model_test`, and most probes.
- **`$OPUS`** — the voice codec, `src/audio/opus.nim` through `voice_codec`:
  `voice_codec_test`, `voice_live_test`, `voice_device_e2e`. `voice_clip_test` needs none.
- **`$MA`** — the audio devices, `src/audio/miniaudio.nim`: `audio_io_null_test`,
  `voice_live_test` (§13), `voice_device_e2e`. Without it the compile stops at
  `miniaudio.h is on no --path`. `audio_io_test` needs none.
- **`$SODIUM`** — anything whose import closure reaches `crypto/curve25519` (the
  Ed25519/X25519 encryption identity), which is most of the room: `decline_test`,
  `provenance_all_test`, `flow_test`, `materialshare_test`, `schema_unknown_test`,
  `lez_readiness_test`, and every test that seals or encrypts (`epoch_crypto_test`
  F-16, `keystore_test`, `coordination_test`, `multiparty_intent_test`,
  `coordination_surface_test`, `membership_handshake_test`, `store_node_view_test`, `founder_restart_test`, `two_instance_test` — the
  full cross-host journey — `governance_test`, `threshold_fold_test`).
- **`$SECP`** — anything importing `src/crypto/secp256k1.nim` or a secp-signing driver
  (`secp256k1_test`, `safe_test`, `safe_collect_test`, `binding_test`,
  `conformance_test`, `readiness_test`, `authorization_test`, and the crypto and
  coordination tests). `nim-secp256k1` vendors and compiles its own C (the closure
  clones it with its submodule); no system libsecp256k1 is linked.
- **`$STINT`** — amounts: `wallet_types_test` alone; with `$SECP` + `$SODIUM` for
  `wallet_mock_test`, `material_test`, `offers_test`, `null_ladder_test` and the
  holdings-catalogue probe `probes/probe_catalogue_no_leak.nim` (spec `derived-exo-45e`).
- **`$W3`** — nim-eth and the web3 stack: `wallet_verify_test` (the reused nim-eth
  proof primitive), `wallet_sign_test` (EIP-155 signing vs the canonical vector),
  `wallet_rpc_test`, `rpc_budget_test`, and anything importing `evm_adapter` (`wallet_evm_test`,
  `coordinate_submit_anvil`), a LEZ chain seam (`lez_multisig_live_e2e`,
  `lez_frost_*_e2e`), `drivers/safe_rpc.nim` — whose calls run on chronos under
  `wallet/rpc_budget.nim` since exo-14f — directly or through `readiness` / `settlement`
  (`safe_owners_test`, `safe_fidelity_test`, `settlement_test`, `readiness_test`), or
  `wallet/btc_adapter.nim`, whose node calls run on chronos's HTTP client since exo-496
  (the `btc_*` and Bitcoin split tests, the regtest e2e tests, the btc probes). websock is
  deliberately not needed: the code imports `web3/eth_api` + `json_rpc/clients/httpclient`
  (and `chronos/apps/http/httpclient`), not top-level `web3`.

### The host-return probe

`probes/probe_return_marshalling_host.nim` (spec `derived-exo-526`) builds the host
harness `probes/host_return_harness.nim` with the module compiled in, and reads what a
CLIENT observes. The harness calls the module's `logos_module_*` C ABI through `importc`,
and the module's own constructor (the one the generated surface installs, as in the plugin)
initializes the one Nim runtime, so the harness is built `--noMain`. It was C++ linked
against a staticlib until exo-607 T7; a Nim harness cannot link a second Nim runtime, and
the port's trace is identical to the C++ one's. Its inner `nim c` reads the closure from
`$MUSTER_NIMPKGS` (default `~/.cache/muster/nimpkgs`), and the harness links secp256k1,
libsodium and libopus: an explicit `MUSTER_SECP256K1_LIB` / `MUSTER_SODIUM_LIB` /
`MUSTER_OPUS_LIB` wins (run-suite exports the last two), then `pkg-config`, then a
filesystem glob over `/nix/store`. miniaudio needs no flag: the closure's checkout is on the
inner `--path`, and the module compiles it. The harness defines the `lp_*`
inter-module ABI as a host with no protocol stack and reports `lp_stub_calls` (0: nothing
the probe calls reaches another module). Besides health, propose and status, it calls
`voice_status` (voice notes, S3): it must be in the method table as QString, and its JSON
must name the libopus the harness links (`opus_get_version_string`), with `ready.capture` and
`ready.playback` still "unknown", since reading it opens no device. Since S7 it also calls
the six other voice methods, `coordinate_messages` and `coordinate_proof` through the
generated dispatch with no room joined, each listed as QString and replying exactly what
that state gives (`{"error":"not-joined"}`, `{"error":"not-recording"}`,
`{"error":"no-draft"}`, `"ok"`, `[]`), and reads `voice_status` again: no device opened.

```bash
tests/run-suite.sh return_marshalling
```

## On-chain tests

**anvil + the Safe fixture.** `infra/anvil/devnet.sh` starts anvil, deploys and funds
the real Safe v1.4.1 (singleton, factory, fallback handler, a 2-of-3 proxy), and
prints `SAFE_ADDR`. Each test takes `<safeAddr> [rpcUrl]`. They share the Safe's nonce,
so the runner runs e2e tests one at a time. `safe_anvil_e2e` and `coordinate_submit_anvil`
each assume a **fresh** devnet (each signs its first transaction at nonce 0, and
`safe_anvil_e2e` expects an unfunded recipient), so give each its own: restart the devnet
between them (`pkill -x anvil; infra/anvil/devnet.sh`). `safe_real_anvil_e2e` reads the
live nonce and runs on any devnet.

- `safe_anvil_e2e` — the single-instance path: collect 2-of-3 owner signatures
  locally, assemble `execTransaction`, submit, confirm the transfer on-chain.
- `safe_real_anvil_e2e` — against the contract itself: muster's safeTxHash equals the
  Safe's own `getTransactionHash` for a transaction that uses every field; the
  disclosure check reads `getOwners` + `getThreshold` and the bypasses (modules, guard)
  from the chain; a data-carrying CALL executes through the ten-argument
  `execTransaction`.
- `coordinate_submit_anvil` — the ROOM-SIDE path (`coordinate_submit`): the owner
  signatures travel through the coordination **log** (propose + contribute events);
  the room folds to executable, the signatures are gathered *from the log*, assembled,
  and submitted through the adapter. A successful `execTransaction` proves the room's
  re-derived safeTxHash matches the contract's on-chain `getTxHash`.

**Bitcoin Core regtest.** `infra/bitcoind/regtest.sh` starts a FRESH regtest chain
(RPC `127.0.0.1:18443`, `muster`/`muster`, `-txindex`; `nix shell nixpkgs#bitcoind`
provides the binaries). Stop any other instance first: `phase_d_exit_test` needs a
fresh chain.

- `btc_regtest_e2e` — the Phase B exit (exo-a50.2.7). For both
  `btc.p2wsh-sortedmulti` and `btc.tapscript-multi-a`: muster derives the address
  Bitcoin Core derives from the descriptor; funds it and builds a spend from the UTXOs
  the node reports; a member approves in-app through the keystore (attested); an
  outside signer — a Bitcoin Core wallet holding the third key — signs muster's
  exported PSBT and the imported signature counts, graded unattested; the settlement
  finalizes the witnesses and the adapter broadcasts; final a block later, the payee
  paid.
- `phase_d_exit_test` — the Phase D exit: an in-room ChillDKG, then a spend Core cannot
  tell from single-sig.

```bash
nix shell nixpkgs#bitcoind -c bash infra/bitcoind/regtest.sh   # from the repo root; `… regtest.sh stop` stops it
module/tests/run-suite.sh e2e btc_regtest_e2e
```

**A LEZ v0.2.4 sequencer.** `infra/lez/localnet.sh` runs one on `127.0.0.1:3040` (the
first build takes 5–15 minutes; its header lists the toolchain, including what a machine
with no system g++ needs, and `docs/labbook/lez-multisig-versions.md` the reasons).
`lez_multisig_live_e2e` deploys the program first when `MUSTER_LEZ_MULTISIG_BIN` names the
guest — `make build` in `logos-co/lez-multisig` (PR #45 or later), which reproduces the
testnet's ImageID `2ced3d30…d4c7`. The public testnet works too:
`TEST_ARGS="https://testnet.lez.logos.co 40"`.
