## Chain-agnostic wallet types (F-Design: settlement is chain-agnostic).
##
## These describe accounts, assets, amounts, fees, transfers and finality without
## assuming any one chain's model. An EVM address and a LEZ shielded key-set are
## both `Account`s; ETH-wei and a token's base units are both `Amount`s. The four
## divergence axes we refuse to collapse (mirroring the driver's, invariant 6):
## the ACCOUNT MODEL (public id vs shielded key-set), the ASSET model (native vs
## token), FINALITY latency (immediate vs minutes), and the FAILURE channel.
##
## Failure is a raised `WalletError`, never a sentinel value. This is deliberate:
## a chain that signals failure by returning an empty string or `success:false`
## (the LEZ convention) must be normalized so a failed read can NEVER be mistaken
## for a zero balance or a successful send — the one thing a payment surface must
## never get wrong. Adapters translate their quirks into a raise.
##
## Amounts are non-negative integers in base units, held as a canonical decimal
## string on the wire (JSON-friendly) with the arithmetic done in `stint`'s
## `UInt256` — the Status/Nimbus bignum, which is exactly the EVM 256-bit word, so
## real wei and token balances neither overflow uint64 nor need a hand-rolled
## bignum. We reuse it rather than reimplement it (org libraries first).

import stint

type
  WalletError* = object of CatchableError

  AssetKind* = enum
    akNative = "native"    ## the chain's native asset (ETH, LEZ)
    akToken = "token"      ## a token on the chain (ERC-20-style)

  AssetId* = object
    chain*: string         ## chain id, e.g. "evm:31337", "mock:shielded"
    symbol*: string        ## display symbol, e.g. "ETH", "USDC"
    kind*: AssetKind
    reference*: string     ## token contract / asset ref; "" for native
    decimals*: int         ## display decimals (18 for ETH, 6 for USDC…)

  Amount* = object
    asset*: AssetId
    raw*: string           ## non-negative integer, base units, canonical decimal

  AccountForm* = enum
    afPublic = "public"    ## a public, resolvable account id (EVM address, LEZ public id)
    afShielded = "shielded" ## a shielded key-set — receiving without a public address

  Account* = object
    chain*: string
    form*: AccountForm
    id*: string            ## opaque account handle (adapter-interpreted)

  FinalityModel* = enum
    finImmediate = "immediate"        ## e.g. a local devnet — final on inclusion
    finProbabilistic = "probabilistic" ## confirmations accrue (public EVM)
    finDelayed = "delayed"            ## settlement takes real time (LEZ proofs, minutes)

  ChainDescriptor* = object
    chain*: string
    displayName*: string
    nativeAsset*: AssetId
    accountForms*: seq[AccountForm]   ## the account models this chain offers
    finality*: FinalityModel

  FeeEstimate* = object
    fee*: Amount           ## what the transfer will cost, in some asset
    note*: string          ## human note, e.g. "gas 21000 @ 1 gwei"

  PreparedTx* = object
    chain*: string
    frm*: Account
    to*: string
    amount*: Amount
    fee*: FeeEstimate
    payload*: string       ## opaque adapter-built payload (calldata hex / json)

  TxRef* = object
    chain*: string
    id*: string            ## a handle for polling finality

  FinalityStatus* = enum
    fsPending = "pending"
    fsFinal = "final"
    fsFailed = "failed"

  Finality* = object
    status*: FinalityStatus
    detail*: string

# ── arbitrary-precision non-negative decimal arithmetic ────────────────────────
# Just what the wallet needs: validate, compare, add, subtract, and format base
# units for display. Non-negative only — balances and amounts never go below zero,
# and a subtraction that would (insufficient funds) is an error, not a wrap.

proc parseU(s: string): UInt256 =
  if s.len == 0: raise newException(WalletError, "empty amount")
  try: u256(s)                                   # decimal parse (stint)
  except CatchableError: raise newException(WalletError, "non-numeric amount: " & s)

proc normDec*(s: string): string =
  ## Canonical decimal form (validates + strips leading zeros) via stint.
  parseU(s).toString

proc cmpDec*(a, b: string): int =
  let x = parseU(a); let y = parseU(b)
  if x < y: -1 elif x == y: 0 else: 1

proc addDec*(a, b: string): string = (parseU(a) + parseU(b)).toString

proc subDec*(a, b: string): string =
  ## a - b; raises if b > a (there is no negative amount).
  let x = parseU(a); let y = parseU(b)
  if x < y: raise newException(WalletError, "amount underflow: " & b & " > " & a)
  (x - y).toString

proc formatUnits*(raw: string, decimals: int): string =
  ## Base units → a human decimal string (e.g. 1500000000000000000, 18 -> "1.5").
  ## Trailing fractional zeros are trimmed; an all-zero fraction drops the point.
  let n = normDec(raw)
  if decimals <= 0: return n
  var s = n
  while s.len <= decimals: s = "0" & s
  let whole = s[0 ..< s.len - decimals]
  var frac = s[s.len - decimals .. ^1]
  while frac.len > 0 and frac[^1] == '0': frac = frac[0 ..< frac.high]
  if frac.len == 0: whole else: whole & "." & frac

proc mulSmall*(a: string, m: int): string =
  ## Multiply a canonical decimal by a small non-negative factor (e.g. gas × price).
  (parseU(a) * u256(m)).toString

proc hexToDec*(hex: string): string =
  ## A hex quantity (with or without 0x) to a canonical decimal — how an EVM
  ## eth_getBalance / balanceOf result becomes an Amount without truncation.
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  if h.len == 0: return "0"
  try: fromHex(UInt256, h).toString
  except CatchableError: raise newException(WalletError, "bad hex quantity: " & hex)

proc decToHex*(dec: string): string =
  ## A canonical decimal to a minimal lowercase hex string (no 0x) — how an Amount
  ## becomes the 32-byte word in EVM calldata (padded by the caller).
  let x = parseU(dec)
  if x == u256(0): return "0"
  var s = x.toHex                      # stint hex; strip any leading zeros to minimal
  var i = 0
  while i < s.len - 1 and s[i] == '0': inc i
  s[i .. ^1]

# ── constructors / helpers ─────────────────────────────────────────────────────

proc amount*(asset: AssetId, raw: string): Amount = Amount(asset: asset, raw: normDec(raw))
proc zero*(asset: AssetId): Amount = Amount(asset: asset, raw: "0")

proc sameAsset*(a, b: AssetId): bool =
  a.chain == b.chain and a.symbol == b.symbol and a.kind == b.kind and a.reference == b.reference

proc add*(a, b: Amount): Amount =
  if not sameAsset(a.asset, b.asset): raise newException(WalletError, "asset mismatch in add")
  Amount(asset: a.asset, raw: addDec(a.raw, b.raw))

proc sub*(a, b: Amount): Amount =
  if not sameAsset(a.asset, b.asset): raise newException(WalletError, "asset mismatch in sub")
  Amount(asset: a.asset, raw: subDec(a.raw, b.raw))

proc display*(a: Amount): string =
  ## Human-readable, e.g. "1.5 ETH".
  formatUnits(a.raw, a.asset.decimals) & " " & a.asset.symbol
