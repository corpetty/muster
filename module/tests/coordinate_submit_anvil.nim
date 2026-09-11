## Room-side submit, end to end against anvil: the owner signatures travel through the
## coordination LOG (propose + contribute events), the room folds to executable, and
## then — the coordinate_submit path — the signatures are gathered FROM the log,
## re-derived against the effect, assembled into a Safe execTransaction, and submitted
## on-chain. A successful execTransaction is itself the proof that the safeTxHash the
## room re-derived matches the contract's on-chain getTxHash (else checkSignatures
## reverts). This is the multi-party counterpart to safe_anvil_e2e: same on-chain
## assembly, but the signatures come from reduce(log), not local signing state.
## Usage: coordinate_submit_anvil <safeAddr> [rpcUrl]
import std/[os, algorithm, strutils, tables]
import ../src/drivers/safe
import ../src/drivers/safe_rpc
import ../src/crypto/secp256k1
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/coordination/intents
import ../src/drivers/driver as drivercore

proc hexToBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2..^1]
  for i in 0 ..< h.len div 2:
    result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc toAddr(s: string): Address =
  let b = hexToBytes(s); (for i in 0 ..< 20: result[i] = b[i])
proc toKey(s: string): array[32, byte] =
  let b = hexToBytes(s); (for i in 0 ..< 32: result[i] = b[i])
proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc toSig65(b: seq[byte]): Signature65 =
  for i in 0 ..< min(65, b.len): result[i] = b[i]
proc cmpSigner(a, b: (Address, Signature65)): int =
  for i in 0 ..< 20:
    if a[0][i] != b[0][i]: return (if a[0][i] < b[0][i]: -1 else: 1)
  0

let rpc = (if paramCount() >= 2: paramStr(2) else: "http://127.0.0.1:8545")
let safeAddr = toAddr(paramStr(1))
let k0 = toKey("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let k1 = toKey("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
let relayer = addressOf(k0)
let recipient = toAddr("0x00000000000000000000000000000000DeaDBeef")
let value = 1_000_000_000_000_000_000'u64          # 1 ETH

let drv = newSafeDriver(chainId = 31337, safe = safeAddr,
                        owners = @[addressOf(k0), addressOf(k1)], threshold = 2)
let foldDrv: DriverFor = proc(kind: string): drivercore.Driver = drv

# The effect, as the JSON a room proposes (coordinate_propose takes JSON). The
# re-derivation goes through effectFromJson, exactly as coordinate_submit does.
let effectJson = """{"to":"0x00000000000000000000000000000000DeaDBeef","value":""" &
                 $value & ""","nonce":0}"""
let mat = canonicalize(drv, effectFromJson(effectJson))
var hash: array[32, byte]
for i in 0 ..< 32: hash[i] = mat.bytes[i]

# 1. Build the ROOM LOG: a propose, then two owner signatures as contribute events —
#    the signatures carried as hex on the log, keyed by the recovered owner, exactly
#    as coordinate_contribute publishes them. The room folds this to executable.
let id = intentIdFor(effectJson)
let sig0 = toHex(signRecoverable(hash, k0))
let sig1 = toHex(signRecoverable(hash, k1))
var events = @[
  proposeEvent(id, effectJson),
  contributeEvent(id, contributorOf(drv, effectJson, sig0), sig0),
  contributeEvent(id, contributorOf(drv, effectJson, sig1), sig1)]
doAssert intentState(events, foldDrv, id) == "executable",
         "the room folds two owner signatures to executable"
echo "1. room log folds to executable (two owner sigs on the shared log) OK"

# 2. The coordinate_submit path: gather the owner signatures FROM the log (dedup by the
#    recovered signer), re-derive the hash, sort, assemble, submit — nothing read from
#    local signing state; the log is the source of truth.
var signed: seq[(Address, Signature65)]
var seenSigner: seq[string]
for e in events:
  let p = e.key.split('/')
  if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
    let s = toSig65(hexToBytes(e.value))
    if not recoversToOwner(hash, s, drv.owners): continue
    let signer = ecrecover(hash, s)
    let sk = toHex(signer)
    if sk in seenSigner: continue
    seenSigner.add sk
    signed.add (signer, s)
doAssert signed.len == 2, "two distinct owner signatures gathered from the log"
signed.sort(cmpSigner)
var sigbytes: seq[byte]
for (_, s) in signed: sigbytes.add @s
echo "2. gathered ", signed.len, " owner sigs FROM the log (not local state) OK"

# 3. Submit on-chain and observe finality from the receipt (R-8). A successful
#    execTransaction cross-validates the room's safeTxHash against the contract's.
let balBefore = parseHexInt(getBalance(rpc, recipient))
echo "recipient balance before: ", balBefore
let calldata = assembleExecTransaction(recipient, value, @[], sigbytes)
let txHash = submitExecTransaction(rpc, relayer, safeAddr, calldata)
echo "submitted execTransaction: ", txHash
var status = -1
for i in 0 .. 50:
  status = watchReceiptStatus(rpc, txHash)
  if status >= 0: break
  sleep(200)
doAssert status == 1, "room-side execTransaction did not succeed on-chain (status " & $status & ")"
let balAfter = parseHexInt(getBalance(rpc, recipient))
echo "recipient balance after:  ", balAfter
doAssert balAfter - balBefore == 1_000_000_000_000_000_000,
         "recipient did not receive 1 ETH (delta " & $(balAfter - balBefore) & ")"
echo "3. room-side execTransaction executed on-chain -> final, transfer landed OK"

# 4. exo-275 regression: a SECOND settle must commit to the Safe's NEW on-chain nonce
#    (now 1), read via safeNonce — NOT a hardcoded 0. A second proposal at nonce 0
#    re-derives a safeTxHash the contract's getTxHash (which uses the live nonce) no
#    longer matches, so checkSignatures reverts. This proves the room reads the live
#    nonce so sequential settles each land.
let n2 = safeNonce(rpc, safeAddr)
doAssert n2 == 1'u64, "Safe nonce advanced to 1 after the first settle (safeNonce got " & $n2 & ")"
let effectJson2 = """{"to":"0x00000000000000000000000000000000DeaDBeef","value":""" &
                  $value & ""","nonce":""" & $n2 & """}"""
let mat2 = canonicalize(drv, effectFromJson(effectJson2))
var hash2: array[32, byte]
for i in 0 ..< 32: hash2[i] = mat2.bytes[i]
let id2 = intentIdFor(effectJson2)
let s20 = toHex(signRecoverable(hash2, k0))
let s21 = toHex(signRecoverable(hash2, k1))
let events2 = @[
  proposeEvent(id2, effectJson2),
  contributeEvent(id2, contributorOf(drv, effectJson2, s20), s20),
  contributeEvent(id2, contributorOf(drv, effectJson2, s21), s21)]
doAssert intentState(events2, foldDrv, id2) == "executable", "second intent folds to executable"
var signed2: seq[(Address, Signature65)]
signed2.add (ecrecover(hash2, toSig65(hexToBytes(s20))), toSig65(hexToBytes(s20)))
signed2.add (ecrecover(hash2, toSig65(hexToBytes(s21))), toSig65(hexToBytes(s21)))
signed2.sort(cmpSigner)
var sigbytes2: seq[byte]
for (_, s) in signed2: sigbytes2.add @s
let bal2Before = parseHexInt(getBalance(rpc, recipient))
let calldata2 = assembleExecTransaction(recipient, value, @[], sigbytes2)
let txHash2 = submitExecTransaction(rpc, relayer, safeAddr, calldata2)
var status2 = -1
for i in 0 .. 50:
  status2 = watchReceiptStatus(rpc, txHash2)
  if status2 >= 0: break
  sleep(200)
doAssert status2 == 1,
  "SECOND room-side execTransaction failed (status " & $status2 & ") — the nonce-0 regression (exo-275)"
let bal2After = parseHexInt(getBalance(rpc, recipient))
doAssert bal2After - bal2Before == 1_000_000_000_000_000_000, "second transfer did not land"
echo "4. exo-275: second settle at live nonce ", n2, " (safeNonce) succeeded on-chain OK"

echo "coordinate_submit_anvil: room fold -> sigs from log -> on-chain final (x2, live nonce): all OK"
