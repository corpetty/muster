## Safe fidelity (exo-a50.1.4; docs/design/multisig-landscape.md §3, §8 Phase A).
##
## The Safe driver mapped only to / value / nonce: `data` was always empty and
## `operation` always CALL, so a proposal could not express — and a card could not
## show — what a Safe transaction actually does. Hiding `operation = delegatecall` is
## how the Bybit signers were led to approve code that took the Safe (Feb 2025). And it
## settled through a 4-argument fixture ABI the real Safe does not have. Held here:
##   1. a `safe-tx` effect carries EVERY SafeTx field into the signed hash — changing
##      data, operation, any gas field, the gas token or the refund receiver changes the
##      bytes an owner signs — while a plain transfer's hash is unchanged;
##   2. settlement speaks the real Safe ABI: execTransaction with all ten arguments
##      (selector 0x6a761202), every field encoded where the real Safe reads it;
##   3. delegatecall is surfaced and GATED: the manifest says it can write the Safe's
##      own storage; proposing or signing one is refused unless this client allowlists
##      the target (signRefusal), and a CALL is never refused;
##   4. the ways around the threshold are READ: a Safe's modules page and its guard
##      slot decode to the addresses that can act without the owners.
## The real-Safe anvil run (infra/anvil/devnet.sh deploys the v1.4.1 singleton) checks
## the same hash against the contract's own getTransactionHash: safe_real_anvil_e2e.nim.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/drivers/safe
import ../src/drivers/safe_rpc
import ../src/drivers/threshold
import ../src/coordination/intent_events
import ../src/crypto/secp256k1

proc addrOf(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

const SafeAddr = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
const Target = "0x1111111111111111111111111111111111111111"
const MultiSend = "0x40A2aCCbd92BCA938b02010E17A5b8929b49130D"
let drv = newSafeDriver(chainId = 31337, safe = addrOf(SafeAddr),
  owners = @[addrOf("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")], threshold = 1)

proc hashOf(j: JsonNode): seq[byte] = canonicalize(drv, effectFromJson($j)).bytes

# ── 1. every SafeTx field reaches the signed hash ─────────────────────────────
block:
  let transfer = %*{"to": Target, "value": 5, "nonce": 3}
  let base = %*{"effect": "safe-tx", "to": Target, "value": 5, "nonce": 3}
  doAssert effectFromJson($base).schemaId == "muster.effect.safe-tx.v1"
  doAssert effectSchema($base) == ("muster.effect.safe-tx.v1", true)
  doAssert hashOf(base) == hashOf(transfer),
    "a safe-tx with no data, CALL and zero gas fields is the same Safe transaction as the transfer"
  let tx = toSafeTx(effectFromJson($(%*{"effect": "safe-tx", "to": Target, "value": 5, "nonce": 3,
    "data": "0xa9059cbb", "operation": 1, "safeTxGas": 7, "baseGas": 8, "gasPrice": 9,
    "gasToken": MultiSend, "refundReceiver": Target})))
  doAssert tx.data == @[0xa9'u8, 0x05, 0x9c, 0xbb] and tx.operation == 1
  doAssert tx.safeTxGas == 7 and tx.baseGas == 8 and tx.gasPrice == 9
  doAssert tx.gasToken == addrOf(MultiSend) and tx.refundReceiver == addrOf(Target)
  var seen = @[hashOf(base)]
  for (k, v) in [("data", %"0xa9059cbb"), ("operation", %1), ("safeTxGas", %7), ("baseGas", %8),
                 ("gasPrice", %9), ("gasToken", %MultiSend), ("refundReceiver", %Target)]:
    var j = base.copy(); j[k] = v
    let h = hashOf(j)
    doAssert h notin seen, k & " must change the bytes an owner signs"
    seen.add h
  echo "1. every SafeTx field reaches the signed hash; a plain transfer is unchanged OK"

# ── 2. the real Safe ABI: execTransaction, ten arguments ───────────────────────
block:
  let tx = SafeTx(to: addrOf(Target), value: 5, data: @[0xde'u8, 0xad], operation: 1,
                  safeTxGas: 7, baseGas: 8, gasPrice: 9, gasToken: addrOf(MultiSend),
                  refundReceiver: addrOf(Target), nonce: 3)
  let sigs = newSeq[byte](65)
  let cd = assembleExecTransaction(tx, sigs)
  doAssert cd[0 .. 3] == @[0x6a'u8, 0x76, 0x12, 0x02], "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)"
  proc word(i: int): seq[byte] = cd[4 + 32*i ..< 4 + 32*(i+1)]
  proc num(i: int): int =
    for b in word(i)[24 .. 31]: result = (result shl 8) or int(b)
  doAssert word(0)[12 .. 31] == @(addrOf(Target))
  doAssert num(1) == 5 and num(3) == 1 and num(4) == 7 and num(5) == 8 and num(6) == 9
  doAssert word(7)[12 .. 31] == @(addrOf(MultiSend)) and word(8)[12 .. 31] == @(addrOf(Target))
  doAssert num(2) == 10 * 32, "data sits after the ten head words"
  doAssert num(10) == 2 and word(11)[0 .. 1] == @[0xde'u8, 0xad]
  doAssert num(9) == 10 * 32 + 64, "signatures follow data's length word and its padded bytes"
  doAssert num(12) == 65
  echo "2. settlement speaks the real Safe ABI (0x6a761202, all ten arguments) OK"

# ── 3. delegatecall is surfaced and gated ───────────────────────────────────────
block:
  let dc = effectFromJson($(%*{"effect": "safe-tx", "to": MultiSend, "value": 0, "nonce": 0,
                                "data": "0x8d80ff0a", "operation": 1}))
  let call = effectFromJson($(%*{"effect": "safe-tx", "to": Target, "value": 1, "nonce": 0,
                                  "data": "0xa9059cbb", "operation": 0}))
  let m = drv.manifest(dc)
  doAssert m.discloses.anyIt(it.field == "operation"), "the chain sees the operation"
  doAssert m.touches.anyIt(it.target.endsWith(":storage") and it.mode == tmWrite),
    "a delegatecall runs code AS the Safe: it can write the Safe's own storage (owners, modules)"
  doAssert not drv.manifest(call).touches.anyIt(it.target.endsWith(":storage")),
    "a plain call does not touch the Safe's own storage"
  doAssert consistencyFailures(m, dc).len == 0
  let refusal = drv.signRefusal(dc)
  doAssert refusal.len > 0 and MultiSend.toLowerAscii() in refusal.toLowerAscii(), refusal
  doAssert drv.signRefusal(call) == "", "a CALL is never refused"
  let allowing = newSafeDriver(chainId = 31337, safe = addrOf(SafeAddr), threshold = 1)
  allowing.delegatecallAllow = @[addrOf(MultiSend)]
  doAssert allowing.signRefusal(dc) == "", "an allowlisted delegatecall target may be signed"
  doAssert newThresholdDriver(@[], 1).signRefusal(dc) == "", "a driver that does not override it refuses nothing"
  echo "3. delegatecall is disclosed, touches the Safe's storage, and is refused unless allowlisted OK"

# ── 4. the ways around the threshold, read ──────────────────────────────────────
block:
  # getModulesPaginated returns (address[] array, address next): [offset][next][len][items…]
  let page = "0x" & "0000000000000000000000000000000000000000000000000000000000000040" &
             "0000000000000000000000000000000000000000000000000000000000000001" &
             "0000000000000000000000000000000000000000000000000000000000000002" &
             "000000000000000000000000" & "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" &
             "000000000000000000000000" & "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let mods = decodeModulesPage(page)
  doAssert mods.len == 2 and mods[0] == addrOf("0x" & repeat("aa", 20)) and mods[1] == addrOf("0x" & repeat("bb", 20))
  doAssert decodeModulesPage("0x" & "0000000000000000000000000000000000000000000000000000000000000040" &
    "0000000000000000000000000000000000000000000000000000000000000001" &
    "0000000000000000000000000000000000000000000000000000000000000000").len == 0
  doAssert guardFromSlot("0x000000000000000000000000" & repeat("cc", 20)) == "0x" & repeat("cc", 20)
  doAssert guardFromSlot("0x" & repeat("0", 64)) == "", "no guard set"
  doAssert GuardSlot == "0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8"
  echo "4. a Safe's modules page and guard slot decode to who can act without the owners OK"

echo "safe_fidelity_test: all OK"
