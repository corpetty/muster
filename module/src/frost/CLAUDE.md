# module/src/frost/

Threshold Schnorr on secp256k1 (Phase D, epic exo-a50.4): FROST signing (BIP-445 draft,
bitcoin/bips#2070) and its key ceremony ChillDKG (draft, bitcoin/bips#2227). The aggregate
is one BIP-340 signature, so to the chain a FROST account looks single-sig.

- `secp.nim` — points with an explicit infinity over libsecp256k1's ABI, and scalars mod n
  over stint (inverse by Fermat). This is what the drafts' reference code (secp256k1lab)
  assumes and libsecp's public API lacks.
- `signing.nim` — FROST signing, a port of the BIP-445 reference (`frost_ref/signing.py`
  @ siv2r/bips 8e25d57), with its error messages verbatim. It covers nonce gen/agg,
  sign (which spends the secnonce), partial-signature verify, aggregation into one BIP-340
  signature, plain and x-only tweaks, and deterministic signing. It is held to every
  vector in `tests/vectors/bip-0445/`.
- `schnorr.nim` — BIP-340 with a tag prefix, plain/x-only key generation, and libsecp-style
  ECDH. These are what ChillDKG takes from secp256k1lab; its proofs of possession use a
  prefix libsecp's schnorrsig cannot.
- `chilldkg.nim` — ChillDKG, a port of the draft reference (`chilldkg_ref` @ mllwchrry/bips
  2b9b0b1): VSS, SimplPedPop, EncPedPop and CertEq, the participant and coordinator steps,
  investigation and recovery. The reference's exceptions are carried as one `DkgError`
  (class name, message, blamed ids). It is held to every vector in
  `tests/vectors/chilldkg/`. The coordinator only relays, so in a room every member can
  compute its steps from the log.

Rules:
- Every algorithm is a port of the draft's Python reference at a named commit, pinned to
  the draft's own vectors. A draft change is a re-pin, never a silent drift.
- NOT constant time (stint branches on values). This is demo-grade, like the MPC candidate.
  The production gate in landscape §9 applies: re-choose the implementation before real
  funds.
- Secrets (shares, nonces) never enter the room log. Holding them is the keystore's job
  (seam S7, exo-24a).
