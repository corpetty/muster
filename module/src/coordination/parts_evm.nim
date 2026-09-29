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
    let r = s.adapter.submit(s.adapter.prepareTransfer(s.frm, t.to, amt), s.ks)
    (true, r.id, "")
  except CatchableError as e:
    (false, "", e.msg)

method partLanded*(s: EvmPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  case rpcReceiptStatus(s.url, tx)
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
