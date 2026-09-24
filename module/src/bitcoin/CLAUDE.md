# module/src/bitcoin/

Bitcoin, as far as a multisig family needs it (Phase B, exo-a50.2; design
`docs/design/multisig-landscape.md`). Pure functions — no network, no wallet, no keys
held: transactions and their segwit serialization, the two signature-hash algorithms
a Bitcoin multisig signs (BIP-143 for P2WSH, BIP-341/342 for taproot script paths),
the scripts (`sortedmulti`, `multi_a`), bech32/bech32m addresses, taproot output keys
and control blocks, and DER / BIP-340 Schnorr signing and verification over
nim-secp256k1.

- `tx.nim` — `BtcTx`, compact sizes, (de)serialization, txid, sha256d, tagged hashes
- `script.nim` — push encoding, sortedmulti witnessScript, multi_a leaf, P2WSH / P2TR scriptPubKeys
- `sighash.nim` — BIP-143 and BIP-341/342 signature hashes
- `bech32.nim` — BIP-173 / BIP-350 segwit addresses
- `taproot.nim` — leaf / branch / tweak hashes, the output key, control blocks, the NUMS internal key
- `keys.nim` — DER ECDSA (low-S) and BIP-340 Schnorr sign / verify, compressed and x-only keys
- `psbt.nim` — BIP-174 v0 + BIP-371 taproot fields: strict parse, lossless re-serialize, typed access to partial / tapscript signatures, the Combiner, and `canonicalBytes` (the spend, never the PSBT encoding)

Rules: everything here is pinned to the official BIP test vectors
(`module/tests/bitcoin_primitives_test.nim`). A transaction's canonical muster form is
never its raw bytes or a PSBT — the driver canonicalizes the semantic inputs (inv 5).
