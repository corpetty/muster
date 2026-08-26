# module/tests

Most probes/tests run with bare `nim r -d:release tests/<name>.nim` (pure Nim,
no external deps) — this is how the exophial spec oracles under `tests/probes/`
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
(e.g. `wallet_evm_test`) need the full web3 closure — clone with bearssl's
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
`binding_test`, `conformance_test` — the driver conformance suite run against stub +
Safe — and the crypto/coordination tests). We no longer link a system
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
