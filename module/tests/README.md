# module/tests

Most probes/tests run with bare `nim r -d:release tests/<name>.nim` (pure Nim,
no external deps; `manifest_test` and `log_proof_test` too, and `dcbor_golden_test` — known-answer bytes for invariant 5, hand-computed from RFC 8949: width boundaries, the CDE-vs-length-first ordering discriminator, hash-input framing; it catches a byte-order flip the property probes pass). `malformed_sig_test` (exo-cf7 — a malformed signature is never fatal: the verifiers, both owner-signature drivers, the fold with a hostile approval in the log, join-request bindings, authorizations; needs `$SECP` + `$SODIUM`) / `decline_test` / `provenance_all_test` / `flow_test` / `room_infra_test` (exo-428 — the room's infrastructure is dictated by its drivers; also needs `$SECP` for the real Safe driver) / `frost_dkg_sign_test` (Phase D — a 2-of-3 ChillDKG key signs under FROST as one BIP-340 signature libsecp accepts; recovery; needs `$SECP` + `$STINT`) / `frost_keystore_test` (S7: host keys, the ceremony steps, nonces consumed before use, shares recovered from public recovery data, a restart aborts; `$SECP` + `$STINT` + `$SODIUM`) / `btc_frost_driver_test` (the btc.frost-bip445 driver: account from recovery data, key-path sighashes, round-tagged contributions, aggregation into one witness signature, the profile) / `frost_ceremony_room_test` (the ceremony and both rounds over a three-member room's log) / `phase_d_exit_test` (Phase D exit on a FRESH regtest bitcoind: in-room ChillDKG, then a spend Core cannot tell from single-sig) / `lez_frost_account_e2e` (a FROST key owns a LEZ public account on a real v0.2.4 sequencer; web3 closure) / `lez_frost_room_e2e` (exo-55e: a FROST group acts on LEZ from the room — in-room ceremony on lez:local, a lez-call at the chain-read nonce, both rounds, settled; a stale nonce refused; web3 closure + a local sequencer) / `frost_chilldkg_test` (exo-fae — ChillDKG against all 249 draft vectors in `tests/vectors/chilldkg/`) / `frost_signing_test` (exo-d7e — BIP-445 FROST signing against all 266 draft vectors in `tests/vectors/bip-0445/`) / `frost_group_test` (exo-b9c — points with infinity, scalars mod n; BIP-340 in those operations agrees with libsecp) / `lez_multisig_rebuilt_test` (exo-3c9 — the rebuilt program's account-ids layout: target accounts committed + bound at execute, checked on the S5 re-read; the card names no bypass; count-only keeps #40; §5 holds the decoder and PDA derivation to real chain bytes, from a local LEZ v0.2.4 sequencer (`vectors/lez-multisig-v024/`) and from the public testnet deployment (`vectors/lez-multisig-testnet/`); the room accepts the testnet multisig as a `lez:testnet` account) / `lez_tx_test` (exo-3c9: LEZ v0.2.4 public transactions byte for byte against LEZ's own crates, `vectors/lez-tx-v024/` + its generator: instruction words, message borsh + hash, BIP-340 witnesses, sendTransaction payload, deployment, base58 ids; needs `$SECP`) / `lez_member_keys_test` (exo-3c9: fresh LEZ member keys per label, derived in the keystore, never exported; `$SECP` + `$SODIUM`) / `lez_multisig_live_e2e` (exo-3c9: the room drives the program on a REAL v0.2.4 chain: `infra/lez/localnet.sh`, or the public testnet with `https://testnet.lez.logos.co 40`; args `[sequencerUrl] [blockSeconds]`, `MUSTER_LEZ_MULTISIG_BIN` deploys first; needs the web3 closure (chronos, json-rpc, bearssl) + `$SECP` + `$SODIUM`) / `phase_c_exit_test` (exo-84f — the Phase C exit: the LEZ multisig vote locus against the program model: disclose + verify, propose on chain, a member's own vote after an S5 re-read, a mismatched pointer refused before any vote, settle on the chain's count, the card; needs `$SECP`) / `lez_settlement_test` (exo-0c9 — count the votes on chain, re-read at settle, Execute, final when Executed) / `lez_vote_test` (exo-12a1 — voting in the room: S5 read, cast, confirm, receipt + room-key attestation; refusals cast and publish nothing; needs `$SECP`) / `lez_multisig_driver_test` (exo-6cbe — the vote-locus driver: disclosure with config, pointer effect, receipts, S5 checkRead, profile/conformance; needs `$SECP`) / `lez_multisig_chain_test` (exo-946 — the chain seam + FakeLezMultisig, the program's handlers in process; pure Nim) / `lez_multisig_model_test` (exo-a26 — lez-multisig's borsh state/proposals, SPEL seeds, versioned PDAs; pure Nim) / `btc_outside_signer_test` (exo-a50.2.6 — signers outside muster, seam S8: a Bitcoin intent exports as a PSBT, an outside signer's PSBT imports as counted + unattested, another spend's refused; readiness asks the Bitcoin node which chain it serves; needs `$SECP`) / `btc_settlement_test` (exo-a50.2.5 — the Bitcoin settlement: a spend built from UTXOs, only driver-accepted signatures, P2WSH + tapscript witnesses finalized in script key order, the reviewed tx broadcast; needs `$SECP` + `$STINT`) / `btc_inapp_test` (exo-a50.2.4 — a member signs Bitcoin in-app through the keystore, attested; an outside signature counts, unattested; needs `$SECP`) / `btc_driver_test` (exo-a50.2.3 — the Bitcoin multisig driver: P2WSH sortedmulti + tapscript multi_a accounts, sighashes, contributions, conformance, signRefusal, kinds, PSBT both ways; needs `$SECP`) / `psbt_test` (exo-a50.2.2 — PSBT v0 + BIP-371 against the BIP-174/371 vectors; the canonical form never hashes PSBT bytes; pure Nim) / `bitcoin_primitives_test` (exo-a50.2.1 — Bitcoin primitives pinned to the official BIP-143 / BIP-340 / BIP-341 / BIP-350 vectors in `tests/vectors/`; needs `$SECP`) / `phase_a_exit_test` (exo-a50.1.7 — Phase A exit: two Safes, two chains, two rooms, no globals, card rows only from the profile; needs `$SECP` + `$STINT`) / `settlement_test` (exo-a50.1.5 — the settlement seam: chosen by profile, assembled from the log, submitted through the ChainAdapter; needs `$SECP` + `$STINT`) / `safe_fidelity_test` (exo-a50.1.4 — every SafeTx field reaches the signed hash, the real ten-argument execTransaction, delegatecall disclosed + refused unless allowlisted, modules/guard decoding; needs `$SECP`) / `accounts_test` (exo-a50.1.3 — accounts disclosed by members into the room; two Safes on two chains in one room; the chain check; needs `$SECP`) / `kinds_test` (exo-a50.1.2 — the one list of driver kinds; an unknown kind refuses, never a silent Safe; needs `$SECP`) / `profile_test` (exo-a50.1.1 — every driver declares its multisig family profile, held to describe() and to contracts/families/registry.json both ways; needs `$SECP`) / `materialshare_test` (exo-45e K5) / `schema_unknown_test` (exo-1ec.3 — the schema-driven rendering gate) / `lez_readiness_test` (exo-44b L1) are pure Nim but link libsodium
(its import closure reaches curve25519) — run it with the `$SODIUM` flag below — this is how the exophial spec oracles under `tests/probes/`
are graded.

**Exception — the wallet tests need the stint closure on the Nim path** (the same
packages `metadata.json` `codegen.nim.packages` pins; the module build fetches
them, but a local `nim r` needs `--path`). `wallet_types_test` needs only these;
`wallet_mock_test`/`wallet_evm_test` also need libsecp256k1 + libsodium (keystore
identity). Clone the four once, then:

```bash
D=/tmp/nimpkgs; mkdir -p $D
git -C $D clone --depth 1 https://github.com/status-im/nim-stint
git -C $D clone --depth 1 https://github.com/status-im/nim-stew
git -C $D clone --depth 1 https://github.com/arnetheduck/nim-results
git -C $D clone --depth 1 https://github.com/status-im/nim-intops
STINT="--path:$D/nim-stint --path:$D/nim-stew --path:$D/nim-results --path:$D/nim-intops/src"
nim r -d:release $STINT tests/wallet_types_test.nim
```

`wallet_verify_test` (verified state reads, the reused nim-eth proof primitive)
also needs nim-eth + nimcrypto on the path:

```bash
git -C $D clone --depth 1 https://github.com/status-im/nim-eth
git -C $D clone --depth 1 https://github.com/cheatfate/nimcrypto
NIMETH="$STINT --path:$D/nim-eth --path:$D/nimcrypto"
nim r -d:release $NIMETH tests/wallet_verify_test.nim
```

`wallet_sign_test` (client-side EIP-155 tx signing vs the canonical vector) needs
nim-eth + the secp closure (`$SECP` below):

```bash
nim r -d:release --threads:on $SECP $STINT --path:$D/nim-eth tests/wallet_sign_test.nim
```

`wallet_rpc_test` (the nim-web3 RPC seam) and anything importing `evm_adapter`
(e.g. `wallet_evm_test`, and `coordinate_submit_anvil` since exo-a50.1.5 settles through
the adapter) need the full web3 closure — check each clone out at the rev
`module/metadata.json` pins (`codegen.nim.packages`); HEADs drift and fail to build — clone with bearssl's
submodule, and note websock is deliberately NOT needed (we import `web3/eth_api` +
`json_rpc/clients/httpclient`, not top-level `web3`):

```bash
for r in nim-web3 nim-chronos nim-chronicles nim-faststreams nim-json-rpc \
         nim-serialization nim-json-serialization nim-http-utils; do
  git -C $D clone --depth 1 https://github.com/status-im/$r; done
git -C $D clone --depth 1 --recurse-submodules https://github.com/status-im/nim-bearssl
W3="--path:$D/nim-web3 --path:$D/nim-chronos --path:$D/nim-chronicles --path:$D/nim-bearssl \
    --path:$D/nim-faststreams --path:$D/nim-json-rpc --path:$D/nim-serialization \
    --path:$D/nim-json-serialization --path:$D/nim-http-utils"
nim r -d:release --threads:on $W3 $SECP $STINT --path:$D/nim-eth tests/wallet_rpc_test.nim
```

**Exception — anything importing `src/crypto/secp256k1.nim` or `src/drivers/safe.nim`
uses `nim-secp256k1` on the path** (`secp256k1_test`, `safe_test`, `safe_collect_test`,
`binding_test`, `demo_contacts_test` (exo-1fc — golden vectors for the demo pre-seeded chat ids; $SECP + libsodium), `invites_test` (exo-3f0 — inbox-topic determinism + invite seal/open round-trip; $SECP + libsodium), `safe_owners_test` (exo-45e K3), `keyed_contribute_test` (exo-45e K5/K2b — signWith by ref), `keybinding_test` (exo-45e K5 — the per-key F-14 binding published on a keyed contribution; $SECP + libsodium), `lez_readiness_test`+`lez_provision_test` (exo-44b — LEZ detect + the provisioning fallback), `material_test` + `offers_test` + `lez_modeb_test` + `composer_step_test` (exo-45e K2a/K4/ModeB/step-three — catalogue, offers, and the coordinated-transfer counterparty slot; need $STINT + libsodium), `null_ladder_test` (exo-1ec.5 — the null ladder typed onto the ChainAdapter seam; $STINT + libsodium), `conformance_test` — the driver conformance suite run against stub +
Safe — `readiness_test` (the action-manifest readiness probe against a real SafeDriver, exo-002.2), `authorization_test` (muster-issued grants, exo-002.7) and the crypto/coordination tests). We no longer link a system
libsecp256k1 — `nim-secp256k1` vendors and compiles its own C (clone with
`--recurse-submodules`). Its own deps are stew + results + nimcrypto:

```bash
git -C $D clone --depth 1 --recurse-submodules https://github.com/status-im/nim-secp256k1
SECP="--path:$D/nim-secp256k1 --path:$D/nim-stew --path:$D/nim-results --path:$D/nimcrypto"
nim r -d:release --threads:on $SECP tests/safe_collect_test.nim
```

The tests that also seal/encrypt (`epoch_crypto_test` F-16, `keystore_test`,
`coordination_test`, `multiparty_intent_test`, `coordination_surface_test`,
`membership_handshake_test`, `two_instance_test` (the full cross-host journey),
`governance_test` (driver-as-proposal), and `threshold_fold_test` — the Ed25519 k-of-n
driver folding through the generic reduceIntents) additionally need libsodium and,
where they touch amounts, the stint closure:

```bash
SODIUM=$(nix build nixpkgs#libsodium --no-link --print-out-paths)
nim r -d:release --threads:on $SECP $STINT --passL:"$SODIUM/lib/libsodium.so" \
  tests/epoch_crypto_test.nim
```

The holdings catalogue (`material_test`, exo-45e K2) and its no-leak probe
(`probes/probe_catalogue_no_leak.nim`, spec `derived-exo-45e` oracle s1) use the
same `$SECP` + `$STINT` + libsodium closure (keystore + wallet types):

```bash
nim r -d:release --threads:on $SECP $STINT --passL:"$SODIUM/lib/libsodium.so" \
  tests/material_test.nim
```

**Exception — the host-return probe needs g++ + secp256k1:**
`probes/probe_return_marshalling_host.nim` builds the module as a Nim staticlib
(the shape the real cdylib build produces) and links it into the C++ host harness
`probes/host_return_harness.cpp`, which reproduces the shipped
Nim->C++->host-client return marshalling and reads what a CLIENT observes. Point
it at secp256k1 the same way — an explicit `MUSTER_SECP256K1_LIB` wins, else
`pkg-config --libs libsecp256k1`, else a bare `-lsecp256k1`:

```bash
MUSTER_SECP256K1_LIB="-L/path/to/secp/lib -lsecp256k1 -Wl,-rpath,/path/to/secp/lib" \
  nim r -d:release tests/probes/probe_return_marshalling_host.nim
```

**On-chain tests (need a live anvil + the MiniSafe fixture).** Bring the devnet up
with `infra/anvil/devnet.sh` (starts anvil, deploys + funds MiniSafe, prints
`SAFE_ADDR`). Both take `<safeAddr> [rpcUrl]` and use the `$SECP`/`$STINT` closures:

- `safe_anvil_e2e` — the single-instance path: collect 2-of-3 owner signatures
  locally, assemble `execTransaction`, submit, confirm the transfer on-chain.
- `coordinate_submit_anvil` — the ROOM-SIDE path (`coordinate_submit`): the owner
  signatures travel through the coordination **log** (propose + contribute events);
  the room folds to executable, the signatures are gathered *from the log*,
  assembled, and submitted. A successful `execTransaction` proves the room's
  re-derived safeTxHash matches the contract's on-chain `getTxHash`.

```bash
SAFE=$(infra/anvil/devnet.sh | grep -oE '0x[0-9a-fA-F]{40}' | tail -1)
nim r -d:release --threads:on $SECP $STINT tests/coordinate_submit_anvil.nim "$SAFE"
```

**On-chain Bitcoin test (needs a regtest Bitcoin Core).** `infra/bitcoind/regtest.sh`
starts a FRESH regtest chain (RPC `127.0.0.1:18443`, `muster`/`muster`, `-txindex`;
`nix shell nixpkgs#bitcoind` provides the binaries). `btc_regtest_e2e` — the Phase B
exit (exo-a50.2.7) — takes `[rpcUrl] [rpcUser] [rpcPassword]` and, for both
`btc.p2wsh-sortedmulti` and `btc.tapscript-multi-a`: checks muster derives the address
Bitcoin Core derives from the descriptor; funds it and builds a spend from the UTXOs the
node reports; a member approves in-app through the keystore (attested); an outside
signer — a Bitcoin Core wallet holding the third key — signs muster's exported PSBT and
the imported signature counts, graded unattested; the settlement finalizes the witnesses
and the adapter broadcasts; final a block later, the payee paid. Needs `$SECP` + `$STINT`.

```bash
nix shell nixpkgs#bitcoind -c infra/bitcoind/regtest.sh
nim r -d:release --threads:on $SECP $STINT tests/btc_regtest_e2e.nim
```
