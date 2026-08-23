## The EVM adapter's pure pieces — calldata assembly, hex<->decimal balance
## parsing, account derivation, the asset registry — checked without a node. The
## RPC methods (balance/estimateFee/submit/finality) need anvil and run in the
## integration path. Needs libsecp256k1 + libsodium (keystore identity).

import std/strutils
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/wallet/evm_adapter
import ../src/crypto/secp256k1
import ../src/crypto/keystore

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

proc addr20(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

# 1. hex<->decimal roundtrips across the uint64 boundary (a real wei balance).
doAssert hexToDec("0x0") == "0"
doAssert hexToDec("0xde0b6b3a7640000") == "1000000000000000000", "1 ETH in wei"
doAssert decToHex("1000000000000000000") == "de0b6b3a7640000"
let huge = "123456789012345678901234567890"
doAssert hexToDec("0x" & decToHex(huge)) == huge, "hex<->dec roundtrip beyond 64 bits"
echo "1. hex<->decimal balance parsing OK"

# 2. ERC-20 calldata: correct selectors and 32-byte-padded arguments.
let to = addr20("0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
let bal = erc20BalanceOfData(to)
doAssert bal.startsWith("0x70a08231"), "balanceOf selector"
doAssert bal.len == 10 + 64, "selector + one padded word"
doAssert bal.endsWith("70997970c51812dc3a010c7d01b50e0d17dc79c8"), "address right-aligned in the word"

let xfer = erc20TransferData(to, "1230000")           # 1.23 of a 6-dec token
doAssert xfer.startsWith("0xa9059cbb"), "transfer selector"
doAssert xfer.len == 10 + 64 + 64, "selector + address word + amount word"
doAssert xfer.endsWith(decToHex("1230000").align(64, '0')), "amount right-aligned in the word"
echo "2. ERC-20 calldata assembly OK"

# 3. Describe + account derivation + asset registry (no node needed).
let ks = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let usdc = AssetId(chain: "evm:31337", symbol: "USDC", kind: akToken,
                   reference: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6)
let evm = newEvmAdapter("evm:31337", "http://127.0.0.1:8545", tokens = @[usdc])
let d = evm.describe()
doAssert d.finality == finImmediate and d.accountForms == @[afPublic]
doAssert d.nativeAsset.symbol == "ETH" and d.nativeAsset.decimals == 18
let accs = evm.accounts(ks)
doAssert accs.len == 1 and accs[0].form == afPublic
doAssert accs[0].id == addrHex(ks.address()), "account is the keystore's address"
let assets = evm.assets()
doAssert assets.len == 2 and assets[1].symbol == "USDC", "native ETH + the registered token"
echo "3. describe + account + asset registry OK"

# 4. The adapter registers into the generic Wallet by its chain id.
let w = newWallet(ks)
w.register(evm)
doAssert w.chains().len == 1 and w.chains()[0].chain == "evm:31337"
doAssert w.accounts()[0].id == addrHex(ks.address())
echo "4. registers into the chain-agnostic Wallet OK"

echo "wallet_evm_test: all OK"
