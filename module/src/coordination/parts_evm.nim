## A part paid and read on an EVM chain (exo-a90.4; docs/design/split-the-bill.md §4.4–§4.5):
## the PartSeam a split's evm.split family settles through. The payer's own wallet (the EVM
## adapter, their key through the keystore, their RPC) sends; the creditor reads a reported
## transaction from THEIR OWN RPC — never a service's (invariant 8) — and it is graded for what
## it is: what that endpoint reported (F-10, attested). ETH, or an ERC-20 token named in the
## split (exo-5ab): a token share is a transfer() call on the token, read back from its
## Transfer log.

import std/strutils
import ../crypto/keystore
import ../intents/materialization   # PartTransfer
import ../wallet/[types, adapter, evm_adapter, evm_rpc, erc20_logs]
import ../drivers/split   # isErc20Asset
import ./parts

type EvmPartSeam* = ref object of PartSeam
  chain*: string            ## CAIP-2, "eip155:<id>"
  url*: string              ## this member's own RPC
  adapter*: EvmAdapter      ## this member's wallet on that chain
  ks*: Keystore
  frm*: Account             ## the account this member pays from
  spent: seq[string]        ## the last payment's nonce, "nonce:<n>" (lastSpends)

proc newEvmPartSeam*(chain, url: string, adapter: EvmAdapter, ks: Keystore, frm: Account): EvmPartSeam =
  EvmPartSeam(chain: chain, url: url, adapter: adapter, ks: ks, frm: frm)

proc refuse(s: EvmPartSeam, t: PartTransfer): string =
  if t.chain != s.chain: return "this wallet pays on " & s.chain & ", the part settles on " & t.chain
  if t.asset != "ETH" and not isErc20Asset(t.asset):
    return "an Ethereum share is paid in ETH or an erc20:<token> (asked: " & t.asset & ")"
  # the endpoint must serve the chain agreed: never pay, nor confirm, through another one
  try:
    let served = "eip155:" & rpcChainId(s.url)
    if served != s.chain: return "your RPC serves " & served & ", the part settles on " & s.chain
  except CatchableError as e:
    return "could not reach your RPC: " & e.msg
  ""

method sendPart*(s: EvmPartSeam, t: PartTransfer): tuple[ok: bool, tx, detail: string] =
  let why = s.refuse(t)
  if why.len > 0: return (false, "", why)
  try:
    # ETH, or the split's token: the adapter's ERC-20 path builds transfer(payTo, share) on it
    let amt =
      if isErc20Asset(t.asset):
        Amount(asset: AssetId(chain: s.adapter.describe().chain, symbol: t.asset, kind: akToken,
                              reference: t.asset[6 .. ^1]), raw: t.amount)
      else: Amount(asset: s.adapter.describe().nativeAsset, raw: t.amount)
    # the nonce this payment takes (the adapter signs at the pending count): kept with it,
    # so the chain can later say whether it may still land (partGone, exo-a90.23)
    let nonce = rpcNonce(s.url, s.frm.id)
    let r = s.adapter.submit(s.adapter.prepareTransfer(s.frm, t.to, amt), s.ks)
    s.spent = @["nonce:" & $nonce]
    (true, r.id, "")
  except CatchableError as e:
    (false, "", e.msg)

method lastSpends*(s: EvmPartSeam): seq[string] = s.spent

method partGone*(s: EvmPartSeam, t: PartTransfer, pp: PendingPart): tuple[gone: bool, detail: string] =
  ## An Ethereum payment can never land once your RPC no longer knows it AND its nonce is
  ## settled one way or the other: used by another mined transaction, or free again — then a
  ## new payment takes that same nonce, and at most one of the two can ever be mined. A
  ## payment your RPC still knows (pending or mined) is never gone; nor is one whose nonce is
  ## unknown, or when the RPC cannot be read.
  var nonce = -1'i64
  for sp in pp.spends:
    if sp.startsWith("nonce:"):
      try: nonce = parseBiggestInt(sp[6 .. ^1]) except ValueError: discard
  if nonce < 0: return (false, "the nonce " & pp.tx & " took is not known")
  try:
    if rpcTransferOf(s.url, pp.tx).found: return (false, pp.tx & " is known to your RPC")
    let mined = rpcNonceMined(s.url, s.frm.id)
    let pending = rpcNonce(s.url, s.frm.id)
    if mined > uint64(nonce):
      return (true, pp.tx & " is unknown to your RPC and nonce " & $nonce & " was used by another transaction")
    if pending <= uint64(nonce):
      return (true, pp.tx & " left the mempool unmined; nonce " & $nonce & " is free, so a new payment takes it")
    (false, pp.tx & " is unknown to your RPC, but something is pending at nonce " & $nonce)
  except CatchableError as e:
    (false, "could not read your RPC: " & e.msg)

method partLanded*(s: EvmPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  # bound before the case, never its selector: the read raises on failure (exo-14f), and a
  # raising selector leaves `result` unbuilt (see EvmAdapter.finality)
  let status = rpcReceiptStatus(s.url, tx)
  case status
  of 1: (true, "")
  of 0: (false, tx & " failed on " & s.chain)
  else: (false, tx & " is not in a block yet")

method checkReceived*(s: EvmPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  ## The creditor's own read of a reported payment: it must be on this chain, succeeded,
  ## pay payTo, and move exactly the share — each mismatch named.
  let why = s.refuse(t)
  if why.len > 0: return (false, why)
  try:
    if isErc20Asset(t.asset):
      # a token share: the receipt's Transfer log from THAT token, exactly the share, to payTo
      let r = rpcReceiptLogs(s.url, tx)
      if not r.found: return (false, "your RPC has no receipt for " & tx & " on " & s.chain & " yet")
      if r.status != 1: return (false, tx & " failed on " & s.chain)
      let why = matchTokenPayment(tokenTransfers(r.logs), t.asset[6 .. ^1], t.to, t.amount)
      if why.len > 0: return (false, tx & ": " & why)
      return (true, "")
    let r = rpcTransferOf(s.url, tx)
    if not r.found: return (false, "your RPC knows no transaction " & tx & " on " & s.chain)
    if r.status == -1: return (false, tx & " is not in a block yet")
    if r.status != 1: return (false, tx & " failed on " & s.chain)
    if r.toHex.toLowerAscii() != t.to.toLowerAscii(): return (false, tx & " pays " & r.toHex & ", not " & t.to)
    if r.valueDec != t.amount: return (false, tx & " pays the amount " & r.valueDec & " wei; the share is " & t.amount)
    (true, "")
  except CatchableError as e:
    (false, "could not read " & tx & ": " & e.msg)
