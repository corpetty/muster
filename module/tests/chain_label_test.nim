## exo-e71 — a chain is named for the person reading, not by its CAIP-2 id.
##
## The cards and the split composer said "from their own wallet on
## bip122:0f9188f13cb7b2c71f2a335e3a4fc328" and "a contract on eip155:31337". One mapping,
## chainLabel, names a chain in copy ("Bitcoin regtest", "local chain 31337"); the id itself
## stays where a detail line shows it, and nothing signed or checked ever reads a label.
## Held here:
##   * chainLabel names the chains muster knows, and falls back to the id (an unknown
##     Ethereum chain by its number) — never an empty string;
##   * the Bitcoin names come from bitcoin/network's own table, not a second one;
##   * a card's "Where the rule lives" row names the chain by its label, for the split and
##     for a contract-locus family alike.

import std/[strutils, sequtils]
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/split
import ../src/bitcoin/network
import ../src/coordination/card_rows

const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"

# ── 1. the labels ─────────────────────────────────────────────────────────────
block:
  doAssert chainLabel("eip155:1") == "Ethereum"
  doAssert chainLabel("eip155:11155111") == "Sepolia"
  doAssert chainLabel("eip155:8453") == "Base"
  doAssert chainLabel("eip155:31337") == "local chain 31337"
  doAssert chainLabel("eip155:999") == "EVM chain 999", "an unknown Ethereum chain by its number"
  doAssert chainLabel(Regtest) == "Bitcoin regtest"
  doAssert chainLabel("bip122:000000000019d6689c085ae165831e93") == "Bitcoin"
  doAssert chainLabel("bip122:00000000da84f2bafbbc53dee25a72ae") == "Bitcoin testnet4"
  doAssert chainLabel("bip122:ffffffffffffffffffffffffffffffff") == "bip122:ffffffffffffffffffffffffffffffff",
           "an unknown Bitcoin network keeps its id"
  doAssert chainLabel("lez:testnet") == "LEZ testnet"
  doAssert chainLabel("lez:local") == "LEZ local"
  doAssert chainLabel("cosmos:cosmoshub-4") == "cosmos:cosmoshub-4"
  doAssert chainLabel("") == ""
  # one table: every Bitcoin network muster knows has a label of its own name
  for n in Networks:
    doAssert chainLabel(n.caip2) == (if n.name == "mainnet": "Bitcoin" else: "Bitcoin " & n.name), n.name
  echo "1. chainLabel names the chains muster knows and keeps the id for the rest OK"

# ── 2. the card's Where row reads the label ───────────────────────────────────
block:
  let roster = @[repeat("aa", 64), repeat("bb", 64)]
  let evm = newSplitDriver(EvmSplitFamily, "eip155:31337", roster).profile()
  let btc = newSplitDriver(BtcSplitFamily, Regtest, roster).profile()
  let evmWhere = cardRows(evm).filterIt(it.key == "where")[0].text
  let btcWhere = cardRows(btc).filterIt(it.key == "where")[0].text
  doAssert "own wallet on local chain 31337" in evmWhere and "eip155:" notin evmWhere, evmWhere
  doAssert "own wallet on Bitcoin regtest" in btcWhere and "bip122:" notin btcWhere, btcWhere
  var contract = evm
  contract.locus = loContract
  contract.chain = "eip155:8453"
  let cWhere = cardRows(contract).filterIt(it.key == "where")[0].text
  doAssert cWhere.startsWith("A contract on Base checks"), cWhere
  echo "2. the Where row names the chain by its label OK"

echo "chain_label_test: all OK"
