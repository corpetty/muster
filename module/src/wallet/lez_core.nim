## The `LezCore` seam — muster's clean interface over the LEZ wallet (`lez_core` /
## `wallet_ffi`). Behind it: a deterministic `FakeLezCore` for tests (no infra), and
## later an `LpLezCore` that calls the real `lez_core` module over `lp_*` (P-L3).
##
## The seam is muster-shaped, not a 1:1 mirror of `lez_core`'s C surface — the real
## client maps these onto `create_account_*` / `get_balance` / `transfer_*` / `sync_*`
## / `claim_pinata`. What the seam DOES preserve is the LEZ's shape, because it's the
## part the adapter's correctness depends on (see docs/design/lez-adapter.md and
## docs/labbook/lez-core-error-conventions.md):
##
##   • two account forms — a public id, and a private key node (npk/vpk) that RECEIVES
##     by scan, not by address (a payment lands at an account the recipient didn't
##     create; `sync` + `listAccounts` discover it);
##   • the three failure conventions the real module uses, surfaced here as the seam's
##     own contract so the adapter translates each into a `WalletError` raise;
##   • delayed settlement — a shielded transfer proves (minutes) and the recipient's
##     note is discoverable only after `sync`.

import std/[json, tables, strutils]
import ./types

type
  LezAccountKind* = enum
    lakPublic  = "public"
    lakPrivate = "private"

  LezAccount* = object
    id*: string            ## the account id (public id, or a derived private account id)
    kind*: LezAccountKind
    npk*, vpk*: string     ## the private key node — empty for a public account

  ## The envelope `register_*` / `transfer_*` return: NON-empty even on failure, so the
  ## adapter must read `success`, never infer from emptiness (labbook §4).
  LezResult* = object
    success*: bool
    txHash*: string
    error*: string

  LezCore* = ref object of RootObj
    ## The seam. Concrete impls: FakeLezCore (here), LpLezCore (real, P-L3).

method createAccount*(c: LezCore, kind: LezAccountKind): LezAccount {.base, gcsafe.} =
  raise newException(WalletError, "LezCore.createAccount is abstract")

method listAccounts*(c: LezCore): seq[LezAccount] {.base, gcsafe.} =
  raise newException(WalletError, "LezCore.listAccounts is abstract")

method getBalanceRaw*(c: LezCore, accountId: string): string {.base, gcsafe.} =
  ## Raw base-units balance. The real module returns an EMPTY string on a read it
  ## can't answer (labbook §1) — the adapter raises on "" so it's never a false zero.
  raise newException(WalletError, "LezCore.getBalanceRaw is abstract")

method transferPublic*(c: LezCore, frm, to, amountRaw: string): LezResult {.base, gcsafe.} =
  raise newException(WalletError, "LezCore.transferPublic is abstract")

method transferPrivate*(c: LezCore, frm, toNpk, toVpk, amountRaw: string): LezResult {.base, gcsafe.} =
  ## Public→private or private→private. `toNpk`/`toVpk` are the recipient's key node;
  ## the module invents a random identifier, so the recipient RECOVERS by scan, never
  ## by querying a named id (labbook §5 / the POC). Proves — minutes — in the real one.
  raise newException(WalletError, "LezCore.transferPrivate is abstract")

method sync*(c: LezCore): int {.base, gcsafe.} =
  ## Scan to the tip, discovering received private notes. Non-zero == failure (the
  ## module's int convention). After this, a received note appears in listAccounts.
  raise newException(WalletError, "LezCore.sync is abstract")

method claimPinata*(c: LezCore, pinataId, account: string, nonce: int): LezResult {.base, gcsafe.} =
  ## The faucet. Fast (<20s) in the real module; stays sync there.
  raise newException(WalletError, "LezCore.claimPinata is abstract")

# ── envelope helper ────────────────────────────────────────────────────────────
proc parseEnvelope*(s: string): LezResult =
  ## Parse a `transfer_*` / `register_*` / `claim_*` JSON envelope. A malformed or
  ## empty string is a failure (not a silent success) — the whole point of §4.
  if s.len == 0:
    return LezResult(success: false, error: "empty result")
  try:
    let j = parseJson(s)
    LezResult(success: j{"success"}.getBool(false),
              txHash: j{"tx_hash"}.getStr(""),
              error: j{"error"}.getStr(""))
  except CatchableError:
    LezResult(success: false, error: "unparseable result: " & s)

# ── FakeLezCore — deterministic, in-memory, no infra ───────────────────────────
# Models the LEZ's shape so the adapter is exercised honestly: public transfers debit
# and credit at once; a PRIVATE transfer credits a note the recipient can only find
# after `sync` (receive-by-scan + delayed settlement); an unknown account's balance
# read returns "" (→ the adapter raises). `tick`-free: `sync` is the settlement step.

type
  PendingNote = object
    npk, vpk, amountRaw: string

  FakeLezCore* = ref object of LezCore
    balances: Table[string, string]        ## accountId -> raw balance
    accounts: seq[LezAccount]              ## created + discovered accounts
    pending: seq[PendingNote]              ## private notes not yet discovered by sync
    seq: int                               ## deterministic id/tx counter
    failNextTransfer*: bool                ## test hook: force a success:false envelope

proc newFakeLezCore*(): FakeLezCore =
  FakeLezCore(balances: initTable[string, string](), seq: 0)

proc nextId(c: FakeLezCore, prefix: string): string =
  inc c.seq
  prefix & "-" & $c.seq

method createAccount*(c: FakeLezCore, kind: LezAccountKind): LezAccount =
  let a =
    if kind == lakPublic:
      LezAccount(id: c.nextId("pub"), kind: lakPublic)
    else:
      let n = c.nextId("npk"); let v = c.nextId("vpk")
      # id derived from the key node (models SHA256(prefix‖npk‖identifier))
      LezAccount(id: c.nextId("priv"), kind: lakPrivate, npk: n, vpk: v)
  c.accounts.add a
  c.balances[a.id] = "0"
  a

method listAccounts*(c: FakeLezCore): seq[LezAccount] = c.accounts

method getBalanceRaw*(c: FakeLezCore, accountId: string): string =
  ## Sentinel: an account the wallet doesn't hold returns "" (an unanswerable read),
  ## which the adapter turns into a raise — never a false zero.
  if accountId in c.balances: c.balances[accountId] else: ""

proc credit(c: FakeLezCore, id, amountRaw: string) =
  let cur = if id in c.balances: c.balances[id] else: "0"
  c.balances[id] = $(parseBiggestUInt(cur) + parseBiggestUInt(amountRaw))

proc debitOrRaise(c: FakeLezCore, id, amountRaw: string) =
  let cur = if id in c.balances: c.balances[id] else: ""
  if cur.len == 0: raise newException(WalletError, "unknown account " & id)
  if parseBiggestUInt(cur) < parseBiggestUInt(amountRaw):
    raise newException(WalletError, "insufficient funds")
  c.balances[id] = $(parseBiggestUInt(cur) - parseBiggestUInt(amountRaw))

method transferPublic*(c: FakeLezCore, frm, to, amountRaw: string): LezResult =
  if c.failNextTransfer:
    c.failNextTransfer = false
    return LezResult(success: false, error: "wallet FFI error 99")
  c.debitOrRaise(frm, amountRaw)
  c.credit(to, amountRaw)
  LezResult(success: true, txHash: c.nextId("tx"))

method transferPrivate*(c: FakeLezCore, frm, toNpk, toVpk, amountRaw: string): LezResult =
  if c.failNextTransfer:
    c.failNextTransfer = false
    return LezResult(success: false, error: "ProgramProveFailed")
  c.debitOrRaise(frm, amountRaw)
  # The note is NOT yet discoverable — it settles into a fresh account on sync, which
  # the recipient finds by scanning under its key node (receive-by-scan).
  c.pending.add PendingNote(npk: toNpk, vpk: toVpk, amountRaw: amountRaw)
  LezResult(success: true, txHash: c.nextId("tx"))

method sync*(c: FakeLezCore): int =
  ## Settle pending private notes into discoverable accounts under their key node.
  for n in c.pending:
    let a = LezAccount(id: c.nextId("recv"), kind: lakPrivate, npk: n.npk, vpk: n.vpk)
    c.accounts.add a
    c.balances[a.id] = n.amountRaw
  c.pending = @[]
  0

method claimPinata*(c: FakeLezCore, pinataId, account: string, nonce: int): LezResult =
  c.credit(account, "1000000000")   # fund with 1e9 base units
  LezResult(success: true, txHash: c.nextId("tx"))
