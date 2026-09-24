## The settlement seam (exo-a50.1.5; seam S6 of docs/design/multisig-landscape.md).
##
## A family is scheme × settlement. The DRIVER says what a contribution is and whether
## it counts; the SETTLEMENT turns an executable intent's contributions into a chain
## transaction and carries it through the ChainAdapter seam (wallet/adapter.nim):
##
##   assemble(driver, effect, contributions) → a PreparedTx, or a refusal naming why
##   submit(tx, keystore)                    → a TxRef, through the adapter
##   watch(txRef)                            → finality, through the adapter
##
## settlementFor picks one from the driver's family PROFILE — never from a policy
## string, never by branching on a concrete driver type in the core. A room family
## (settlement "none") or an undeclared / unsupported driver has NO settlement: nil,
## never a guess. The Safe settlement is the first tenant; Phase B's Bitcoin (PSBT)
## and Phase C's LEZ vote settlements slot in beside it.

import std/[json, algorithm]
import ../intents/materialization
import ../drivers/driver
import ../drivers/profile
import ../drivers/safe
import ../drivers/safe_rpc
import ../crypto/secp256k1
import ../crypto/keystore
import ../wallet/types
import ../wallet/adapter

type
  SettleContribution* = tuple[contributor: string, bytes: seq[byte]]
    ## a contribution from the log: who (as recorded) and the opaque bytes

  Assembled* = object
    ok*: bool
    error*: string        ## "insufficient-signatures" | "not-settleable" | …
    detail*: string
    have*, need*: int     ## contributions the driver accepted / the threshold
    tx*: PreparedTx

  Settlement* = ref object of RootObj
    family*: string       ## the registry family this settles
    adapter*: ChainAdapter
    relayer*: Account     ## who sends the settling transaction (pays its fee)

method assemble*(s: Settlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled {.base.} =
  Assembled(ok: false, error: "not-settleable", detail: "no settlement for " & s.family)

method submit*(s: Settlement, tx: PreparedTx, ks: Keystore): TxRef {.base.} =
  ## Through the adapter seam, from the relayer the settlement was configured with.
  s.adapter.submit(tx, ks)

method watch*(s: Settlement, txRef: TxRef): Finality {.base.} =
  s.adapter.finality(txRef)

# ── the Safe ─────────────────────────────────────────────────────────────────
type SafeSettlement* = ref object of Settlement

proc cmpAddress*(a, b: Address): int =
  ## ascending byte order — the order Safe.checkSignatures requires of its signers
  for i in 0 ..< 20:
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  0

proc hex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

method assemble*(s: SafeSettlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled =
  ## Re-derive the safeTxHash from the effect (never trusted from the log, invariant 1),
  ## keep each contribution only if it recovers to one of the Safe's owners (the
  ## driver's own rule), one per owner, ascending by owner (Safe.checkSignatures), and
  ## refuse below the threshold. The calldata is the real ten-argument execTransaction.
  if not (drv of SafeDriver):
    return Assembled(ok: false, error: "not-settleable", detail: "a Safe settlement needs a Safe driver")
  let sd = SafeDriver(drv)
  let mat = canonicalize(sd, effect)
  var hash: array[32, byte]
  for i in 0 ..< min(32, mat.bytes.len): hash[i] = mat.bytes[i]
  var signed: seq[(Address, Signature65)]
  var seen: seq[Address]
  for c in contributions:
    if c.bytes.len != 65: continue
    var sig: Signature65
    for i in 0 ..< 65: sig[i] = c.bytes[i]
    if not recoversToOwner(hash, sig, sd.owners): continue
    let who = ecrecover(hash, sig)
    if who in seen: continue
    seen.add who
    signed.add (who, sig)
  if signed.len < sd.threshold:
    return Assembled(ok: false, error: "insufficient-signatures", have: signed.len, need: sd.threshold,
                     detail: $signed.len & " of the " & $sd.threshold & " owner signatures the Safe needs")
  signed.sort(proc(a, b: (Address, Signature65)): int = cmpAddress(a[0], b[0]))
  var sigbytes: seq[byte]
  for (_, sig) in signed: sigbytes.add @sig
  let calldata = assembleExecTransaction(toSafeTx(effect), sigbytes)
  let safeHex = hex0x(sd.safe)
  Assembled(ok: true, have: signed.len, need: sd.threshold,
    tx: PreparedTx(chain: s.relayer.chain, frm: s.relayer, to: safeHex,
                   payload: $(%*{"to": safeHex, "data": hex0x(calldata), "gas": 400_000})))

proc settlementFor*(drv: Driver, adapter: ChainAdapter, relayer: Account): Settlement =
  ## The settlement a driver's family needs — read from its PROFILE. nil when the
  ## family settles nowhere (a room family) or the driver declares nothing (unsupported).
  let p = drv.profile()
  if not p.declared or p.settlement == "none": return nil
  case p.family
  of "evm.safe": SafeSettlement(family: p.family, adapter: adapter, relayer: relayer)
  else: nil
