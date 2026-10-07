# The typed attestation's vectors come from Foundry, not from muster (2026-10-07)

ADR-017 K6b (exo-149.6): `coordination/attest_typed.nim` builds the EIP-712 documents a
platform-held key signs for the attestation over P and for the identity binding. muster's
EIP-712 hashing (`wallet/keystore_legs.typedDataHash`) was already held to Safe's own
`safeTxHash`; the Muster documents add types that path never exercised (`string`, `bytes`,
`uint64`, `uint32`, `bytes32`, and a domain with no `verifyingContract`). So the vectors in
`module/tests/attest_typed_test.nim` §1 are signatures **Foundry** made over the same
documents, and muster's must equal them byte for byte. Both sides sign with RFC 6979
deterministic nonces, so equal signatures mean equal hashes; Foundry's v is 27/28, and so is
muster's.

To re-derive them (after a deliberate change to a document's shape, never to make a red test
green):

```
D=$(mktemp -d)
TEST_ARGS="--emit $D" module/tests/run-suite.sh attest_typed
CAST=$(nix build nixpkgs#foundry --no-link --print-out-paths | tail -1)/bin/cast
K=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil key 0
$CAST wallet sign --private-key $K --data --from-file $D/attestation.json
$CAST wallet sign --private-key $K --data --from-file $D/binding.json
```

Frozen with cast 1.8.4.

Two decisions made while building it, both written into ADR-017:

- `materialization` is `bytes`, not `bytes32`. A driver's materialization root is not always
  32 bytes, and hashing it to fit would put a value in front of the person that matches
  nothing they can compare. For a Safe it is the 32-byte `safeTxHash`, which the signer also
  shows as the SafeTx leg's signing hash, so the two can be read side by side.
- A verifier never reads the typed document from the wire. It rebuilds it from what it
  recomputed from the log and recovers the signer over that hash. "The rendering disagrees
  with P" therefore needs no separate field-by-field check: any other rendering is another
  hash, and recovers to another address.
