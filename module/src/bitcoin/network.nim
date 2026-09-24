## Bitcoin networks (exo-a50.2.3): the bech32 human-readable part and the CAIP-2 chain id
## (bip122:<first 32 hex chars of the genesis block hash>) for each.

import std/strutils
import ./tx

type BtcNetwork* = object
  name*: string    ## mainnet · testnet · testnet4 · signet · regtest
  hrp*: string     ## bech32 prefix
  caip2*: string   ## "bip122:<genesis prefix>"

const Networks* = [
  BtcNetwork(name: "mainnet", hrp: "bc", caip2: "bip122:000000000019d6689c085ae165831e93"),
  BtcNetwork(name: "testnet", hrp: "tb", caip2: "bip122:000000000933ea01ad0ee984209779ba"),
  BtcNetwork(name: "testnet4", hrp: "tb", caip2: "bip122:00000000da84f2bafbbc53dee25a72ae"),
  BtcNetwork(name: "signet", hrp: "tb", caip2: "bip122:00000008819873e925422c1ff0f99f7c"),
  BtcNetwork(name: "regtest", hrp: "bcrt", caip2: "bip122:0f9188f13cb7b2c71f2a335e3a4fc328")]

proc networkByName*(name: string): BtcNetwork =
  for n in Networks:
    if n.name == name: return n
  raise newException(BtcError, "unknown Bitcoin network: " & name)

proc networkByCaip2*(chain: string): BtcNetwork =
  for n in Networks:
    if n.caip2 == chain: return n
  raise newException(BtcError, "not a known Bitcoin chain: " & chain)

proc hrpOfAddress*(address: string): string =
  ## the bech32 prefix an address claims (the part before its last '1')
  let i = address.toLowerAscii().rfind('1')
  if i < 1: raise newException(BtcError, "not a segwit address: " & address)
  address.toLowerAscii()[0 ..< i]
