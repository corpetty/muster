# module/tests

## Run them

One command runs every test that needs no chain — 92 unit tests and the 55 invariant
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
`.lgx` does. It takes libsodium from nixpkgs (and, for the host-return probe,
secp256k1 and `g++`), and builds every test with one flag set: the union of the
`$SECP`, `$STINT`, web3, SDK and libsodium flags below. An extra `--path` is harmless
to a pure-Nim test. Each test's log lands in `$OUT` (a fresh temp dir unless set),
and the summary names every failure. Env: `JOBS` (8), `TEST_TIMEOUT` (900 s),
`TEST_ARGS` (appended to each selected test's command line, for an e2e test's own
arguments), `MUSTER_NIMPKGS` (the closure dir).

**Chain-bound tests never run by default.** Bring the chain up first
([on-chain tests](#on-chain-tests)), then run one by name:

| test | chain | arguments (defaults) |
|---|---|---|
| `safe_anvil_e2e`, `safe_real_anvil_e2e`, `coordinate_submit_anvil` | anvil + the Safe fixture, `infra/anvil/devnet.sh` | `<safeAddr> [rpcUrl]` (`http://127.0.0.1:8545`) — the Safe address is required |
| `btc_regtest_e2e`, `phase_d_exit_test` | a **fresh** Bitcoin Core regtest, `infra/bitcoind/regtest.sh` | `[rpcUrl] [user] [password]` (`http://127.0.0.1:18443`, `muster`, `muster`) |
| `lez_multisig_live_e2e`, `lez_frost_account_e2e`, `lez_frost_room_e2e` | a LEZ v0.2.4 sequencer, `infra/lez/localnet.sh`, or the public testnet | `[sequencerUrl] [blockSeconds]` (`http://127.0.0.1:3040`, `15`); `lez_multisig_live_e2e` also reads `MUSTER_LEZ_MULTISIG_BIN` |

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
- `log_proof_test`
- `malformed_sig_test` (exo-cf7 — a malformed signature is never fatal: the verifiers, both owner-signature drivers, the fold with a hostile approval in the log, join-request bindings, authorizations; needs `$SECP` + `$SODIUM`)
- `decline_test`
- `provenance_all_test`
- `flow_test`
- `room_infra_test` (exo-428 — the room's infrastructure is dictated by its drivers; also needs `$SECP` for the real Safe driver)
- `materialshare_test` (exo-45e K5)
- `schema_unknown_test` (exo-1ec.3 — the schema-driven rendering gate)

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
nim r -d:release --threads:on $SECP $STINT $SODIUM tests/epoch_crypto_test.nim
```

Which group a test needs:

- **None** — pure Nim: `dcbor_golden_test`, `manifest_test`, `log_proof_test`,
  `psbt_test`, `lez_multisig_chain_test`, `lez_multisig_model_test`, and most probes.
- **`$SODIUM`** — anything whose import closure reaches `crypto/curve25519` (the
  Ed25519/X25519 encryption identity), which is most of the room: `decline_test`,
  `provenance_all_test`, `flow_test`, `materialshare_test`, `schema_unknown_test`,
  `lez_readiness_test`, and every test that seals or encrypts (`epoch_crypto_test`
  F-16, `keystore_test`, `coordination_test`, `multiparty_intent_test`,
  `coordination_surface_test`, `membership_handshake_test`, `two_instance_test` — the
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
  `wallet_rpc_test`, and anything importing `evm_adapter` (`wallet_evm_test`,
  `coordinate_submit_anvil`) or a LEZ chain seam (`lez_multisig_live_e2e`,
  `lez_frost_*_e2e`). websock is deliberately not needed: the code imports
  `web3/eth_api` + `json_rpc/clients/httpclient`, not top-level `web3`.

### The host-return probe

`probes/probe_return_marshalling_host.nim` (spec `derived-exo-526`) builds the module
as a Nim staticlib (the shape the real cdylib build produces), links it into the C++
host harness `probes/host_return_harness.cpp`, and reads what a CLIENT observes. Its
inner `nim c` reads the closure from `$MUSTER_NIMPKGS` (default
`~/.cache/muster/nimpkgs`), and the harness links secp256k1 and libsodium: an explicit
`MUSTER_SECP256K1_LIB` / `MUSTER_SODIUM_LIB` wins, then `pkg-config`, then a
filesystem glob over `/nix/store`. The harness defines the `lp_*` inter-module ABI as a
host with no protocol stack and reports `lp_stub_calls` (0: nothing the probe calls
reaches another module). It needs `g++`; the runner borrows nixpkgs' when the host has
none.

```bash
tests/run-suite.sh return_marshalling
```

## On-chain tests

**anvil + the Safe fixture.** `infra/anvil/devnet.sh` starts anvil, deploys and funds
the real Safe v1.4.1 (singleton, factory, fallback handler, a 2-of-3 proxy), and
prints `SAFE_ADDR`. Each test takes `<safeAddr> [rpcUrl]`. They share the Safe's nonce,
so the runner runs e2e tests one at a time; `safe_anvil_e2e` also assumes a **fresh**
devnet (it signs at nonce 0 and expects an unfunded recipient), so run it first or
restart the devnet (`pkill -x anvil; infra/anvil/devnet.sh`).

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
first build takes about 15 minutes; its header lists the toolchain, and
`docs/labbook/lez-multisig-versions.md` the reasons). The public testnet works too:
`TEST_ARGS="https://testnet.lez.logos.co 40"`.
