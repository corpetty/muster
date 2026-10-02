## The `LezCore` seam — muster's clean interface over the LEZ wallet (`lez_core` /
## `wallet_ffi`). Behind it: a deterministic `FakeLezCore` for tests (no infra), and
## later an `LpLezCore` that calls the real `lez_core` module over `lp_*` (P-L3).
##
## The seam is muster-shaped, not a 1:1 mirror of `lez_core`'s C surface — the real
## client maps these onto `create_account_*` / `get_balance` / `transfer_*` / `sync_*`.
## There is no faucet: LEZ v0.3.0 removed the testnet's pinata program (exo-eb6.4), so
## native LEZ reaches an account only at genesis, over the bridge, or by a transfer from
## an account that holds some. What the seam DOES preserve is the LEZ's shape, because it's the
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
import ../intents/disclosure   # the action-manifest rows (exo-002.1)
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

  ## The four transfer rails the zone supports (from demo/muster-ui's ChatBackendAssets
  ## — the working driver). The source decides whether the payer is named, the
  ## destination whether the payee is, and the amount is public unless BOTH ends are
  ## shielded. This square is the education surface: the same transfer, four honesties.
  TransferForm* = enum
    tfPublic    = "public"     ## public → public         (transfer_public)
    tfShield    = "shield"     ## public → private         (transfer_shielded)
    tfDeshield  = "deshield"   ## private → public         (transfer_deshielded)
    tfPrivate   = "private"    ## private → private        (transfer_private)

  Disclosure* = object
    amount*, payer*, payee*: bool   ## what THIS rail puts on the public record

  LezCore* = ref object of RootObj
    ## The seam. Concrete impls: FakeLezCore (here), LpLezCore (real, P-L3).
    synced*, tip*: int     ## where the last `sync` left this wallet's scan, and the chain's tip

const
  LezSyncOk* = 0           ## `sync`: the scan is at the chain tip
  LezSyncFailed* = 1       ## `sync`: the scan failed (the module's int convention)
  LezSyncBehind* = 2       ## `sync`: progress made, not yet at the tip — call again
  LezProveBudgetMs* = 900_000   ## a proving transfer's budget (measured 6m41s–7.4m + headroom)

proc disclosureOf*(f: TransferForm): Disclosure =
  ## What each rail leaks — verbatim from the demo's rails. The amount is public unless
  ## both ends are shielded (private→private); the payer is named iff the source is
  ## public; the payee is named iff the destination is public.
  case f
  of tfPublic:   Disclosure(amount: true,  payer: true,  payee: true)
  of tfShield:   Disclosure(amount: true,  payer: true,  payee: false)
  of tfDeshield: Disclosure(amount: true,  payer: false, payee: true)
  of tfPrivate:  Disclosure(amount: false, payer: false, payee: false)

proc toDisclosureRows*(d: Disclosure): seq[DisclosureRow] =
  ## The LEZ square as action-manifest rows (docs/design/action-manifest.md): each
  ## field this rail puts on the public record is a row to the chain observer. The
  ## first real per-action disclosure — a room-coordinated LEZ transfer (Mode B)
  ## declares exactly these beyond the baseline.
  if d.amount: result.add row("amount", obChainObserver)
  if d.payer:  result.add row("payer",  obChainObserver)
  if d.payee:  result.add row("payee",  obChainObserver)

method createAccount*(c: LezCore, kind: LezAccountKind): LezAccount {.base, gcsafe.} =
  raise newException(WalletError, "LezCore.createAccount is abstract")

method listAccounts*(c: LezCore): seq[LezAccount] {.base, gcsafe.} =
  raise newException(WalletError, "LezCore.listAccounts is abstract")

method getBalanceRaw*(c: LezCore, accountId: string, isPublic: bool): string {.base, gcsafe.} =
  ## Raw (decimal) base-units balance. lez_core's get_balance(id, is_public) needs to
  ## know the account form, so the seam carries it. The real module returns an EMPTY
  ## string on a read it can't answer (labbook §1) — the adapter raises on "" so it's
  ## never a false zero.
  raise newException(WalletError, "LezCore.getBalanceRaw is abstract")

method transfer*(c: LezCore, form: TransferForm, frm, to, amountRaw: string): LezResult {.base, gcsafe.} =
  ## Move value on one of the four rails. `to` is an account id for a public
  ## destination (tfPublic/tfDeshield) and the recipient's key node for a shielded one
  ## (tfShield/tfPrivate). A shielded send invents a random identifier, so the
  ## recipient RECOVERS by scan, never by querying a named id (labbook / the POC). The
  ## real module maps these to transfer_public/shielded/deshielded/private, async +
  ## 900s, amount as 16-byte LE hex; each PROVES (minutes) except tfPublic.
  raise newException(WalletError, "LezCore.transfer is abstract")

method sync*(c: LezCore): int {.base, gcsafe.} =
  ## Advance the scan toward the tip, discovering received private notes: LezSyncOk once
  ## at the tip (a received note then appears in listAccounts), LezSyncBehind when it made
  ## progress but a call's budget ran out first — a fresh wallet on testnet starts at
  ## block 0, tens of thousands of blocks away — and LezSyncFailed on a failed scan.
  ## `synced` / `tip` say where it got to.
  raise newException(WalletError, "LezCore.sync is abstract")

method proving*(c: LezCore): bool {.base, gcsafe.} =
  ## Is a transfer proving in the background in this wallet right now? lez_core serializes
  ## the wallet, so any other call — a scan above all — waits behind a ~7-minute proof and
  ## times out. A sync core never is.
  false

method labelled*(c: LezCore, label: string): string {.base, gcsafe.} =
  ## The id of the account a label names in THIS wallet, "" if none. Labels live in the
  ## wallet's own storage (lez_core add_label / resolve_label), so they outlast the
  ## process — how a relaunch finds the accounts it made (exo-884). A core without labels
  ## answers "", and the adapter creates accounts as before.
  ""

method labelAccount*(c: LezCore, label: string, account: LezAccount): bool {.base, gcsafe.} =
  ## Name one of this wallet's accounts, persistently; true once the label resolves to it.
  false

method pollTransfer*(c: LezCore): tuple[done: bool, result: LezResult] {.base, gcsafe.} =
  ## For an ASYNC core (LpLezCore): has the in-flight proving transfer settled yet, and
  ## its result? A proving transfer takes minutes, so the real core fires it in the
  ## BACKGROUND (transfer returns a "pending" marker at once, never blocking the module
  ## thread) and this reports completion. Sync cores (the fake) return their result from
  ## transfer directly and never mark it pending, so the default is "n/a, done".
  (done: true, result: LezResult(success: true))

proc walkSync*(last, tip, chunk: int, budgetS: float, step: proc(toBlock: int): bool,
               clock: proc(): float): tuple[code, reached: int] =
  ## Walk a scan from `last` toward `tip` in steps of at most `chunk` blocks, while the
  ## call's budget lasts — one sync_to_block to a far tip does not fit a call's timeout
  ## (measured on testnet: ~1s per 250 blocks, 5000 blocks in 13.6s), and a timed-out
  ## lez_core call keeps the wallet busy behind it. Returns LezSyncOk at the tip,
  ## LezSyncBehind when the budget ran out first, LezSyncFailed when a step failed;
  ## `reached` is the last block that did sync.
  var at = last
  let start = clock()
  while at < tip:
    if at > last and clock() - start >= budgetS: return (LezSyncBehind, at)
    let next = min(at + chunk, tip)
    if not step(next): return (LezSyncFailed, at)
    at = next
  (LezSyncOk, at)

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

  FakeLezChain* = ref object
    ## The pretend ledger. A standalone FakeLezCore owns one; several wallets can SHARE
    ## one (newFakeLezCore(chain)) so a private payment from one member's wallet lands in
    ## another's — found only by the recipient's own scan (exo-a90.9, the private split).
    balances: Table[string, string]        ## accountId -> raw balance
    pending: seq[PendingNote]              ## private notes not yet discovered by a scan
    seq: int                               ## deterministic id/tx counter

  FakeLezCore* = ref object of LezCore
    chain: FakeLezChain
    shared: bool                           ## true = a wallet on a shared chain
    accounts: seq[LezAccount]              ## created + discovered accounts (THIS wallet's)
    labels: Table[string, string]          ## label -> account id, as the wallet stores them
    failNextTransfer*: bool                ## test hook: force a success:false envelope
    lagSyncs*: int                         ## test hook: the next n scans are still catching up
    asyncTransfers*: bool                  ## test hook: prove in the background, as LpLezCore does
    proveTicks*: int                       ## …settling on the n-th pollTransfer (default 2)
    proving: tuple[form: TransferForm, frm, to, amountRaw: string, ticks: int, live: bool]

proc newFakeLezChain*(): FakeLezChain =
  FakeLezChain(balances: initTable[string, string](), seq: 0)

proc newFakeLezCore*(): FakeLezCore =
  ## A standalone wallet: its own ledger, and a scan settles every pending note into it.
  FakeLezCore(chain: newFakeLezChain())

proc newFakeLezCore*(chain: FakeLezChain): FakeLezCore =
  ## One wallet on a SHARED chain: its scan discovers only the notes sent to a key node
  ## this wallet holds — receive-by-scan across members, the way the real zone behaves.
  FakeLezCore(chain: chain, shared: true)

proc fund*(chain: FakeLezChain, accountId, raw: string) =
  ## Genesis funding, for tests and the demo: credit any account on the chain directly,
  ## the way a zone's genesis does. Not a faucet: LEZ v0.3 has none, and the fake keeps
  ## no kindness the zone lacks.
  let cur = if accountId in chain.balances: chain.balances[accountId] else: "0"
  chain.balances[accountId] = $(parseBiggestUInt(cur) + parseBiggestUInt(raw))

proc nextId(c: FakeLezCore, prefix: string): string =
  inc c.chain.seq
  prefix & "-" & $c.chain.seq

method createAccount*(c: FakeLezCore, kind: LezAccountKind): LezAccount =
  let a =
    if kind == lakPublic:
      LezAccount(id: c.nextId("pub"), kind: lakPublic)
    else:
      # a key node shaped like the zone's: a 32-byte npk and a 33-byte vpk, lowercase hex
      # (deterministic from the chain's counter, unique across the wallets that share it)
      inc c.chain.seq
      let n = toHex(c.chain.seq, 64).toLowerAscii()
      let v = "02" & toHex(c.chain.seq, 64).toLowerAscii()
      # id derived from the key node (models SHA256(prefix‖npk‖identifier))
      LezAccount(id: c.nextId("priv"), kind: lakPrivate, npk: n, vpk: v)
  c.accounts.add a
  c.chain.balances[a.id] = "0"
  a

method listAccounts*(c: FakeLezCore): seq[LezAccount] = c.accounts

method labelled*(c: FakeLezCore, label: string): string = c.labels.getOrDefault(label, "")

method labelAccount*(c: FakeLezCore, label: string, account: LezAccount): bool =
  ## As the wallet does: a label is taken once, and only for an account the wallet holds.
  if label in c.labels: return c.labels[label] == account.id
  for a in c.accounts:
    if a.id == account.id:
      c.labels[label] = account.id
      return true
  false

method getBalanceRaw*(c: FakeLezCore, accountId: string, isPublic: bool): string =
  ## Sentinel: an account the ledger doesn't hold returns "" (an unanswerable read),
  ## which the adapter turns into a raise — never a false zero. (The fake's ledger is
  ## keyed by id, so isPublic is unused here; the real module needs it.)
  if accountId in c.chain.balances: c.chain.balances[accountId] else: ""

proc credit(c: FakeLezCore, id, amountRaw: string) = c.chain.fund(id, amountRaw)

proc fund*(c: FakeLezCore, accountId, raw: string) =
  ## Genesis funding on this wallet's chain (tests, the demo): see FakeLezChain.fund.
  c.credit(accountId, raw)

proc debitOrRaise(c: FakeLezCore, id, amountRaw: string) =
  let cur = if id in c.chain.balances: c.chain.balances[id] else: ""
  if cur.len == 0: raise newException(WalletError, "unknown account " & id)
  if parseBiggestUInt(cur) < parseBiggestUInt(amountRaw):
    raise newException(WalletError, "insufficient funds")
  c.chain.balances[id] = $(parseBiggestUInt(cur) - parseBiggestUInt(amountRaw))

proc settle(c: FakeLezCore, form: TransferForm, frm, to, amountRaw: string): LezResult {.gcsafe.}

method transfer*(c: FakeLezCore, form: TransferForm, frm, to, amountRaw: string): LezResult =
  if c.failNextTransfer:
    c.failNextTransfer = false
    return LezResult(success: false, error: "wallet FFI error 99")   # the envelope failure
  if c.asyncTransfers:
    # as LpLezCore: accepted at once, proved in the background, the result polled later —
    # nothing moves on the chain until the proof lands
    if c.proving.live:
      return LezResult(success: false, error: "a LEZ transfer is already proving — wait for it")
    c.proving = (form, frm, to, amountRaw, (if c.proveTicks > 0: c.proveTicks else: 2), true)
    return LezResult(success: true, txHash: "pending")
  c.settle(form, frm, to, amountRaw)

method proving*(c: FakeLezCore): bool = c.proving.live

method pollTransfer*(c: FakeLezCore): tuple[done: bool, result: LezResult] =
  if not c.proving.live: return (true, LezResult(success: true))
  dec c.proving.ticks
  if c.proving.ticks > 0: return (false, LezResult())
  c.proving.live = false
  try: (true, c.settle(c.proving.form, c.proving.frm, c.proving.to, c.proving.amountRaw))
  except WalletError as e: (true, LezResult(success: false, error: e.msg))

proc settle(c: FakeLezCore, form: TransferForm, frm, to, amountRaw: string): LezResult {.gcsafe.} =
  c.debitOrRaise(frm, amountRaw)
  case form
  of tfPublic, tfDeshield:
    # public destination (an account id) — credited at once.
    c.credit(to, amountRaw)
  of tfShield, tfPrivate:
    # shielded destination (a "npk:vpk" key node) — the note is NOT yet discoverable;
    # it settles into a fresh account on a scan, found under its key node.
    let parts = to.split(':')
    let npk = (if parts.len > 0: parts[0] else: to)
    let vpk = (if parts.len > 1: parts[1] else: "")
    c.chain.pending.add PendingNote(npk: npk, vpk: vpk, amountRaw: amountRaw)
  LezResult(success: true, txHash: c.nextId("tx"))

method sync*(c: FakeLezCore): int =
  ## Settle pending private notes into discoverable accounts under their key node. A
  ## standalone wallet takes every note; a wallet on a shared chain only the notes sent to
  ## a key node it holds — the rest stay for their own recipients' scans. With `lagSyncs`
  ## set, the scan is still catching up: nothing is discovered yet.
  if c.lagSyncs > 0:
    dec c.lagSyncs
    (c.synced, c.tip) = (1000, 29083)
    return LezSyncBehind
  var keep: seq[PendingNote]
  for n in c.chain.pending:
    var mine = not c.shared
    for a in c.accounts:
      if a.kind == lakPrivate and a.npk == n.npk and a.vpk == n.vpk: mine = true
    if not mine:
      keep.add n
      continue
    let a = LezAccount(id: c.nextId("recv"), kind: lakPrivate, npk: n.npk, vpk: n.vpk)
    c.accounts.add a
    c.chain.balances[a.id] = n.amountRaw
  c.chain.pending = keep
  (c.synced, c.tip) = (29083, 29083)
  LezSyncOk
