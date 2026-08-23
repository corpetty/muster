## A mock shielded chain — the second ChainAdapter, deliberately unlike EVM, so the
## wallet seam is proven generic rather than assumed. Modelled on the LEZ's real
## divergences (see demo/WALKTHROUGH.md, docs/labbook/lez-core-error-conventions):
##
##   • dual account model — a public id AND a shielded key-set, from one identity;
##   • delayed finality — a transfer debits the sender immediately but the
##     recipient's balance does not move until settlement completes several ticks
##     later (the "balance read right after a transfer is stale" trap);
##   • failure by sentinel — the underlying "chain" returns an empty string for a
##     read it cannot answer; the adapter TRANSLATES that into a raise, so an
##     unanswerable read can never be mistaken for a zero balance.
##
## In-memory and deterministic (advanced by tick()), so it needs no infra — unlike
## the real LEZ adapter, which needs the zone's proving stack running.

import std/[tables, json]
import ./types
import ./adapter
import ../crypto/keystore

const ChainId = "mock:shielded"

type
  Pending = object
    toId, symbol, raw: string
    ticksLeft: int
    failed: bool

  MockChain* = ref object of ChainAdapter
    native: AssetId
    token: AssetId
    ledger: Table[string, Table[string, string]]   ## accountId -> symbol -> raw base units
    pending: Table[string, Pending]                 ## txId -> settling transfer
    nextTx: int
    confirmTicks: int

proc newMockChain*(confirmTicks = 2): MockChain =
  let native = AssetId(chain: ChainId, symbol: "MOCK", kind: akNative, decimals: 9)
  let token = AssetId(chain: ChainId, symbol: "MTK", kind: akToken,
                      reference: "mock-token-1", decimals: 6)
  MockChain(native: native, token: token,
            ledger: initTable[string, Table[string, string]](),
            pending: initTable[string, Pending](), nextTx: 0, confirmTicks: confirmTicks)

proc credit*(m: MockChain, accountId, symbol, raw: string) =
  ## Test/seed helper: give an account a balance (as if it had received funds).
  if accountId notin m.ledger: m.ledger[accountId] = initTable[string, string]()
  let cur = m.ledger[accountId].getOrDefault(symbol, "0")
  m.ledger[accountId][symbol] = addDec(cur, normDec(raw))

proc rawBalance(m: MockChain, accountId, symbol: string): string =
  ## The "underlying chain read": returns "" for an account it has never seen — the
  ## sentinel-failure convention the adapter must not mistake for zero.
  if accountId notin m.ledger: return ""
  m.ledger[accountId].getOrDefault(symbol, "0")

# ── the seam ───────────────────────────────────────────────────────────────────

method describe*(m: MockChain): ChainDescriptor =
  ChainDescriptor(chain: ChainId, displayName: "Mock Shielded Zone",
                  nativeAsset: m.native, accountForms: @[afPublic, afShielded],
                  finality: finDelayed)

method accounts*(m: MockChain, ks: Keystore): seq[Account] =
  ## Two forms from one identity: a public id off the secp address, and a shielded
  ## key-set off the encryption identity (which does not appear on any public rail).
  const hexd = "0123456789abcdef"
  var pub = "mock-pub:"
  for b in ks.address(): (pub.add hexd[int(b shr 4)]; pub.add hexd[int(b and 0xF)])
  var shld = "mock-shld:"
  for b in ks.encIdentity().ed: (shld.add hexd[int(b shr 4)]; shld.add hexd[int(b and 0xF)])
  @[Account(chain: ChainId, form: afPublic, id: pub),
    Account(chain: ChainId, form: afShielded, id: shld)]

method assets*(m: MockChain): seq[AssetId] = @[m.native, m.token]

proc assetFor(m: MockChain, symbol: string): AssetId =
  if symbol == m.native.symbol: m.native
  elif symbol == m.token.symbol: m.token
  else: raise newException(WalletError, "unknown asset " & symbol)

method balance*(m: MockChain, account: Account, asset: AssetId): Amount =
  let raw = m.rawBalance(account.id, asset.symbol)
  if raw.len == 0:
    # The sentinel: an unanswerable read. NEVER return zero here — that is the
    # payment-app footgun this whole failure channel exists to prevent.
    raise newException(WalletError, "mock chain: no such account " & account.id)
  amount(asset, raw)

method estimateFee*(m: MockChain, frm: Account, to: string, amt: Amount): FeeEstimate =
  ## A flat proof cost in the native asset — a shielded transfer pays to prove,
  ## not per-byte gas.
  FeeEstimate(fee: amount(m.native, "1000000"), note: "shielded proof cost")

method prepareTransfer*(m: MockChain, frm: Account, to: string, amt: Amount): PreparedTx =
  PreparedTx(chain: ChainId, frm: frm, to: to, amount: amt,
             fee: m.estimateFee(frm, to, amt),
             payload: $(%*{"from": frm.id, "to": to, "symbol": amt.asset.symbol, "raw": amt.raw}))

method submit*(m: MockChain, tx: PreparedTx, ks: Keystore): TxRef =
  ## Debit the sender NOW; the recipient is credited only when the transfer settles
  ## (finality, confirmTicks later). Insufficient funds is a raise via sub(), never
  ## a silent success.
  let sym = tx.amount.asset.symbol
  let have = m.rawBalance(tx.frm.id, sym)
  if have.len == 0: raise newException(WalletError, "sender has no balance on this chain")
  m.ledger[tx.frm.id][sym] = subDec(have, tx.amount.raw)   # raises on underflow
  inc m.nextTx
  let id = "mocktx-" & $m.nextTx
  m.pending[id] = Pending(toId: tx.to, symbol: sym, raw: tx.amount.raw,
                          ticksLeft: m.confirmTicks, failed: false)
  TxRef(chain: ChainId, id: id)

method finality*(m: MockChain, txRef: TxRef): Finality =
  if txRef.id notin m.pending:
    raise newException(WalletError, "unknown tx " & txRef.id)
  let p = m.pending[txRef.id]
  if p.failed: Finality(status: fsFailed, detail: "settlement rejected")
  elif p.ticksLeft > 0:
    Finality(status: fsPending, detail: "settling (" & $p.ticksLeft & " to go)")
  else:
    Finality(status: fsFinal, detail: "settled")

proc tick*(m: MockChain) =
  ## Advance settlement one step. When a transfer's ticks reach zero, the recipient
  ## is finally credited — the moment the balance actually moves.
  for id, p in m.pending.mpairs:
    if p.failed or p.ticksLeft <= 0: continue
    dec p.ticksLeft
    if p.ticksLeft == 0:
      m.credit(p.toId, p.symbol, p.raw)
