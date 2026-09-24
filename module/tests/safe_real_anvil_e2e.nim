## The real Safe v1.4.1 on anvil (exo-a50.1.4): infra/anvil/devnet.sh deploys the
## singleton + factory + fallback handler and a 2-of-3 proxy. Against the CONTRACT:
##   1. muster's safeTxHash equals the Safe's own getTransactionHash for a transaction
##      that uses EVERY field — data, DELEGATECALL, the gas fields, a gas token and a
##      refund receiver — so what an owner signs in muster is exactly what the Safe checks;
##   2. the disclosure check reads the chain: getOwners + getThreshold agree with the
##      disclosed account (verified), and the ways around the threshold are READ: no
##      modules, no guard on a fresh Safe (known, not assumed);
##   3. a data-carrying CALL executes through the ten-argument execTransaction.
## Usage: safe_real_anvil_e2e <safeAddr> [rpcUrl]   (run devnet.sh first)
import std/[os, algorithm, strutils, sequtils]
import ../src/drivers/safe
import ../src/drivers/safe_rpc
import ../src/crypto/secp256k1
import ../src/intents/materialization
import ../src/coordination/intent_events
import ../src/coordination/accounts
import ../src/hashing/keccak256

proc hexToBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2..^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc toAddr(s: string): Address =
  let b = hexToBytes(s); (for i in 0 ..< 20: result[i] = b[i])
proc toKey(s: string): array[32, byte] =
  let b = hexToBytes(s); (for i in 0 ..< 32: result[i] = b[i])
proc hex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc w(x: uint64): seq[byte] = (result = newSeq[byte](32); for i in 0 ..< 8: result[31-i] = byte((x shr uint64(8*i)) and 0xFF))
proc wa(a: Address): seq[byte] = (result = newSeq[byte](32); for i in 0 ..< 20: result[12+i] = a[i])
proc pad(b: seq[byte]): seq[byte] = (result = b; while result.len mod 32 != 0: result.add 0'u8)
proc cmpSigner(a, b: (Address, Signature65)): int =
  for i in 0 ..< 20:
    if a[0][i] != b[0][i]: return (if a[0][i] < b[0][i]: -1 else: 1)
  0

let rpc = (if paramCount() >= 2: paramStr(2) else: "http://127.0.0.1:8545")
let safeHex = paramStr(1)
let safeAddr = toAddr(safeHex)
const Owners = ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"]
let drv = newSafeDriver(chainId = 31337, safe = safeAddr, owners = Owners.mapIt(toAddr(it)), threshold = 2)

# ── 1. every field: muster's hash == the Safe's getTransactionHash ──────────────
block:
  let nonce = safeNonce(rpc, safeAddr)
  let effectJson = """{"effect":"safe-tx","to":"0x40A2aCCbd92BCA938b02010E17A5b8929b49130D","value":7,""" &
    """"data":"0x8d80ff0a00ff","operation":1,"safeTxGas":11,"baseGas":22,"gasPrice":33,""" &
    """"gasToken":"0x1111111111111111111111111111111111111111",""" &
    """"refundReceiver":"0x2222222222222222222222222222222222222222","nonce":""" & $nonce & "}"
  let mine = canonicalize(drv, effectFromJson(effectJson)).bytes
  let tx = toSafeTx(effectFromJson(effectJson))
  let sel = keccak256(cast[seq[byte]]("getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)"))
  var cd = @[sel[0], sel[1], sel[2], sel[3]]
  cd.add wa(tx.to); cd.add w(tx.value); cd.add w(10 * 32); cd.add w(tx.operation.uint64)
  cd.add w(tx.safeTxGas); cd.add w(tx.baseGas); cd.add w(tx.gasPrice)
  cd.add wa(tx.gasToken); cd.add wa(tx.refundReceiver); cd.add w(tx.nonce)
  cd.add w(uint64(tx.data.len)); cd.add pad(tx.data)
  let theirs = hexToBytes(ethCall(rpc, safeAddr, cd))
  doAssert theirs == mine, "muster " & hex0x(mine) & " != Safe.getTransactionHash " & hex0x(theirs)
  doAssert drv.signRefusal(effectFromJson(effectJson)).len > 0, "and muster refuses to sign it (unallowlisted delegatecall)"
  echo "1. muster's safeTxHash == the real Safe's getTransactionHash, every field incl. DELEGATECALL OK"

# ── 2. the disclosure check and the ways around the rule, read from the contract ──
block:
  let o = getOwners(rpc, safeAddr)
  let t = getThreshold(rpc, safeAddr)
  doAssert o.known and t.known, o.detail & " / " & t.detail
  let acct = reduceAccounts(@[accountDiscloseEvent(RoomAccount(family: "evm.safe", chain: "eip155:31337",
    address: safeHex, signers: @Owners, threshold: 2), "tester")])[0]
  let view: ChainView = (known: true, signers: o.owners.mapIt(hex0x(it)), threshold: t.threshold, detail: "")
  doAssert checkAccount(acct, view).status == acVerified, checkAccount(acct, view).detail
  let wrong = reduceAccounts(@[accountDiscloseEvent(RoomAccount(family: "evm.safe", chain: "eip155:31337",
    address: safeHex, signers: @Owners[0 .. 1], threshold: 1), "liar")])[0]
  doAssert checkAccount(wrong, view).status == acDisagrees
  let m = getModules(rpc, safeAddr)
  let g = getGuard(rpc, safeAddr)
  doAssert m.known and m.modules.len == 0, "a fresh Safe has no modules: " & m.detail
  doAssert g.known and g.guard == "", "a fresh Safe has no guard: " & g.detail
  echo "2. owners + threshold read from the Safe verify the disclosure (a false one disagrees); no modules, no guard — read, not assumed OK"

# ── 3. a data-carrying CALL through the ten-argument execTransaction ───────────────
block:
  let nonce = safeNonce(rpc, safeAddr)
  let recipient = "0x00000000000000000000000000000000DeaDBeef"
  let effectJson = """{"effect":"safe-tx","to":"""" & recipient & """","value":1000,"data":"0xcafe","operation":0,"nonce":""" & $nonce & "}"
  let h = canonicalize(drv, effectFromJson(effectJson)).bytes
  var hash: array[32, byte]
  for i in 0 ..< 32: hash[i] = h[i]
  var signed: seq[(Address, Signature65)]
  for k in ["0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
            "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"]:
    let s = signRecoverable(hash, toKey(k))
    signed.add (ecrecover(hash, s), s)
  signed.sort(cmpSigner)
  var sigs: seq[byte]
  for (_, s) in signed: sigs.add @s
  let txh = submitExecTransaction(rpc, toAddr(Owners[0]), safeAddr, assembleExecTransaction(toSafeTx(effectFromJson(effectJson)), sigs))
  var status = -1
  for _ in 0 .. 25:
    status = watchReceiptStatus(rpc, txh)
    if status >= 0: break
    sleep(200)
  doAssert status == 1, "a data-carrying execTransaction must succeed on the real Safe (status " & $status & ")"
  doAssert safeNonce(rpc, safeAddr) == nonce + 1
  echo "3. a data-carrying CALL executed through the real ten-argument execTransaction OK"

echo "safe_real_anvil_e2e: muster ⇄ real Safe v1.4.1 — every field, the chain reads, the full ABI: all OK"
