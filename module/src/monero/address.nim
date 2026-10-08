## Monero addresses, their networks as CAIP-2, and the `monero:` payment URI (exo-dcc.5,
## ADR-018). Pure: no keys, no network, no lp_*. Nothing here raises on user input; every
## refusal is a value with its reason.
##
## Every rule is read from monero-project/monero (24272e4, 2026-10-08):
##   - block-wise base58 (8-byte blocks → 11 characters, a short last block to
##     `encoded_block_sizes`): `src/common/base58.cpp` `encode` / `decode` / `encode_addr`
##     / `decode_addr`. Not Bitcoin's base58.
##   - an address is varint(tag) ‖ data ‖ the first 4 bytes of Keccak-256 (cn_fast_hash,
##     pre-NIST padding — muster's `hashing/keccak256`) over the tag and data.
##   - the tags per network and kind: `src/cryptonote_config.h`
##     `CRYPTONOTE_PUBLIC_{ADDRESS,INTEGRATED_ADDRESS,SUBADDRESS}_BASE58_PREFIX`.
##   - the data: the public spend key, then the public view key (32 bytes each); an
##     integrated address adds an 8-byte payment id. Nothing may follow
##     (`parse_binary` insists on the stream's end).
##   - each key a point in the prime-order subgroup, not the identity (`check_address`;
##     see `point.nim`).
##   - the URI: `src/wallet/wallet2.cpp` `make_uri` / `parse_uri_impl`; amounts by
##     `cryptonote_format_utils.cpp` `print_money` / `parse_amount`; text by
##     `contrib/epee/src/abstract_http_client.cpp` `conver_to_url_format` /
##     `convert_from_url_format`.
## The CAIP-2 references follow bip122: `monero:` + the first 32 hex characters of the
## network's genesis block hash (ADR-018; the test re-derives them from the source's
## genesis constants). Case is never normalised: an address is the exact string.
##
## This is Monero's own checksum over Monero's own encoding. It is not on muster's
## signing path; what muster signs commits to the chain id and the payTo string (inv 5).

import std/[options, strutils]
import ../hashing/keccak256
import ./point

export point.isValidKey, point.decompresses

type
  MoneroNetwork* = enum
    xmrMainnet = "mainnet", xmrTestnet = "testnet", xmrStagenet = "stagenet"
  MoneroAddressKind* = enum
    makStandard = "standard", makSubaddress = "subaddress", makIntegrated = "integrated"
  MoneroRefusal* = enum
    mrNone = "", mrBadBase58 = "bad-base58", mrBadLength = "bad-length",
    mrUnknownTag = "unknown-tag", mrBadChecksum = "bad-checksum", mrBadKey = "bad-key",
    mrUnknownChain = "unknown-chain", mrWrongNetwork = "wrong-network",
    mrIntegrated = "integrated-address", mrBadAmount = "bad-amount", mrBadUri = "bad-uri"
  MoneroAddress* = object
    ok*: bool
    refusal*: MoneroRefusal      ## mrNone when ok
    reason*: string              ## what a person reads when it is refused
    network*: MoneroNetwork      ## meaningful once the tag was read
    kind*: MoneroAddressKind
    spendKey*, viewKey*: array[32, byte]
    paymentId*: Option[array[8, byte]]   ## integrated addresses only
  DecodedAddr* = object
    refusal*: MoneroRefusal
    tag*: uint64
    data*: seq[byte]
  PaymentUri* = object
    ok*: bool
    refusal*: MoneroRefusal
    reason*, uri*: string
  ParsedUri* = object
    ok*: bool
    refusal*: MoneroRefusal
    reason*, address*, paymentId*, description*, recipientName*: string
    amount*: uint64              ## atomic units; 0 when the URI names none
    unknown*: seq[string]        ## parameters wallet2 does not know, verbatim

# ── base58, block-wise (src/common/base58.cpp) ──────────────────────────────────
const
  Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  EncodedBlockSizes = [0, 2, 3, 5, 6, 7, 9, 10, 11]
  FullBlockSize = 8
  FullEncodedBlockSize = 11
  ChecksumSize = 4

proc decodedBlockSize(n: int): int =
  for i, e in EncodedBlockSizes:
    if e == n: return i
  -1

proc digitOf(c: char): int = Alphabet.find(c)

proc encodeBlock(data: openArray[byte], res: var string, at: int) =
  var num = 0'u64
  for b in data: num = (num shl 8) or uint64(b)
  var i = at + EncodedBlockSizes[data.len] - 1
  while num > 0:
    res[i] = Alphabet[int(num mod 58)]
    num = num div 58
    dec i

proc decodeBlock(s: openArray[char], res: var seq[byte]): bool =
  let size = decodedBlockSize(s.len)
  if size <= 0: return false                       # no block has this length
  var num = 0'u64
  var order = 1'u64
  for i in countdown(s.high, 0):
    let digit = digitOf(s[i])
    if digit < 0: return false                     # not in the alphabet
    if digit != 0 and order > high(uint64) div uint64(digit): return false   # overflow
    let tmp = num + order * uint64(digit)
    if tmp < num: return false                     # overflow
    num = tmp
    if i > 0: order = order * 58                   # 58^10 < 2^64
  if size < FullBlockSize and (1'u64 shl (8 * size)) <= num: return false   # wider than the block
  for k in countdown(size - 1, 0):
    res.add byte((num shr (8 * k)) and 0xff)
  true

proc base58Encode*(data: openArray[byte]): string =
  if data.len == 0: return ""
  let full = data.len div FullBlockSize
  let last = data.len mod FullBlockSize
  result = repeat(Alphabet[0], full * FullEncodedBlockSize + EncodedBlockSizes[last])
  for i in 0 ..< full:
    encodeBlock(data.toOpenArray(i * FullBlockSize, i * FullBlockSize + FullBlockSize - 1),
                result, i * FullEncodedBlockSize)
  if last > 0:
    encodeBlock(data.toOpenArray(full * FullBlockSize, data.high), result,
                full * FullEncodedBlockSize)

proc base58Decode*(s: string): Option[seq[byte]] =
  if s.len == 0: return some(newSeq[byte]())
  let full = s.len div FullEncodedBlockSize
  let last = s.len mod FullEncodedBlockSize
  if decodedBlockSize(last) < 0: return none(seq[byte])
  var res: seq[byte]
  for i in 0 ..< full:
    if not decodeBlock(s.toOpenArray(i * FullEncodedBlockSize,
                                     i * FullEncodedBlockSize + FullEncodedBlockSize - 1), res):
      return none(seq[byte])
  if last > 0 and not decodeBlock(s.toOpenArray(full * FullEncodedBlockSize, s.high), res):
    return none(seq[byte])
  some(res)

# ── varint (src/common/varint.h) ────────────────────────────────────────────────
proc writeVarint(v: uint64): seq[byte] =
  var x = v
  while x >= 0x80:
    result.add byte((x and 0x7f) or 0x80)
    x = x shr 7
  result.add byte(x)

proc readVarint(data: openArray[byte], tag: var uint64): int =
  ## read_varint<64>: the bytes read, or < 0 on overflow (-1) or a redundant zero byte (-2).
  tag = 0
  var shift = 0
  for b in data:
    inc result
    if shift + 7 >= 64 and int(b) >= (1 shl (64 - shift)): return -1
    if b == 0 and shift != 0: return -2
    tag = tag or (uint64(b and 0x7f) shl shift)
    if (b and 0x80) == 0: return
    shift += 7

# ── encode_addr / decode_addr ──────────────────────────────────────────────────
proc checksum(body: openArray[byte]): array[ChecksumSize, byte] =
  let h = keccak256(body)
  for i in 0 ..< ChecksumSize: result[i] = h[i]

proc encodeAddr*(tag: uint64, data: openArray[byte]): string =
  var buf = writeVarint(tag)
  buf.add data
  buf.add checksum(buf)
  base58Encode(buf)

proc decodeAddr*(s: string): DecodedAddr =
  let dec = base58Decode(s)
  if dec.isNone: return DecodedAddr(refusal: mrBadBase58)
  let raw = dec.get
  if raw.len <= ChecksumSize: return DecodedAddr(refusal: mrBadLength)
  let body = raw[0 ..< raw.len - ChecksumSize]
  let want = checksum(body)
  for i in 0 ..< ChecksumSize:
    if raw[body.len + i] != want[i]: return DecodedAddr(refusal: mrBadChecksum)
  var tag: uint64
  let n = readVarint(body, tag)
  if n <= 0: return DecodedAddr(refusal: mrUnknownTag)
  DecodedAddr(refusal: mrNone, tag: tag, data: body[n .. ^1])

# ── networks and kinds (src/cryptonote_config.h) ────────────────────────────────
const Tags: array[MoneroNetwork, array[MoneroAddressKind, uint64]] = [
  xmrMainnet: [makStandard: 18'u64, makSubaddress: 42'u64, makIntegrated: 19'u64],
  xmrTestnet: [makStandard: 53'u64, makSubaddress: 63'u64, makIntegrated: 54'u64],
  xmrStagenet: [makStandard: 24'u64, makSubaddress: 36'u64, makIntegrated: 25'u64]]

const Caip2: array[MoneroNetwork, string] = [
  xmrMainnet: "monero:418015bb9ae982a1975da7d79277c270",
  xmrTestnet: "monero:48ca7cd3c8de5b6a4d53d2861fbdaedc",
  xmrStagenet: "monero:76ee3cc98646292206cd3e86f74d88b4"]

proc tagOf*(n: MoneroNetwork, k: MoneroAddressKind): uint64 = Tags[n][k]

proc caip2Of*(n: MoneroNetwork): string = Caip2[n]

proc networkOfChain*(chain: string): Option[MoneroNetwork] =
  ## Exact match only: a CAIP-2 id is compared as the string ADR-018 fixes.
  for n in MoneroNetwork:
    if Caip2[n] == chain: return some(n)
  none(MoneroNetwork)

# ── addresses ───────────────────────────────────────────────────────────────────
proc refused(r: MoneroRefusal, reason: string): MoneroAddress =
  MoneroAddress(ok: false, refusal: r, reason: reason)

proc parseAddress*(s: string): MoneroAddress =
  ## get_account_address_from_str, on whichever network the tag names.
  let d = decodeAddr(s)
  case d.refusal
  of mrNone: discard
  of mrBadBase58: return refused(mrBadBase58, "not a Monero address: not Monero base58")
  of mrBadLength: return refused(mrBadLength, "not a Monero address: too short")
  of mrBadChecksum:
    return refused(mrBadChecksum, "not a Monero address: the checksum does not match (a mistyped character?)")
  else: return refused(mrUnknownTag, "not a Monero address: a malformed prefix")
  var found = false
  for n in MoneroNetwork:
    for k in MoneroAddressKind:
      if Tags[n][k] == d.tag:
        result.network = n
        result.kind = k
        found = true
  if not found:
    return refused(mrUnknownTag, "not a Monero address: prefix " & $d.tag &
                   " names no Monero network")
  let want = if result.kind == makIntegrated: 72 else: 64
  if d.data.len != want:
    result.refusal = mrBadLength
    result.reason = "not a Monero address: " & $d.data.len & " bytes of keys where " &
                    $want & " belong"
    return
  for i in 0 ..< 32:
    result.spendKey[i] = d.data[i]
    result.viewKey[i] = d.data[32 + i]
  if result.kind == makIntegrated:
    var pid: array[8, byte]
    for i in 0 ..< 8: pid[i] = d.data[64 + i]
    result.paymentId = some(pid)
  if not isValidKey(result.spendKey) or not isValidKey(result.viewKey):
    result.refusal = mrBadKey
    result.reason = "not a Monero address: its keys are not valid public keys"
    return
  result.ok = true

proc encodeAddress*(n: MoneroNetwork, k: MoneroAddressKind, spendKey, viewKey: array[32, byte],
                    paymentId = none(array[8, byte])): string =
  ## get_account_address_as_str / get_account_integrated_address_as_str. An integrated
  ## kind without a payment id, or another kind with one, encodes as given — the parser
  ## is what refuses it.
  var data = @spendKey & @viewKey
  if paymentId.isSome: data.add @(paymentId.get)
  encodeAddr(Tags[n][k], data)

proc standardOf*(a: MoneroAddress): string =
  ## The standard address an integrated (or any parsed) address pays: its keys under the
  ## standard tag (split_integrated_address). "" when the address did not parse.
  if not a.ok and a.refusal notin {mrIntegrated, mrWrongNetwork}: return ""
  encodeAddress(a.network, makStandard, a.spendKey, a.viewKey)

proc onChain(address, chain: string): MoneroAddress =
  ## the address, parsed and on the agreed chain's network (any kind)
  let n = networkOfChain(chain)
  if n.isNone:
    return refused(mrUnknownChain, "not a Monero chain muster knows: " & chain.escape)
  result = parseAddress(address)
  if not result.ok: return
  if result.network != n.get:
    result.ok = false
    result.refusal = mrWrongNetwork
    result.reason = "a " & $result.network & " address, but the agreed chain is " & $n.get

proc acceptablePayTo*(address, chain: string): MoneroAddress =
  ## A payTo muster agrees to (ADR-018): a standard address or subaddress on the agreed
  ## chain's network. The network is bound by the address itself (invariant 2,
  ## `implicit`). An integrated address is refused: ADR-018 uses no payment ids, and the
  ## platform's wallet backend does not forward them; a fresh subaddress replaces them.
  result = onChain(address, chain)
  if result.ok and result.kind == makIntegrated:
    result.ok = false
    result.refusal = mrIntegrated
    result.reason = "an integrated address carries a payment id; pay to a subaddress instead"

# ── amounts (cryptonote_format_utils.cpp, CRYPTONOTE_DISPLAY_DECIMAL_POINT = 12) ─
const DecimalPoint = 12

proc formatXmr*(atomic: uint64): string =
  ## print_money: the decimal digits, left-padded to 13, a point 12 from the end.
  result = $atomic
  if result.len < DecimalPoint + 1:
    result = repeat('0', DecimalPoint + 1 - result.len) & result
  result.insert(".", result.len - DecimalPoint)

proc parseDigits(s: string): Option[uint64] =
  ## get_xtype_from_string<uint64_t>: digits only, refused on overflow.
  if s.len == 0: return none(uint64)
  var v = 0'u64
  for c in s:
    if c notin {'0'..'9'}: return none(uint64)
    let d = uint64(ord(c) - ord('0'))
    if v > (high(uint64) - d) div 10: return none(uint64)
    v = v * 10 + d
  some(v)

proc parseXmr*(s: string): Option[uint64] =
  ## parse_amount: trim whitespace; at most 12 decimals once trailing zeros past the
  ## twelfth are dropped; the rest as an unsigned integer of atomic units.
  var str = s.strip(chars = {' ', '\t', '\n', '\v', '\f', '\r'})
  let point = str.find('.')
  var fraction = 0
  if point >= 0:
    fraction = str.len - point - 1
    while DecimalPoint < fraction and str[^1] == '0':
      str.setLen(str.len - 1)
      dec fraction
    if DecimalPoint < fraction: return none(uint64)
    str.delete(point .. point)
  if str.len == 0: return none(uint64)
  if fraction < DecimalPoint: str.add repeat('0', DecimalPoint - fraction)
  parseDigits(str)

# ── percent-encoding (contrib/epee/src/abstract_http_client.cpp) ─────────────────
const
  Unsafe = {'"', '<', '>', '%', '\\', '^', '[', ']', '`', '+', '$', ',', '@', ':', ';',
            '!', '#', '&', '='}   # get_unsave_chars; '/' and '?' are not in it
  UpperHex = "0123456789ABCDEF"

proc urlEncode*(s: string): string =
  ## conver_to_url_format: %XX (upper-case) for a byte ≤ 32, ≥ 123, or in the unsafe set.
  for c in s:
    if ord(c) <= 32 or ord(c) >= 123 or c in Unsafe:
      result.add '%'
      result.add UpperHex[ord(c) shr 4]
      result.add UpperHex[ord(c) and 0xf]
    else:
      result.add c

proc urlDecode*(s: string): string =
  ## convert_from_url_format: '%' and two hex digits (either case) is a byte; anything
  ## else, a malformed or truncated escape included, stays as written.
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      let hi = UpperHex.find(s[i + 1].toUpperAscii)
      let lo = UpperHex.find(s[i + 2].toUpperAscii)
      if hi >= 0 and lo >= 0: result.add char(hi * 16 + lo)
      else: result.add s[i .. i + 2]
      i += 3
    else:
      result.add s[i]
      inc i

# ── the payment URI (src/wallet/wallet2.cpp) ────────────────────────────────────
proc makePaymentUri*(chain, address: string, amount: uint64, description = "",
                     recipientName = ""): PaymentUri =
  ## make_uri, for a payTo muster accepts (acceptablePayTo): "monero:" + address, then
  ## the fields present in wallet2's order — tx_amount (decimal XMR, only when > 0),
  ## recipient_name, tx_description — the first after '?', the rest after '&'. No
  ## tx_payment_id: make_uri refuses a standalone one, and an integrated payTo is refused.
  let a = acceptablePayTo(address, chain)
  if not a.ok: return PaymentUri(refusal: a.refusal, reason: a.reason)
  var uri = "monero:" & address
  var fields = 0
  template field(name, value: string) =
    uri.add (if fields == 0: "?" else: "&")
    inc fields
    uri.add name & "=" & value
  if amount > 0: field("tx_amount", formatXmr(amount))
  if recipientName.len > 0: field("recipient_name", urlEncode(recipientName))
  if description.len > 0: field("tx_description", urlEncode(description))
  PaymentUri(ok: true, uri: uri)

proc makePaymentUri*(chain, address: string, amount: string, description = "",
                     recipientName = ""): PaymentUri =
  ## The same, for an amount as an effect carries it: atomic units as a decimal string.
  let v = parseDigits(amount)
  if v.isNone:
    return PaymentUri(refusal: mrBadAmount,
                      reason: "not an amount of atomic units: " & amount.escape)
  makePaymentUri(chain, address, v.get, description, recipientName)

proc isHex64(s: string): bool =
  ## parse_long_payment_id: 32 bytes as hex
  s.len == 64 and s.allCharsInSet(HexDigits)

proc parsePaymentUri*(uri, chain: string): ParsedUri =
  ## parse_uri_impl, against the network the chain names (wallet2 checks the address
  ## against its own nettype). It accepts what wallet2 accepts, integrated addresses and
  ## a 64-hex tx_payment_id included; whether to pay it is acceptablePayTo's question.
  proc bad(r: MoneroRefusal, reason: string): ParsedUri =
    ParsedUri(ok: false, refusal: r, reason: reason)
  if not uri.startsWith("monero:"):
    return bad(mrBadUri, "not a monero: URI")
  let rest = uri[7 .. ^1]
  let q = rest.find('?')
  let address = if q >= 0: rest[0 ..< q] else: rest
  let a = onChain(address, chain)
  if not a.ok: return bad(a.refusal, a.reason)
  result = ParsedUri(ok: true, address: address)
  if q < 0: return
  let body = rest[q + 1 .. ^1]
  if body.len == 0: return
  var seen: seq[string]
  for arg in body.split('&'):
    let kv = arg.split('=')
    if kv.len != 2: return bad(mrBadUri, "a parameter is not name=value: " & arg.escape)
    if kv[0] in seen: return bad(mrBadUri, "more than one " & kv[0])
    seen.add kv[0]
    case kv[0]
    of "tx_amount":
      let v = parseXmr(kv[1])
      if v.isNone: return bad(mrBadAmount, "not an amount: " & kv[1].escape)
      result.amount = v.get
    of "tx_payment_id":
      if a.kind == makIntegrated:
        return bad(mrBadUri, "a separate payment id with an integrated address")
      if not isHex64(kv[1]): return bad(mrBadUri, "not a payment id: " & kv[1].escape)
      result.paymentId = kv[1]
    of "recipient_name": result.recipientName = urlDecode(kv[1])
    of "tx_description": result.description = urlDecode(kv[1])
    else: result.unknown.add arg
