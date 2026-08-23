## Chain-agnostic amount arithmetic — the part that must be right or a payment
## surface lies. Pure Nim, no external deps.

import ../src/wallet/types

# 1. Canonicalization and comparison.
doAssert normDec("007") == "7"
doAssert normDec("0") == "0"
doAssert cmpDec("10", "9") == 1, "length dominates lexicographic order"
doAssert cmpDec("9", "10") == -1
doAssert cmpDec("42", "42") == 0
echo "1. normalize + compare OK"

# 2. Add/sub across the uint64 boundary — the reason amounts are not a bare int.
#    2^64 = 18446744073709551616; token/wei balances routinely exceed it.
let big = "18446744073709551616"          # 2^64
doAssert addDec(big, "1") == "18446744073709551617"
doAssert subDec(addDec(big, big), big) == big, "(2^64 + 2^64) - 2^64 == 2^64"
doAssert addDec("999", "1") == "1000", "carry propagates"
doAssert subDec("1000", "1") == "999", "borrow propagates"
echo "2. arbitrary-precision add/sub OK"

# 3. Underflow is an error, never a wrap — there is no negative balance.
var underflowed = false
try: discard subDec("5", "6")
except WalletError: underflowed = true
doAssert underflowed, "subtracting more than you have is refused"
echo "3. underflow refused OK"

# 4. Display formatting with decimals, trimming trailing fractional zeros.
doAssert formatUnits("1500000000000000000", 18) == "1.5", "1.5 ETH"
doAssert formatUnits("1000000000000000000", 18) == "1", "whole number drops the point"
doAssert formatUnits("1", 18) == "0.000000000000000001", "1 wei"
doAssert formatUnits("1230000", 6) == "1.23", "6-decimal token"
doAssert formatUnits("42", 0) == "42", "zero-decimal asset"
echo "4. unit formatting OK"

# 5. Amount arithmetic guards the asset: you cannot add ETH to USDC.
let eth = AssetId(chain: "evm:1", symbol: "ETH", kind: akNative, decimals: 18)
let usdc = AssetId(chain: "evm:1", symbol: "USDC", kind: akToken, reference: "0xA0b8…", decimals: 6)
let a = amount(eth, "1000000000000000000")
let b = amount(eth, "500000000000000000")
doAssert add(a, b).display() == "1.5 ETH"
doAssert sub(a, b).display() == "0.5 ETH"
var mismatch = false
try: discard add(a, amount(usdc, "1"))
except WalletError: mismatch = true
doAssert mismatch, "adding different assets is refused"
echo "5. amount arithmetic guards the asset OK"

echo "wallet_types_test: all OK"
