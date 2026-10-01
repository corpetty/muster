## Reads keystore_module for its status row (exo-149.1 K1); keystore_status.nim says what
## the replies mean. Not pure: lp_* calls, so like rln_probe.nim it is compiled only into
## the plugin.
##
## Every read here is ungated and local to keystore_module (no chain, no human), but
## keystore_module dispatches one call at a time and runs scrypt inside approve(), so a
## read can wait behind a human's approval. A blocking cross-module call on the module
## thread is what stalled sends once already (exo-eb6.1), so each read goes out async,
## at most every 5 s, and lands in a queue the module thread drains. A reply older than
## 30 s, or a call that could not go out, reads as unread: never a stale green.

import std/[json, times]
import logos_sdk/ffi
import ../transport/inbound_queue
import ./keystore_status

const
  AsyncMs = 15_000.cint     ## generous: a read may queue behind a human's approve (scrypt)
  EveryS = 5.0
  StaleS = 30.0

type
  AsyncRead = object
    q: InboundQueue
    inFlight: bool
    sentAt: float
    last: JsonNode          ## the last reply that parsed; nil until one does
    lastAt: float
  KeystoreProbe* = ref object
    client: ptr LpClient
    identity, accounts, labels, wallets: AsyncRead

proc onRead(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## On the callee's thread: copy the reply into the queue (no Nim GC), nothing more.
  let q = cast[ptr InboundQueue](userData)
  if ok != 0 and json != nil: q[].enqueue(json) else: q[].enqueue("")

proc newKeystoreProbe*(): KeystoreProbe =
  result = KeystoreProbe()
  for r in [addr result.identity, addr result.accounts, addr result.labels, addr result.wallets]:
    initInboundQueue(r[].q)
  GC_ref(result)            # the callbacks hold pointers into it

proc reached(p: KeystoreProbe): bool =
  ## Created on first use, origin muster_module: keystore_module must attribute our calls
  ## to us (it reads the runtime's caller, never an argument).
  if p.client == nil:
    p.client = lp_client_create(KeystoreModule.cstring, Ours.cstring, nil, nil)
  p.client != nil

proc drain(r: var AsyncRead, now: float) =
  for raw in r.q.drain():
    r.inFlight = false
    var s = newString(raw.len)
    if raw.len > 0: copyMem(addr s[0], unsafeAddr raw[0], raw.len)
    let j = ksReply(s)
    if j != nil: (r.last = j; r.lastAt = now)
  if r.inFlight and now - r.sentAt > AsyncMs.float / 1000 + 5: r.inFlight = false

proc fire(p: KeystoreProbe, r: var AsyncRead, meth: string, now: float) =
  if r.inFlight or now - r.sentAt < EveryS: return
  r.sentAt = now
  if lp_invoke_async(p.client, meth.cstring, "[]", AsyncMs, onRead, addr r.q) == LP_OK:
    r.inFlight = true
  else:
    r.last = nil            # it could not even be asked: unread, not the old answer

proc current(r: AsyncRead, now: float): JsonNode =
  if r.last != nil and now - r.lastAt <= StaleS: r.last else: nil

proc read*(p: KeystoreProbe): KeystoreInputs =
  ## Everything keystoreRow needs, now; the first call after load answers "did not
  ## answer" until the replies land (a few ms later, on the next read).
  if not p.reached(): return KeystoreInputs(reached: false)
  let now = epochTime()
  for (r, meth) in [(addr p.identity, "caller_identity"), (addr p.accounts, "list_accounts"),
                    (addr p.labels, "get_labels"), (addr p.wallets, "get_account_wallets")]:
    r[].drain(now)
    p.fire(r[], meth, now)
  KeystoreInputs(reached: true, identity: p.identity.current(now), accounts: p.accounts.current(now),
                 labels: p.labels.current(now), wallets: p.wallets.current(now))
