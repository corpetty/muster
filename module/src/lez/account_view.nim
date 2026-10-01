## An account as a LEZ sequencer's getAccount reports it, for both lines muster speaks
## (exo-eb6.4 L3). Pure: JSON in, values out; the JSON-RPC client is
## wallet/lez_multisig_live.nim.
##
##   v0.2.4   {program_owner: [u32; 8], balance, data: [u8], nonce}
##   v0.3.0   {nonce, data: {shards: {<program account, base58>: [u8]}}}: an account is
##            its program shards (lee_core account::ProgramShardSelector); the native
##            balance is the 16-byte little-endian shard of the native token program,
##            account 0 ("1111…" in base58). No single owner, no single data.

import std/json
import stint
import ./tx

type
  LezAccountState* = object
    owner*: seq[byte]                 ## v0.2.4: the owning program ([] = none); v0.3: []
    balance*: UInt128                 ## the native balance
    data*: seq[byte]                  ## v0.2.4: the account's data; v0.3: []
    nonce*: UInt128
    shards*: seq[tuple[program, data: seq[byte]]]  ## v0.3: every program shard
    v3*: bool                         ## the zone answered in v0.3.0's shape: which line it runs

proc u128Of(n: JsonNode): UInt128 =
  case n.kind
  of JInt: n.getBiggestInt().stuint(128)
  of JString: parse(n.getStr(), UInt128)
  else: raise newException(ValueError, "not a u128: " & $n)

proc bytesOf(n: JsonNode): seq[byte] =
  for b in n.getElems(): result.add byte(b.getInt())

proc fresh*(a: LezAccountState): bool =
  ## Nothing on chain yet: no owner, no data, no shards, a zero nonce and balance.
  a.owner.len == 0 and a.data.len == 0 and a.shards.len == 0 and a.nonce.isZero and a.balance.isZero

proc accountStateOf*(j: JsonNode): LezAccountState =
  ## getAccount's result, either line; raises ValueError on a shape it does not know.
  if j.kind != JObject: raise newException(ValueError, "not an account: " & $j)
  result.nonce = u128Of(j["nonce"])
  let d = j{"data"}
  if d != nil and d.kind == JObject and d.hasKey("shards"):             # v0.3.0
    result.v3 = true
    for program, data in d["shards"].pairs:
      let p = accountIdFromBase58(program)
      let bytes = bytesOf(data)
      result.shards.add (program: p, data: bytes)
      if p == NativeTokenProgram and bytes.len > 0:
        if bytes.len != 16: raise newException(ValueError, "a native balance shard is 16 bytes")
        result.balance = UInt128.fromBytesLE(bytes)
    return
  var owner: seq[byte]                                                  # v0.2.4
  for w in j["program_owner"].getElems():
    let x = uint32(w.getBiggestInt())
    for i in 0 ..< 4: owner.add byte((x shr (8*i)) and 0xff)
  var any = false
  for b in owner: any = any or b != 0
  if any: result.owner = owner
  result.balance = u128Of(j["balance"])
  result.data = bytesOf(j["data"])
