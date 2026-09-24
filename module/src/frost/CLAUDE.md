# module/src/frost/

Threshold Schnorr on secp256k1 (Phase D, epic exo-a50.4): FROST signing (BIP-445 draft,
bitcoin/bips#2070) and its key ceremony ChillDKG (draft, bitcoin/bips#2227). The aggregate
is one BIP-340 signature, so to the chain a FROST account looks single-sig.

- `secp.nim` — points with an explicit infinity over libsecp256k1's ABI, and scalars mod n
  over stint (inverse by Fermat). This is what the drafts' reference code (secp256k1lab)
  assumes and libsecp's public API lacks.

Rules:
- Every algorithm is a port of the draft's Python reference at a named commit, pinned to
  the draft's own vectors. A draft change is a re-pin, never a silent drift.
- NOT constant time (stint branches on values). This is demo-grade, like the MPC candidate.
  The production gate in landscape §9 applies: re-choose the implementation before real
  funds.
- Secrets (shares, nonces) never enter the room log. Holding them is the keystore's job
  (seam S7, exo-24a).
