## ChainAdapter — the per-chain seam — and Wallet, the chain-agnostic aggregate.
##
## The same shape as every other Muster seam (Transport, ConversationCrypto,
## Keystore, Driver): an interface with ≥2 concrete implementations, so the
## abstraction is proven generic rather than assumed. Here the two are the EVM/Safe
## adapter and a mock shielded-chain adapter whose account model, finality latency,
## and error conventions are deliberately unlike EVM (modelled on the LEZ).
##
## Every method raises `WalletError` on any chain-level failure — an adapter must
## translate its chain's quirks (empty-string / success:false / timeouts) into a
## raise, so a failed read can never be mistaken for a zero balance or a completed
## send. Signing goes through the Keystore seam (FS-4): an adapter is handed the
## keystore, never a key.
##
## RPC endpoints are untrusted, user-configured infrastructure (invariant 8); a
## balance read is a `verified-locally` fact (F-10) the client performs itself.

import std/tables
import ./types
import ../crypto/keystore
export types

type
  ChainAdapter* = ref object of RootObj
    ## One chain behind the seam. Concrete adapters override every method.

method describe*(a: ChainAdapter): ChainDescriptor {.base.} =
  raise newException(WalletError, "ChainAdapter.describe is abstract")

method accounts*(a: ChainAdapter, ks: Keystore): seq[Account] {.base.} =
  ## Derive this chain's account(s) from the module identity — an EVM address, a
  ## LEZ public id and/or a shielded key-set. A chain may offer more than one form.
  raise newException(WalletError, "ChainAdapter.accounts is abstract")

method assets*(a: ChainAdapter): seq[AssetId] {.base.} =
  ## The asset registry: the native asset plus any tokens this adapter knows.
  raise newException(WalletError, "ChainAdapter.assets is abstract")

method balance*(a: ChainAdapter, account: Account, asset: AssetId): Amount {.base.} =
  ## The account's balance in the asset. Raises on a failed read — never returns a
  ## zero that a caller could mistake for "empty".
  raise newException(WalletError, "ChainAdapter.balance is abstract")

method estimateFee*(a: ChainAdapter, frm: Account, to: string, amt: Amount): FeeEstimate {.base.} =
  raise newException(WalletError, "ChainAdapter.estimateFee is abstract")

method prepareTransfer*(a: ChainAdapter, frm: Account, to: string, amt: Amount): PreparedTx {.base.} =
  ## Build (but do not submit) a transfer — so the effect can be reviewed before it
  ## is signed (invariant 1's spirit at the account level).
  raise newException(WalletError, "ChainAdapter.prepareTransfer is abstract")

method submit*(a: ChainAdapter, tx: PreparedTx, ks: Keystore): TxRef {.base.} =
  ## Sign (via the keystore) and broadcast. Returns a handle for polling finality.
  raise newException(WalletError, "ChainAdapter.submit is abstract")

method finality*(a: ChainAdapter, txRef: TxRef): Finality {.base.} =
  ## Observe finality from the chain — a poll, never asserted (R-8). Delayed chains
  ## stay `pending` until settlement really completes.
  raise newException(WalletError, "ChainAdapter.finality is abstract")

# ── Wallet — the chain-agnostic aggregate over the keystore + adapters ─────────

type
  Wallet* = ref object
    ks: Keystore
    adapters: OrderedTable[string, ChainAdapter]   ## chain id -> adapter

proc newWallet*(ks: Keystore): Wallet =
  Wallet(ks: ks, adapters: initOrderedTable[string, ChainAdapter]())

proc register*(w: Wallet, a: ChainAdapter) =
  ## Add a chain. The chain id from describe() is the key, so the wallet routes by
  ## it and a second chain is a registration, not a code change.
  w.adapters[a.describe().chain] = a

proc adapterFor*(w: Wallet, chain: string): ChainAdapter =
  if chain notin w.adapters: raise newException(WalletError, "no adapter for chain " & chain)
  w.adapters[chain]

proc chains*(w: Wallet): seq[ChainDescriptor] =
  for a in w.adapters.values: result.add a.describe()

proc accounts*(w: Wallet): seq[Account] =
  for a in w.adapters.values:
    for acc in a.accounts(w.ks): result.add acc

proc assets*(w: Wallet): seq[AssetId] =
  for a in w.adapters.values:
    for asset in a.assets(): result.add asset

proc balance*(w: Wallet, chain: string, account: Account, asset: AssetId): Amount =
  w.adapterFor(chain).balance(account, asset)

proc estimateFee*(w: Wallet, chain: string, frm: Account, to: string, amt: Amount): FeeEstimate =
  w.adapterFor(chain).estimateFee(frm, to, amt)

proc send*(w: Wallet, chain: string, frm: Account, to: string, amt: Amount): TxRef =
  ## Prepare then submit — the account-level counterpart to the coordinated intent
  ## path. Signing happens behind the keystore seam.
  let a = w.adapterFor(chain)
  a.submit(a.prepareTransfer(frm, to, amt), w.ks)

proc finality*(w: Wallet, txRef: TxRef): Finality =
  w.adapterFor(txRef.chain).finality(txRef)
