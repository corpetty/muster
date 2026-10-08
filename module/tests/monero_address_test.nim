## Monero addresses, the CAIP-2 map and the `monero:` payment URI (exo-dcc.5, ADR-018).
##
## Every vector below is copied from monero-project/monero at commit
## 24272e4a3b2e812cc2a569d95b177ecef4b91e46 (master, 2026-10-08); each block cites the file.
##
##   1. Block-wise base58 (src/common/base58.cpp), held to tests/unit_tests/base58.cpp:
##      block encodings, whole-string encode/decode, every negative case, encode_addr /
##      decode_addr with their tags, and the refusals decode_addr gives.
##   2. Real addresses on all three networks, every kind (tests/functional_tests/
##      validate_address.py and friends): the network and kind each one names, its keys
##      where the source states them, the payment id of an integrated one, and that
##      re-encoding the parsed fields gives the same string back.
##   3. The checksum is pre-NIST Keccak-256 (cn_fast_hash), which muster's keccak256 is.
##   4. Key validity, as get_account_address_from_str's check_address: a key that is not
##      a point, the identity, a small-order point, a point off the prime-order subgroup and
##      a non-canonical encoding are each refused, though the checksum is good.
##   5. The CAIP-2 map both ways, its references re-derived from cryptonote_config.h's
##      genesis transaction and nonce for each network.
##   6. acceptablePayTo: the agreed chain's standard and subaddress kinds pass; a wrong
##      network, an integrated address, an unknown chain, one changed character, a case
##      flip and a truncated address are refused, each with its reason.
##   7. Amounts as wallet2 prints and parses them (print_money / parse_amount).
##   8. The payment URI: make_uri's format and percent-encoding, derived step by step;
##      parse_uri's behaviour held to tests/unit_tests/uri.cpp.
## Pure: no keys, no network, no lp_*.

import std/[options, strutils]
import stint
import ../src/monero/address
import ../src/hashing/keccak256

proc hx(s: string): seq[byte] =
  doAssert s.len mod 2 == 0
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len: result[i] = byte(parseHexInt(s[2*i .. 2*i+1]))

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii()

proc key32(s: string): array[32, byte] =
  let b = hx(s)
  doAssert b.len == 32
  for i in 0 ..< 32: result[i] = b[i]

proc ff(n: int): seq[byte] =
  result = newSeq[byte](n)
  for x in result.mitems: x = 0xFF

# ── 1. Block-wise base58 (tests/unit_tests/base58.cpp) ─────────────────────────
block encodeBlocks:
  # TEST_encode_block: a block of 1..8 bytes encodes to encoded_block_sizes[n] characters;
  # data of ≤ 8 bytes is one block, so encode() gives exactly the block encoding.
  const blocks = [
    ("00", "11"), ("39", "1z"), ("ff", "5Q"),
    ("0000", "111"), ("0039", "11z"), ("0100", "15R"), ("ffff", "LUv"),
    ("000000", "11111"), ("000039", "1111z"), ("010000", "11LUw"), ("ffffff", "2UzHL"),
    ("00000039", "11111z"), ("ffffffff", "7YXq9G"),
    ("0000000039", "111111z"), ("ffffffffff", "VtB5VXc"),
    ("000000000039", "11111111z"), ("ffffffffffff", "3CUsUpv9t"),
    ("00000000000039", "111111111z"), ("ffffffffffffff", "Ahg1opVcGW"),
    ("0000000000000039", "1111111111z"), ("ffffffffffffffff", "jpXCZedGfVQ"),
    ("0000000000000000", "11111111111"), ("0000000000000001", "11111111112"),
    ("0000000000000008", "11111111119"), ("0000000000000009", "1111111111A"),
    ("000000000000003a", "11111111121"), ("00ffffffffffffff", "1Ahg1opVcGW"),
    ("06156013762879f7", "22222222222"),
    ("05e022ba374b2a00", "1z111111111")]
  for (data, enc) in blocks:
    doAssert base58Encode(hx(data)) == enc, data & " -> " & base58Encode(hx(data))
    let d = base58Decode(enc)
    doAssert d.isSome and d.get == hx(data), "decode " & enc

block encodeWhole:
  # TEST_encode: whole strings of zeros (block-wise: 8 zero bytes are eleven '1's, so 9
  # are 11 + 2), and one block plus a 5-byte tail.
  const zeros = ["11", "111", "11111", "111111", "1111111", "111111111", "1111111111",
                 "11111111111", "1111111111111", "11111111111111", "1111111111111111",
                 "11111111111111111", "111111111111111111", "11111111111111111111",
                 "111111111111111111111", "1111111111111111111111"]
  for i, enc in zeros:
    let data = newSeq[byte](i + 1)
    doAssert base58Encode(data) == enc, $(i + 1) & " zero bytes"
    doAssert base58Decode(enc).get == data
  doAssert base58Encode(hx("06156013762879f7ffffffffff")) == "22222222222VtB5VXc"
  doAssert base58Encode(newSeq[byte]()) == ""

block decodePositive:
  # TEST_decode_pos: '' and runs of 0xFF across block boundaries.
  doAssert base58Decode("").get.len == 0
  const pos = ["5Q", "LUv", "2UzHL", "7YXq9G", "VtB5VXc", "3CUsUpv9t", "Ahg1opVcGW",
               "jpXCZedGfVQ", "jpXCZedGfVQ5Q", "jpXCZedGfVQLUv", "jpXCZedGfVQ2UzHL",
               "jpXCZedGfVQ7YXq9G", "jpXCZedGfVQVtB5VXc", "jpXCZedGfVQ3CUsUpv9t",
               "jpXCZedGfVQAhg1opVcGW", "jpXCZedGfVQjpXCZedGfVQ"]
  for i, enc in pos:
    let d = base58Decode(enc)
    doAssert d.isSome, enc
    doAssert d.get.len == i + 1 and d.get == ff(i + 1), enc

block decodeNegative:
  # TEST_decode_block_neg and TEST_decode_neg: impossible block lengths, overflow of a
  # block's byte width, and symbols outside the alphabet (0 I O l _).
  const neg = [
    "1", "z", "1111", "zzzz", "11111111", "zzzzzzzz",
    "123456789AB1", "123456789ABz", "123456789AB1111", "123456789ABzzzz",
    "123456789AB11111111", "123456789ABzzzzzzzz",
    "5R", "zz", "LUw", "zzz", "2UzHM", "zzzzz", "7YXq9H", "zzzzzz", "VtB5VXd", "zzzzzzz",
    "3CUsUpv9u", "zzzzzzzzz", "Ahg1opVcGX", "zzzzzzzzzz", "jpXCZedGfVR", "zzzzzzzzzzz",
    "123456789AB5R", "123456789ABzz", "123456789ABLUw", "123456789ABzzz",
    "123456789AB2UzHM", "123456789ABzzzzz", "123456789AB7YXq9H", "123456789ABzzzzzz",
    "123456789ABVtB5VXd", "123456789ABzzzzzzz", "123456789AB3CUsUpv9u",
    "123456789ABzzzzzzzzz", "123456789ABAhg1opVcGX", "123456789ABzzzzzzzzzz",
    "123456789ABjpXCZedGfVR", "123456789ABzzzzzzzzzzz", "zzzzzzzzzzz11",
    "10", "11I", "11O11", "11l111", "11_11111111", "1101111111111", "11I11111111111111",
    "11O1111111111111111111", "1111111111110", "111111111111l1111", "111111111111_111111111",
    "01111111111", "11111111110", "11111011111", "I1111111111", "O1111111111",
    "l1111111111", "_1111111111"]
  for enc in neg:
    doAssert base58Decode(enc).isNone, "must refuse " & enc

block encodeDecodeAddr:
  # TEST_encode_decode_addr: tag (a varint) + data + the first 4 bytes of Keccak-256.
  let z64 = newSeq[byte](64)
  let rep = hx("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" &
               "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
  let vectors: seq[(string, uint64, seq[byte])] = @[
    ("21D35quxec71111111111111111111111111111111111111111111111111111111111111111111111111111116Q5tCH", 6'u64, z64),
    ("2Aui6ejTFscjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQVqegMoV", 6'u64, ff(64)),
    ("1119XrkPuSmLzdHXgVgrZKjepg5hZAxffLzdHXgVgrZKjepg5hZAxffLzdHXgVgrZKjepg5hZAxffLzdHXgVgrZKVphZRvn", 0'u64, rep),
    ("111111111111111111111111111111111111111111111111111111111111111111111111111111111111111115TXfiA", 0'u64, z64),
    ("PuT7GAdgbA83qvSEivPLYo11111111111111111111111111111111111111111111111111111111111111111111111111111169tWrH", 0x1122334455667788'u64, z64),
    ("PuT7GAdgbA841d7FXjswpJjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQjpXCZedGfVQVq4LL1v", 0x1122334455667788'u64, ff(64)),
    ("PuT7GAdgbA819VwdWVDP", 0x1122334455667788'u64, hx("11")),
    ("PuT7GAdgbA81efAfdCjPg", 0x1122334455667788'u64, hx("2222")),
    ("PuT7GAdgbA83sryEt3YC8Q", 0x1122334455667788'u64, hx("333333")),
    ("PuT7GAdgbA83tWUuc54PFP3b", 0x1122334455667788'u64, hx("44444444")),
    ("PuT7GAdgbA83u9zaKrtRKZ1J6", 0x1122334455667788'u64, hx("5555555555")),
    ("PuT7GAdgbA83uoWF3eanGG1aRoG", 0x1122334455667788'u64, hx("666666666666")),
    ("PuT7GAdgbA83vT1umSHMYJ4oNVdu", 0x1122334455667788'u64, hx("77777777777777")),
    ("PuT7GAdgbA83w6XaVDyvpoGQBEWbB", 0x1122334455667788'u64, hx("8888888888888888")),
    ("PuT7GAdgbA83wk3FD1gW7J2KVGofA1r", 0x1122334455667788'u64, hx("999999999999999999")),
    ("15p2yAV", 0'u64, newSeq[byte]()),
    ("FNQ3D6A", 0x7F'u64, newSeq[byte]()),
    ("26k9QWweu", 0x80'u64, newSeq[byte]()),
    ("3BzAD7n3y", 0xFF'u64, newSeq[byte]()),
    ("11efCaY6UjG7JrxuB", 0'u64, hx("11223344556677")),
    ("21rhHRT48LN4PriP9", 6'u64, hx("11223344556677"))]
  for (enc, tag, data) in vectors:
    doAssert encodeAddr(tag, data) == enc, "encode_addr " & enc & " got " & encodeAddr(tag, data)
    let d = decodeAddr(enc)
    doAssert d.refusal == mrNone, enc & ": " & $d.refusal
    doAssert d.tag == tag and d.data == data, enc

block decodeAddrNegative:
  # TEST_decode_addr_neg, each with the refusal muster names for it.
  let neg = [
    ("zuT7GAdgbA819VwdWVDP", mrBadBase58),   # a block overflows
    ("0uT7GAdgbA819VwdWVDP", mrBadBase58),   # '0' is not in the alphabet
    ("IuT7GAdgbA819VwdWVDP", mrBadBase58),
    ("OuT7GAdgbA819VwdWVDP", mrBadBase58),
    ("luT7GAdgbA819VwdWVDP", mrBadBase58),
    ("\0uT7GAdgbA819VwdWVDP", mrBadBase58),
    ("PuT7GAdgbA819VwdWVD", mrBadBase58),    # an 8-character last block is no block size
    ("11efCaY6UjG7JrxuC", mrBadChecksum),
    ("jerj2e4mESo", mrUnknownTag),           # FF 00 …: a varint with a redundant zero byte
    ("1", mrBadBase58), ("1111", mrBadBase58),
    ("11", mrBadLength), ("111", mrBadLength), ("11111", mrBadLength),   # ≤ 4 bytes: no
    ("111111", mrBadLength),                                             # room for data
    # base58.cpp names these "address_too_short" too, but decode_block refuses them
    # first: six characters decode to 4 bytes, and "999999" is 8·(58⁶−1)/57 ≈ 5.3·10⁹
    # ("ZZZZZZ" ≈ 2.1·10¹⁰), both ≥ 2³² — a block overflow.
    ("999999", mrBadBase58), ("ZZZZZZ", mrBadBase58)]
  for (enc, want) in neg:
    let d = decodeAddr(enc)
    doAssert d.refusal == want, enc.escape & ": want " & $want & ", got " & $d.refusal

# ── 2. Real addresses on every network, every kind ─────────────────────────────
# tests/functional_tests/validate_address.py check_good_addresses: [network, kind, address].
const goodAddresses = [
  (xmrMainnet, makStandard, "42ey1afDFnn4886T7196doS9GPMzexD9gXpsZJDwVjeRVdFCSoHnv7KPbBeGpzJBzHRCAs9UxqeoyFQMYbqSWYTfJJQAWDm"),
  (xmrMainnet, makStandard, "44Kbx4sJ7JDRDV5aAhLJzQCjDz2ViLRduE3ijDZu3osWKBjMGkV1XPk4pfDUMqt1Aiezvephdqm6YD19GKFD9ZcXVUTp6BW"),
  (xmrTestnet, makStandard, "9ujeXrjzf7bfeK3KZdCqnYaMwZVFuXemPU8Ubw335rj2FN1CdMiWNyFV3ksEfMFvRp9L9qum5UxkP5rN9aLcPxbH1au4WAB"),
  (xmrStagenet, makStandard, "53teqCAESLxeJ1REzGMAat1ZeHvuajvDiXqboEocPaDRRmqWoVPzy46GLo866qRFjbNhfkNckyhST3WEvBviDwpUDd7DSzB"),
  (xmrMainnet, makIntegrated, "4BxSHvcgTwu25WooY4BVmgdcKwZu5EksVZSZkDd6ooxSVVqQ4ubxXkhLF6hEqtw96i9cf3cVfLw8UWe95bdDKfRQeYtPwLm1Jiw7AKt2LY"),
  (xmrMainnet, makSubaddress, "8AsN91rznfkBGTY8psSNkJBg9SZgxxGGRUhGwRptBhgr5XSQ1XzmA9m8QAnoxydecSh5aLJXdrgXwTDMMZ1AuXsN1EX5Mtm"),
  (xmrMainnet, makSubaddress, "86kKnBKFqzCLxtK1Jmx2BkNBDBSMDEVaRYMMyVbeURYDWs8uNGDZURKCA5yRcyMxHzPcmCf1q2fSdhQVcaKsFrtGRsdGfNk"),
  (xmrTestnet, makIntegrated, "AApMA1VuhiCaHzr5X2KXi2Zc9oJ3VaGjkfChxxpRpxkyKf1NetvbRbQTbFMrGkr85DjnEH7JsBaoUFsgKwZnmtnVWnoB8MDotCsLb7eWwz"),
  (xmrTestnet, makSubaddress, "BdKg9udkvckC5T58a8Nmtb6BNsgRAxs7uA2D49sWNNX5HPW5Us6Wxu8QMXrnSx3xPBQQ2iu9kwEcRGAoiz6EPmcZKbF62GS"),
  (xmrTestnet, makSubaddress, "BcFvPa3fT4gVt5QyRDe5Vv7VtUFao9ci8NFEy3r254KF7R1N2cNB5FYhGvrHbMStv4D6VDzZ5xtxeKV8vgEPMnDcNFuwZb9"),
  (xmrStagenet, makIntegrated, "5K8mwfjumVseCcQEjNbf59Um6R9NfVUNkHTLhhPCmNvgDLVS88YW5tScnm83rw9mfgYtchtDDTW5jEfMhygi27j1QYphX38hg6m4VMtN29"),
  (xmrStagenet, makSubaddress, "73LhUiix4DVFMcKhsPRG51QmCsv8dYYbL6GcQoLwEEFvPvkVvc7BhebfA4pnEFF9Lq66hwvLqBvpHjTcqvpJMHmmNjPPBqa"),
  (xmrStagenet, makSubaddress, "7A1Hr63MfgUa8pkWxueD5xBqhQczkusYiCMYMnJGcGmuQxa7aDBxN1G7iCuLCNB3VPeb2TW7U9FdxB27xKkWKfJ8VhUZthF"),
  # validate_address.py check_openalias_addresses: donate@getmonero.org's mainnet subaddress
  (xmrMainnet, makSubaddress, "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"),
  # tests/functional_tests/wallet.py: the velvet-lymph wallet's subaddress (0,1)
  (xmrMainnet, makSubaddress, "84QRUYawRNrU3NN1VpFRndSukeyEb3Xpv8qZjjsoJZnTYpDYceuUTpog13D7qPxpviS7J29bSgSkR11hFFoXWk2yNdsR9WF"),
  # tests/unit_tests/base58.cpp test_keys_addr_str
  (xmrMainnet, makStandard, "4AzKEX4gXdJdNeM6dfiBFL7kqund3HYGvMBF3ttsNd9SfzgYB6L7ep1Yg1osYJzLdaKAYSLVh6e6jKnAuzj3bw1oGy9kXCb"),
  # tests/unit_tests/uri.cpp TEST_ADDRESS / TEST_INTEGRATED_ADDRESS (a TESTNET wallet2)
  (xmrTestnet, makStandard, "9tTLtauaEKSj7xoVXytVH32R1pLZBk4VV4mZFGEh4wkXhDWqw1soPyf3fGixf1kni31VznEZkWNEza9d5TvjWwq5PaohYHC"),
  (xmrTestnet, makIntegrated, "A4A1uPj4qaxj7xoVXytVH32R1pLZBk4VV4mZFGEh4wkXhDWqw1soPyf3fGixf1kni31VznEZkWNEza9d5TvjWwq5acaPMJfMbn3ReTsBpp"),
  # tests/functional_tests/integrated_address.py
  (xmrMainnet, makIntegrated, "4CMe2PUhs4J4886T7196doS9GPMzexD9gXpsZJDwVjeRVdFCSoHnv7KPbBeGpzJBzHRCAs9UxqeoyFQMYbqSWYTfSbLRB61BQVATzerHGj"),
  (xmrMainnet, makStandard, "46r4nYSevkfBUMhuykdK3gQ98XDqDTYW1hNLaXNvjpsJaSbNtdXh1sKMsdVgqkaihChAzEy29zEDPMR3NHQvGoZCLGwTerK"),
  (xmrMainnet, makIntegrated, "4GYjoMG9Y2BBUMhuykdK3gQ98XDqDTYW1hNLaXNvjpsJaSbNtdXh1sKMsdVgqkaihChAzEy29zEDPMR3NHQvGoZCVSs1ZojwrDCGS5rUuo")]

block everyNetworkEveryKind:
  var seen: set[MoneroNetwork]
  var kinds: array[MoneroNetwork, set[MoneroAddressKind]]
  for (net, kind, s) in goodAddresses:
    let a = parseAddress(s)
    doAssert a.ok, s & ": " & $a.refusal & " " & a.reason
    doAssert a.network == net and a.kind == kind, s & ": " & $a.network & "/" & $a.kind
    doAssert a.paymentId.isSome == (kind == makIntegrated), s
    # the encoder is the parser's inverse: the same fields give the same string back
    doAssert encodeAddress(a.network, a.kind, a.spendKey, a.viewKey, a.paymentId) == s, s
    # a standard address is 95 characters, an integrated one 106 (block-wise base58 of
    # 1 + 64 + 4 and 1 + 72 + 4 bytes)
    doAssert s.len == (if kind == makIntegrated: 106 else: 95), s
    seen.incl net
    kinds[net].incl kind
  for n in MoneroNetwork:
    doAssert kinds[n] == {makStandard, makSubaddress, makIntegrated}, "every kind on " & $n

block keysAndPaymentIds:
  # tests/functional_tests/wallet.py check_keys: the velvet-lymph wallet's public keys.
  let velvet = parseAddress(goodAddresses[0][2])
  doAssert hexOf(velvet.spendKey) == "1b3bd040020d3712ab84992b773d0a965134eb2df0392fb84af95de8a17be2ab"
  doAssert hexOf(velvet.viewKey) == "231c9bf8341c6a870d92e3fb98063a90a355fb8dbf74a8561b9d7f9273247e99"
  # integrated_address.py: make_integrated_address(payment_id = '0123456789abcdef') of the
  # same wallet; split_integrated_address gives the standard address back.
  let i1 = parseAddress("4CMe2PUhs4J4886T7196doS9GPMzexD9gXpsZJDwVjeRVdFCSoHnv7KPbBeGpzJBzHRCAs9UxqeoyFQMYbqSWYTfSbLRB61BQVATzerHGj")
  doAssert hexOf(i1.paymentId.get) == "0123456789abcdef"
  doAssert i1.spendKey == velvet.spendKey and i1.viewKey == velvet.viewKey
  doAssert standardOf(i1) == goodAddresses[0][2]
  let i2 = parseAddress("4GYjoMG9Y2BBUMhuykdK3gQ98XDqDTYW1hNLaXNvjpsJaSbNtdXh1sKMsdVgqkaihChAzEy29zEDPMR3NHQvGoZCVSs1ZojwrDCGS5rUuo")
  doAssert hexOf(i2.paymentId.get) == "1122334455667788"
  doAssert standardOf(i2) == "46r4nYSevkfBUMhuykdK3gQ98XDqDTYW1hNLaXNvjpsJaSbNtdXh1sKMsdVgqkaihChAzEy29zEDPMR3NHQvGoZCLGwTerK"
  # uri.cpp: "included payment id: <f612cac0b6cb1cda>"
  let i3 = parseAddress("A4A1uPj4qaxj7xoVXytVH32R1pLZBk4VV4mZFGEh4wkXhDWqw1soPyf3fGixf1kni31VznEZkWNEza9d5TvjWwq5acaPMJfMbn3ReTsBpp")
  doAssert hexOf(i3.paymentId.get) == "f612cac0b6cb1cda"
  doAssert standardOf(i3) == "9tTLtauaEKSj7xoVXytVH32R1pLZBk4VV4mZFGEh4wkXhDWqw1soPyf3fGixf1kni31VznEZkWNEza9d5TvjWwq5PaohYHC"
  # base58.cpp test_serialized_keys: spend key ‖ view key of 4AzKEX4g…
  let b = parseAddress("4AzKEX4gXdJdNeM6dfiBFL7kqund3HYGvMBF3ttsNd9SfzgYB6L7ep1Yg1osYJzLdaKAYSLVh6e6jKnAuzj3bw1oGy9kXCb")
  doAssert hexOf(b.spendKey) == "f724bc5c6cfbb9d97602c300423a2f28641874513a035778a0c1778d833201e9"
  doAssert hexOf(b.viewKey) == "220939689edf1abd5bc1d031f73ecd6c993add66d6808870456afeb8e7eeb68d"

block tags:
  # src/cryptonote_config.h: CRYPTONOTE_PUBLIC_{ADDRESS,INTEGRATED_ADDRESS,SUBADDRESS}_BASE58_PREFIX
  doAssert tagOf(xmrMainnet, makStandard) == 18 and tagOf(xmrMainnet, makIntegrated) == 19 and
           tagOf(xmrMainnet, makSubaddress) == 42
  doAssert tagOf(xmrTestnet, makStandard) == 53 and tagOf(xmrTestnet, makIntegrated) == 54 and
           tagOf(xmrTestnet, makSubaddress) == 63
  doAssert tagOf(xmrStagenet, makStandard) == 24 and tagOf(xmrStagenet, makIntegrated) == 25 and
           tagOf(xmrStagenet, makSubaddress) == 36
  # base58.cpp fails_on_invalid_address_prefix: good keys under tag 0 name no network
  let keys = hx("f724bc5c6cfbb9d97602c300423a2f28641874513a035778a0c1778d833201e9" &
                "220939689edf1abd5bc1d031f73ecd6c993add66d6808870456afeb8e7eeb68d")
  let a0 = parseAddress(encodeAddr(0, keys))
  doAssert not a0.ok and a0.refusal == mrUnknownTag, $a0.refusal
  # fails_on_invalid_address_content: 63 bytes under the standard tag — checksum good,
  # the keys do not parse
  let a63 = parseAddress(encodeAddr(18, keys[1 .. ^1]))
  doAssert not a63.ok and a63.refusal == mrBadLength, $a63.refusal
  # and one byte too many (parse_binary insists on the stream's end)
  let a65 = parseAddress(encodeAddr(18, keys & @[0'u8]))
  doAssert not a65.ok and a65.refusal == mrBadLength, $a65.refusal
  # an integrated tag over 64 bytes (no payment id) is short
  let ai = parseAddress(encodeAddr(19, keys))
  doAssert not ai.ok and ai.refusal == mrBadLength, $ai.refusal

# ── 3. The checksum is pre-NIST Keccak-256 ─────────────────────────────────────
block keccakIsCnFastHash:
  # Keccak-256("") — SHA3-256("") would be a7ffc6f8…; every checksum above passing is
  # the stronger evidence, since a SHA3 checksum would fail all of them.
  doAssert toHex(keccak256(newSeq[byte]())) ==
    "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

# ── 4. Key validity (check_address: not the identity, in the prime-order subgroup) ──
block keyValidity:
  let spend = key32("f724bc5c6cfbb9d97602c300423a2f28641874513a035778a0c1778d833201e9")
  let view = key32("220939689edf1abd5bc1d031f73ecd6c993add66d6808870456afeb8e7eeb68d")
  doAssert isValidKey(spend) and isValidKey(view)
  proc refusedWith(s, v: array[32, byte]): MoneroRefusal =
    let a = parseAddress(encodeAddress(xmrMainnet, makStandard, s, v))
    doAssert not a.ok
    a.refusal
  # base58.cpp fails_on_invalid_address_spend_key: the spend key's first byte zeroed
  var s0 = spend
  s0[0] = 0
  doAssert refusedWith(s0, view) == mrBadKey
  # fails_on_invalid_address_view_key: the view key's last byte set to 0x01
  var v1 = view
  v1[31] = 0x01
  doAssert refusedWith(spend, v1) == mrBadKey
  # the identity (y = 1): a point, refused by name in check_address
  var ident: array[32, byte]
  ident[0] = 1
  doAssert not isValidKey(ident)
  doAssert refusedWith(ident, view) == mrBadKey
  # y = −1 (order 2): decompresses, and l·P ≠ identity
  var ord2 = key32("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
  doAssert not isValidKey(ord2)
  # y = p, a non-canonical encoding of y = 0 (fe_frombytes_vartime refuses y ≥ p)
  var nonCanon = key32("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
  doAssert not isValidKey(nonCanon)
  # x = 0 with the sign bit set (the identity's "negative zero")
  var negZero = ident
  negZero[31] = 0x80
  doAssert not isValidKey(negZero)
  # P + T, T = (0, −1) of order 2: (x, y) + (0, −1) = (−x, −y). On the curve, so it
  # decompresses, but outside the prime-order subgroup: only the l·P check refuses it.
  let p = UInt256.fromHex("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed")
  var yb = spend
  let sign = yb[31] and 0x80
  yb[31] = yb[31] and 0x7f
  let y = UInt256.fromBytesLE(yb)
  let negY = p - y
  var mixed: array[32, byte]
  let nb = negY.toBytesLE()
  for i in 0 ..< 32: mixed[i] = nb[i]
  mixed[31] = mixed[31] or (sign xor 0x80)   # −x flips the sign of x (x ≠ 0 here)
  doAssert decompresses(mixed), "P + T is on the curve"
  doAssert not isValidKey(mixed), "P + T is not in the prime-order subgroup"
  doAssert refusedWith(spend, mixed) == mrBadKey
  # every real address's keys pass (section 2 parsed them all)

# ── 5. CAIP-2: monero:<first 32 hex characters of the genesis block hash> ───────
proc varint(v: uint64): seq[byte] =
  var x = v
  while x >= 0x80:
    result.add byte((x and 0x7f) or 0x80)
    x = x shr 7
  result.add byte(x)

proc genesisHash(genesisTx: string, nonce: uint32): string =
  ## cryptonote_tx_utils.cpp generate_genesis_block: header (major 1, minor 0, timestamp
  ## 0, prev_id 0, nonce) + the coinbase GENESIS_TX. get_block_hashing_blob = header ‖
  ## tree hash (one tx: its v1 hash, Keccak of its blob) ‖ varint(tx count + 1);
  ## calculate_block_hash = get_object_hash(blob) = Keccak(varint(len) ‖ blob).
  let txHash = keccak256(hx(genesisTx))
  var blob = varint(1) & varint(0) & varint(0) & newSeq[byte](32)
  for i in 0 ..< 4: blob.add byte((nonce shr (8 * i)) and 0xff)
  blob.add @txHash
  blob.add varint(1)
  toHex(keccak256(varint(uint64(blob.len)) & blob))

block caip2:
  # src/cryptonote_config.h: GENESIS_TX and GENESIS_NONCE per network.
  const mainTx = "013c01ff0001ffffffffffff03029b2e4c0281c0b02e7c53291a94d1d0cbff8883f8024f5142ee494ffbbd08807121017767aafcde9be00dcfd098715ebcf7f410daebc582fda69d24a28e9d0bc890d1"
  const stageTx = "013c01ff0001ffffffffffff0302df5d56da0c7d643ddd1ce61901c7bdc5fb1738bfe39fbe69c28a3a7032729c0f2101168d0c4ca86fb55a4cf6a36d31431be1c53a3bd7411bb24e8832410289fa6f3b"
  let gMain = genesisHash(mainTx, 10000)
  doAssert gMain == "418015bb9ae982a1975da7d79277c2705727a56894ba0fb246adaabb1f4632e3", gMain
  let gTest = genesisHash(mainTx, 10001)
  let gStage = genesisHash(stageTx, 10002)
  # ADR-018: read from the platform's default nodes (get_block_header_by_height 0) on
  # 2026-10-08; recomputed here from the source's own constants.
  doAssert caip2Of(xmrMainnet) == "monero:418015bb9ae982a1975da7d79277c270"
  doAssert caip2Of(xmrStagenet) == "monero:76ee3cc98646292206cd3e86f74d88b4"
  doAssert caip2Of(xmrTestnet) == "monero:48ca7cd3c8de5b6a4d53d2861fbdaedc"
  doAssert caip2Of(xmrMainnet) == "monero:" & gMain[0 ..< 32]
  doAssert caip2Of(xmrTestnet) == "monero:" & gTest[0 ..< 32], gTest
  doAssert caip2Of(xmrStagenet) == "monero:" & gStage[0 ..< 32], gStage
  for n in MoneroNetwork:
    doAssert networkOfChain(caip2Of(n)) == some(n)
  for bad in ["", "monero:", "monero:418015bb9ae982a1975da7d79277c27",
              "monero:418015bb9ae982a1975da7d79277c2705", "monero:418015BB9AE982A1975DA7D79277C270",
              "MONERO:418015bb9ae982a1975da7d79277c270", "bip122:000000000019d6689c085ae165831e93",
              "monero:mainnet", " monero:418015bb9ae982a1975da7d79277c270"]:
    doAssert networkOfChain(bad).isNone, bad

# ── 6. acceptablePayTo(addr, chain) ────────────────────────────────────────────
block payTo:
  let stage = caip2Of(xmrStagenet)
  let main = caip2Of(xmrMainnet)
  let stdS = "53teqCAESLxeJ1REzGMAat1ZeHvuajvDiXqboEocPaDRRmqWoVPzy46GLo866qRFjbNhfkNckyhST3WEvBviDwpUDd7DSzB"
  let subS = "73LhUiix4DVFMcKhsPRG51QmCsv8dYYbL6GcQoLwEEFvPvkVvc7BhebfA4pnEFF9Lq66hwvLqBvpHjTcqvpJMHmmNjPPBqa"
  let intS = "5K8mwfjumVseCcQEjNbf59Um6R9NfVUNkHTLhhPCmNvgDLVS88YW5tScnm83rw9mfgYtchtDDTW5jEfMhygi27j1QYphX38hg6m4VMtN29"
  let subM = "8AsN91rznfkBGTY8psSNkJBg9SZgxxGGRUhGwRptBhgr5XSQ1XzmA9m8QAnoxydecSh5aLJXdrgXwTDMMZ1AuXsN1EX5Mtm"
  let stdM = "42ey1afDFnn4886T7196doS9GPMzexD9gXpsZJDwVjeRVdFCSoHnv7KPbBeGpzJBzHRCAs9UxqeoyFQMYbqSWYTfJJQAWDm"
  # the agreed chain's standard and subaddress kinds
  let a1 = acceptablePayTo(stdS, stage)
  doAssert a1.ok and a1.kind == makStandard and a1.network == xmrStagenet
  let a2 = acceptablePayTo(subS, stage)
  doAssert a2.ok and a2.kind == makSubaddress
  doAssert acceptablePayTo(subM, main).ok
  doAssert acceptablePayTo(stdM, main).ok
  # an integrated address: parsed, but ADR-018 carries no payment id
  let a3 = acceptablePayTo(intS, stage)
  doAssert not a3.ok and a3.refusal == mrIntegrated and a3.reason.len > 0
  doAssert a3.kind == makIntegrated   # it says what it read
  # the wrong network for the chain (invariant 2: the address's network is the chain's)
  let a4 = acceptablePayTo(stdS, main)
  doAssert not a4.ok and a4.refusal == mrWrongNetwork and a4.network == xmrStagenet
  doAssert not acceptablePayTo(subM, stage).ok
  doAssert acceptablePayTo(subM, caip2Of(xmrTestnet)).refusal == mrWrongNetwork
  # an unknown chain refuses even a good address
  doAssert acceptablePayTo(stdS, "bip122:000000000019d6689c085ae165831e93").refusal == mrUnknownChain
  doAssert acceptablePayTo(stdS, "monero:00000000000000000000000000000000").refusal == mrUnknownChain
  # validate_address.py check_bad_addresses: the last character changed (m → 9)
  let bad = "42ey1afDFnn4886T7196doS9GPMzexD9gXpsZJDwVjeRVdFCSoHnv7KPbBeGpzJBzHRCAs9UxqeoyFQMYbqSWYTfJJQAWD9"
  doAssert acceptablePayTo(bad, main).refusal == mrBadChecksum
  # one character in the middle changed (the 9th, D → E)
  var mid = stdM
  mid[8] = 'E'
  doAssert acceptablePayTo(mid, main).refusal == mrBadChecksum
  # case is part of the address: a case flip is a different (and here invalid) string
  var flip = stdM
  flip[8] = 'd'
  doAssert not acceptablePayTo(flip, main).ok
  doAssert acceptablePayTo(stdM.toLowerAscii(), main).refusal != mrNone
  # truncated: one character short, one block short, and the 4-character "42ey"
  doAssert not acceptablePayTo(stdM[0 ..< ^1], main).ok
  doAssert not acceptablePayTo(stdM[0 ..< ^11], main).ok
  doAssert acceptablePayTo("42ey", main).refusal == mrBadBase58
  # validate_address.py's other bad strings, and whitespace never trimmed
  for s in ["", "a", " ", "@", " " & stdM, stdM & " ", stdM & "\n"]:
    let r = acceptablePayTo(s, main)
    doAssert not r.ok and r.reason.len > 0, s.escape

# ── 7. Amounts: print_money and parse_amount (cryptonote_format_utils.cpp) ──────
block amounts:
  # insert_money_decimal_point: left-pad to 13 digits, a point 12 from the end; no
  # trailing zeros trimmed.
  doAssert formatXmr(0) == "0.000000000000"
  doAssert formatXmr(1) == "0.000000000001"
  doAssert formatXmr(1_000_000_000_000'u64) == "1.000000000000"
  doAssert formatXmr(1_500_000_000_000'u64) == "1.500000000000"
  doAssert formatXmr(123_456_789'u64) == "0.000123456789"
  doAssert formatXmr(high(uint64)) == "18446744.073709551615"
  doAssert parseXmr("1") == some(1_000_000_000_000'u64)
  doAssert parseXmr("1.") == some(1_000_000_000_000'u64)
  doAssert parseXmr(".5") == some(500_000_000_000'u64)
  doAssert parseXmr("0.000000000001") == some(1'u64)
  doAssert parseXmr("1.5000000000000000") == some(1_500_000_000_000'u64)  # extra zeros trimmed
  doAssert parseXmr(" 2.25\t") == some(2_250_000_000_000'u64)            # boost::trim
  doAssert parseXmr("18446744.073709551615") == some(high(uint64))
  for bad in ["", ".", "-1", "+1", "alphanumeric", "0.0000000000001", "1.2.3", "1e3",
              "18446744.073709551616", "99999999999999999999", "1 000", "0x10"]:
    doAssert parseXmr(bad).isNone, bad
  for v in [0'u64, 1, 999, 1_000_000_000_000'u64, 7_654_321_000_001'u64, high(uint64)]:
    doAssert parseXmr(formatXmr(v)) == some(v)

# ── 8. The payment URI (wallet2.cpp make_uri / parse_uri) ──────────────────────
block urlEncoding:
  # abstract_http_client.cpp conver_to_url_format: a byte is escaped as %XX (upper-case
  # hex) when ≤ 32, ≥ 123, or one of  " < > % \ ^ [ ] ` + $ , @ : ; ! # & =  — so '/'
  # and '?' pass unescaped, and every UTF-8 byte ≥ 0x80 is escaped.
  doAssert urlEncode("foo bar") == "foo%20bar"
  doAssert urlEncode("a/b?c") == "a/b?c"
  doAssert urlEncode("\"<>%\\^[]`+$,@:;!#&=") ==
    "%22%3C%3E%25%5C%5E%5B%5D%60%2B%24%2C%40%3A%3B%21%23%26%3D"
  doAssert urlEncode("{|}~\x7f") == "%7B%7C%7D%7E%7F"
  doAssert urlEncode("\t\x01") == "%09%01"
  doAssert urlEncode("café") == "caf%C3%A9"
  doAssert urlEncode("AZaz09-._'()*") == "AZaz09-._'()*"
  # convert_from_url_format: %XX decodes when both are hex digits, else stays literal
  doAssert urlDecode("foo%20bar") == "foo bar"
  doAssert urlDecode("foo%2x") == "foo%2x"
  doAssert urlDecode("foo%2") == "foo%2"
  doAssert urlDecode("foo%") == "foo%"
  doAssert urlDecode("foo%2020") == "foo 20"
  doAssert urlDecode("caf%c3%A9") == "café"

block makeUri:
  let stage = caip2Of(xmrStagenet)
  let sub = "73LhUiix4DVFMcKhsPRG51QmCsv8dYYbL6GcQoLwEEFvPvkVvc7BhebfA4pnEFF9Lq66hwvLqBvpHjTcqvpJMHmmNjPPBqa"
  # Derivation, following make_uri line by line:
  #   uri = "monero:" + address
  #   payment_id empty → no tx_payment_id
  #   amount 1_500_000_000_000 > 0 → "?tx_amount=" + print_money(…) = "1.500000000000"
  #   recipient_name "Alice & Bob" → "&recipient_name=" + "Alice%20%26%20Bob"
  #   tx_description "dinner: 50/50, café" → "&tx_description=" +
  #     "dinner%3A%2050/50%2C%20caf%C3%A9"   (':' ',' ' ' escaped, '/' not, é = C3 A9)
  #   The order is fixed: tx_amount, recipient_name, tx_description.
  let u = makePaymentUri(stage, sub, 1_500_000_000_000'u64,
                         description = "dinner: 50/50, café", recipientName = "Alice & Bob")
  doAssert u.ok, u.reason
  doAssert u.uri == "monero:" & sub &
    "?tx_amount=1.500000000000&recipient_name=Alice%20%26%20Bob" &
    "&tx_description=dinner%3A%2050/50%2C%20caf%C3%A9", u.uri
  # one atomic unit, no name, no description
  let u1 = makePaymentUri(stage, sub, 1)
  doAssert u1.ok and u1.uri == "monero:" & sub & "?tx_amount=0.000000000001", u1.uri
  # amount 0 is left out (make_uri: `if (amount > 0)`), so the first field takes the '?'
  let u0 = makePaymentUri(stage, sub, 0, description = "x")
  doAssert u0.ok and u0.uri == "monero:" & sub & "?tx_description=x", u0.uri
  doAssert makePaymentUri(stage, sub, 0).uri == "monero:" & sub
  # uri.cpp make_uri_encodes_equals (a TESTNET wallet, amount 0)
  const testAddr = "9tTLtauaEKSj7xoVXytVH32R1pLZBk4VV4mZFGEh4wkXhDWqw1soPyf3fGixf1kni31VznEZkWNEza9d5TvjWwq5PaohYHC"
  let ue = makePaymentUri(caip2Of(xmrTestnet), testAddr, 0, description = "key=value",
                          recipientName = "name=value")
  doAssert ue.ok and ue.uri == "monero:" & testAddr &
    "?recipient_name=name%3Dvalue&tx_description=key%3Dvalue", ue.uri
  # the atomic amount as the effect carries it: a decimal string
  doAssert makePaymentUri(stage, sub, "1500000000000").uri == u1.uri.replace("0.000000000001", "1.500000000000")
  for bad in ["", "-1", "1.5", "18446744073709551616", "0x10", " 1"]:
    let r = makePaymentUri(stage, sub, bad)
    doAssert not r.ok and r.refusal == mrBadAmount, bad
  # refusals: the payTo rules hold for the URI too
  doAssert makePaymentUri(caip2Of(xmrMainnet), sub, 1).refusal == mrWrongNetwork
  let intS = "5K8mwfjumVseCcQEjNbf59Um6R9NfVUNkHTLhhPCmNvgDLVS88YW5tScnm83rw9mfgYtchtDDTW5jEfMhygi27j1QYphX38hg6m4VMtN29"
  doAssert makePaymentUri(stage, intS, 1).refusal == mrIntegrated
  doAssert makePaymentUri(stage, sub[0 ..< ^1], 1).ok == false
  doAssert makePaymentUri("eip155:1", sub, 1).refusal == mrUnknownChain
  # what we build, wallet2's parser reads back
  let back = parsePaymentUri(u.uri, stage)
  doAssert back.ok and back.address == sub and back.amount == 1_500_000_000_000'u64
  doAssert back.description == "dinner: 50/50, café" and back.recipientName == "Alice & Bob"

block parseUri:
  # tests/unit_tests/uri.cpp, against a TESTNET wallet2.
  let tn = caip2Of(xmrTestnet)
  const A = "9tTLtauaEKSj7xoVXytVH32R1pLZBk4VV4mZFGEh4wkXhDWqw1soPyf3fGixf1kni31VznEZkWNEza9d5TvjWwq5PaohYHC"
  const I = "A4A1uPj4qaxj7xoVXytVH32R1pLZBk4VV4mZFGEh4wkXhDWqw1soPyf3fGixf1kni31VznEZkWNEza9d5TvjWwq5acaPMJfMbn3ReTsBpp"
  for (u, want) in [("", false), ("monero", false), ("http://foo", false), (" monero:", false),
                    ("monero:", false), ("monero:?", false), ("monero:44444", false),
                    ("monero:" & A, true), ("monero:" & I, true),
                    ("monero:" & A & "&amount=1", false), ("monero:" & A & "?amount", false),
                    ("monero:" & A & "?tx_amount=", false), ("monero:" & A & "?tx_amount=-1", false),
                    ("monero:" & A & "?tx_amount=alphanumeric", false),
                    ("monero:" & A & "?tx_amount=1&tx_amount=1", false),
                    ("monero:" & A & "?tx_payment_id=", false),
                    ("monero:" & A & "?tx_payment_id=1234567890", false),
                    ("monero:" & A & "?tx_payment_id=1234567890123456", false),
                    ("monero:" & I & "?tx_payment_id=1234567890123456", false),
                    ("monero:" & A & "?tx_description=", true), ("monero:" & A & "?recipient_name=", true)]:
    let r = parsePaymentUri(u, tn)
    doAssert r.ok == want, u & ": " & r.reason
  let g = parsePaymentUri("monero:" & A, tn)
  doAssert g.address == A and g.amount == 0 and g.paymentId == "" and g.description == "" and
           g.recipientName == "" and g.unknown.len == 0
  let u1 = parsePaymentUri("monero:" & A & "?unknown=1", tn)
  doAssert u1.ok and u1.unknown == @["unknown=1"]
  let u2 = parsePaymentUri("monero:" & A & "?tx_amount=1&unknown=1&tx_description=desc&foo=bar", tn)
  doAssert u2.ok and u2.unknown == @["unknown=1", "foo=bar"] and u2.amount == 1_000_000_000_000'u64
  doAssert u2.description == "desc"
  let lp = parsePaymentUri("monero:" & A & "?tx_payment_id=1234567890123456789012345678901234567890123456789012345678901234", tn)
  doAssert lp.ok and lp.address == A and lp.paymentId == "1234567890123456789012345678901234567890123456789012345678901234"
  doAssert parsePaymentUri("monero:" & A & "?tx_description=foo", tn).description == "foo"
  doAssert parsePaymentUri("monero:" & A & "?recipient_name=foo", tn).recipientName == "foo"
  for (enc, dec) in [("foo%20bar", "foo bar"), ("foo%2x", "foo%2x"), ("foo%2", "foo%2"),
                     ("foo%", "foo%"), ("foo%2020", "foo 20")]:
    doAssert parsePaymentUri("monero:" & A & "?tx_description=" & enc, tn).description == dec, enc
  # the network is bound: wallet2's parse_uri checks the address against its own nettype
  doAssert parsePaymentUri("monero:" & A, caip2Of(xmrMainnet)).refusal == mrWrongNetwork
  doAssert parsePaymentUri("monero:" & A, "bip122:000000000019d6689c085ae165831e93").refusal == mrUnknownChain

echo "monero_address_test OK"
