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

**Exception — anything importing `src/crypto/secp256k1.nim` or `src/drivers/safe.nim`
uses `nim-secp256k1` on the path** (`secp256k1_test`, `safe_test`, `safe_collect_test`,
`binding_test`, and the crypto/coordination tests). We no longer link a system
libsecp256k1 — `nim-secp256k1` vendors and compiles its own C (clone with
`--recurse-submodules`). Its own deps are stew + results + nimcrypto:

```bash
git -C $D clone --depth 1 --recurse-submodules https://github.com/status-im/nim-secp256k1
SECP="--path:$D/nim-secp256k1 --path:$D/nim-stew --path:$D/nim-results --path:$D/nimcrypto"
nim r -d:release --threads:on $SECP tests/safe_collect_test.nim
```

The tests that also seal/encrypt (`epoch_crypto_test` F-16, `keystore_test`,
`coordination_test`, `multiparty_intent_test`, `coordination_surface_test`,
`membership_handshake_test`) additionally need libsodium and, where they touch
amounts, the stint closure:

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
