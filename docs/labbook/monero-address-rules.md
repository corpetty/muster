# What Muster checks in a Monero address, and where each rule comes from

**exo-dcc.5, 2026-10-08.** `module/src/monero/address.nim` (with `point.nim`) is a pure
parser: no keys, no network, no lp_*. The split driver and the hosted surface use it to
refuse a `payTo` on the wrong network (ADR-018: the binding is `implicit`, invariant 2),
to map a network to its CAIP-2 id, and to build the `monero:` URI a debtor's wallet pays
from. Every rule below was read from monero-project/monero at **`24272e4`** (master,
2026-10-08), and `module/tests/monero_address_test.nim` holds each one to that repo's own
vectors.

## The checks, in the order wallet2 makes them

`cryptonote_basic_impl.cpp` `get_account_address_from_str` calls `base58::decode_addr`, then
matches the tag, then parses the keys, then runs `check_address`. Muster keeps that order,
and each step gives its own refusal:

| Step | Refusal | Source |
|---|---|---|
| Block-wise base58: 8-byte blocks become 11 characters, and a short last block uses `encoded_block_sizes = {0,2,3,5,6,7,9,10,11}`. A block whose value is wider than its byte count is refused, and so is any length that is no block size | `bad-base58` | `src/common/base58.cpp` `decode` / `decode_block` |
| More than 4 bytes decoded | `bad-length` | `decode_addr` |
| The last 4 bytes equal the first 4 of Keccak-256 over the rest. This is pre-NIST Keccak (`cn_fast_hash`), which is muster's `hashing/keccak256` (padding `0x01`) | `bad-checksum` | `decode_addr` |
| The tag is a canonical LEB128 varint (no redundant zero byte, no overflow) | `unknown-tag` | `src/common/varint.h` `read_varint` |
| The tag is one of the nine below | `unknown-tag` | `src/cryptonote_config.h` |
| Exactly 64 bytes after the tag (the spend key, then the view key), or 72 for an integrated address (plus an 8-byte payment id). Nothing may follow | `bad-length` | `parse_binary` → `serialization.h` `check_stream_state` (requires EOF) |
| Each key decompresses (y < p, an x exists, and no sign on x = 0), is not the identity, and l·P = identity | `bad-key` | `check_address` → `rctOps.cpp` `isInMainSubgroup` → `crypto-ops.c` `ge_frombytes_vartime` |

The tags, from `cryptonote_config.h` `CRYPTONOTE_PUBLIC_{ADDRESS,INTEGRATED_ADDRESS,SUBADDRESS}_BASE58_PREFIX`:

| Network | Standard | Integrated | Subaddress | CAIP-2 |
|---|---|---|---|---|
| mainnet | 18 (`4…`) | 19 (`4…`) | 42 (`8…`) | `monero:418015bb9ae982a1975da7d79277c270` |
| testnet | 53 (`9…`) | 54 (`A…`) | 63 (`B…`) | `monero:48ca7cd3c8de5b6a4d53d2861fbdaedc` |
| stagenet | 24 (`5…`) | 25 (`5…`) | 36 (`7…`) | `monero:76ee3cc98646292206cd3e86f74d88b4` |

A standard address or subaddress is 95 characters, and an integrated address is 106.

Case is part of the address. Muster never trims or normalises it: `" 4…"` and a case-flipped
character are both refused.

## acceptablePayTo(addr, chain)

- The chain must be one of the three CAIP-2 ids, matched exactly. Otherwise the refusal is
  `unknown-chain`.
- The address must parse (above), and its tag's network must be the chain's. Otherwise the
  refusal is `wrong-network`.
- An integrated address is refused (`integrated-address`). ADR-018 uses no payment ids, the
  platform backend does not forward them, and a subaddress per request replaces them.
  `wallet2::make_uri` itself accepts integrated addresses: this is Muster's rule, not
  Monero's.

## CAIP-2: re-derived, not only read

ADR-018 read the genesis hashes from live nodes. The test also recomputes them from the
source's own constants. `cryptonote_tx_utils.cpp` `generate_genesis_block` builds the
header (major 1, minor 0, timestamp 0, prev_id 0, `GENESIS_NONCE`) over the coinbase
`GENESIS_TX`. The block hash is `Keccak(varint(len) ‖ header ‖ Keccak(tx) ‖ varint(1))`
(`get_block_hashing_blob` with `get_object_hash`). Mainnet gives the well-known
`418015bb…4632e3`, and all three prefixes match ADR-018's.

Mainnet and testnet share `GENESIS_TX`. Only the nonce (10000 or 10001) separates them.

## The payment URI

`wallet2.cpp` `make_uri`:
- The URI is `monero:<address>`, then the fields that are present in this fixed order:
  `tx_amount`, `recipient_name`, `tx_description`. The first follows a `?` and the rest
  follow a `&`.
- `tx_amount` is omitted when the amount is 0.
- The amount is `print_money`, which writes the atomic units left-padded to 13 digits with a
  point 12 from the end. Trailing zeros are kept: 1.5 XMR is `1.500000000000`.
- The text fields are `conver_to_url_format` (`contrib/epee/src/abstract_http_client.cpp`).
  A byte is written as `%XX`, in upper-case hex, when it is ≤ 32, ≥ 123, or one of
  `get_unsave_chars`: `` "<>%\^[]`+$,@:;!#&= ``.
  - `/` and `?` are not escaped. They were in an older, commented-out version of the list.
  - Every UTF-8 byte ≥ 0x80 is escaped.

`parse_uri_impl`, which Muster mirrors for tests:
- The scheme must be exactly `monero:`.
- The address must be on the wallet's network.
- Parameters are split on `&` and then `=`. A parameter must have exactly one `=`, and no
  parameter may appear twice.
- `tx_amount` is `parse_amount`:
  - whitespace is trimmed;
  - trailing zeros past the twelfth decimal are dropped, and more than 12 decimals is
    refused;
  - the rest must be digits only, and overflow is refused.
- `tx_payment_id` must be 64 hex characters, and is refused with an integrated address.
- `convert_from_url_format` decodes `%XX` only when both characters are hex. Anything else,
  a truncated `%2` included, is kept as written.
- Unknown parameters are returned verbatim.

## Surprises

- **`check_address` checks the subgroup, not only the curve.** A key of the form P + T,
  with T of order 2, decompresses but is refused. The test builds one from a real key,
  since (x, y) + (0, −1) = (−x, −y), and a mutation that skips the l·P step turns the test
  red.
- **Two of base58.cpp's "too short" negatives never reach the length check.** `999999` and
  `ZZZZZZ` decode to 4 bytes, but 8·(58⁶−1)/57 ≈ 5.3·10⁹ ≥ 2³², so `decode_block` refuses
  them as an overflow first. Muster reports both as `bad-base58`.
- **`jerj2e4mESo` has a good checksum.** It fails on the tag, because `FF 00` is a varint
  with a redundant zero byte (`EVARINT_REPRESENT`).

## Not verified from source

- **Other wallets.** Muster builds the URI wallet2's way. Cake and Feather were not read:
  that they parse `tx_amount` with 12 decimals and the same escapes is assumed, not
  checked.
- **`tx_payment_id` hex parsing.** Muster accepts exactly 64 hex characters, in either case.
  epee's `parse_hexstr_to_binbuff` is case-insensitive (`contrib/epee/src/hex.cpp`), but its
  character-skipping path was not traced. Only `parsePaymentUri` reads payment ids, and
  Muster never builds one into a URI.
