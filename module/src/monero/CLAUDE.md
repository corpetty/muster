# module/src/monero/

Monero, as far as a split paid in XMR needs it (epic exo-dcc, ADR-018 in
`docs/02-implementation-plan.md`, plan `docs/design/monero-in-rooms.md`). Pure functions:
no keys, no network, no lp_*. Muster holds no Monero key; the wallet is the platform's
`monero_wallet_backend`, reached elsewhere.

- `address.nim`: Monero's block-wise base58 (not Bitcoin's), `encode_addr` / `decode_addr`,
  the address tags per network and kind, `parseAddress` (a typed result or a refusal, never
  a raise), the CAIP-2 map (`monero:<genesis-hash prefix>`), `acceptablePayTo` (the agreed
  chain's standard or subaddress kind; integrated refused), amounts as wallet2 prints and
  parses them, and the `monero:` payment URI as `make_uri` / `parse_uri` write and read it.
- `point.nim`: whether a 32-byte public key is one `check_address` accepts: it decompresses,
  is not the identity, and lies in the prime-order subgroup. Pure Nim over stint; not
  constant time, and it only ever reads public keys.

Rules:
- Every rule is read from monero-project/monero, and each one's source is named in the
  code. `module/tests/monero_address_test.nim` holds them to that repo's own vectors.
  Where muster's rule and the source differ, the source wins.
- Case is never normalised. An address is the exact string.
- The address checksum is Monero's Keccak over Monero's encoding. It is not on muster's
  signing path, which commits to the chain id and the payTo string (invariant 5).
- Rules and sources: `docs/labbook/monero-address-rules.md`.
