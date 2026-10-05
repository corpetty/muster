# chronos `waitFor` at the sync lidl boundary — and the thread that must own the loop (2026-08-23)

Not an afternoon lost — a note written to prevent one. Adopting `nim-web3` (ADR-014)
brought chronos into the module for the first time, and the way an async library is
driven from a synchronous module surface has exactly two ways to go wrong. Both are
silent until they aren't.

## The shape

`nim-web3`'s `eth_*` calls are chronos `Future[T]` — there is no blocking variant.
The module's callable surface (`muster.lidl`) is the opposite: synchronous
request/response. The host calls a method and expects a value back, not a future.

So the bridge is `waitFor`, at each RPC call site (`module/src/wallet/evm_rpc.nim`):

```nim
let bal = waitFor client.eth_getBalance(addr, "latest")   # runs the chronos loop
```

`waitFor` runs the **global chronos dispatcher** on the calling thread until that
future completes, then returns the value. This is not a workaround — it is the
honest bridge. The lidl contract is request/response; the method must return a
value, and `waitFor` is how you turn one future into one value at that seam.

## The two ways it goes wrong

**1. Calling `waitFor` from a thread that does not own the loop.** `waitFor` drives
the *calling thread's* dispatcher. The module already has a foreign-thread seam —
delivery's `messageReceived` fires on delivery's own thread and only enqueues raw
bytes (`transport/inbound_queue.nim`), draining on the module thread in `poll()`.
Calling `waitFor` (or any chronos await) from that foreign callback would drive the
wrong loop, or none — a hang, not an error. **Rule: `waitFor` only on the module
dispatch thread.** The wallet RPC is called from lidl dispatch, so it is fine; never
move it behind the delivery callback.

**2. Mixing async backends.** The working agreement — *chronos only, never
std/asyncdispatch* — is load-bearing here. `nim-web3` pulls chronos; if any
dependency dragged in `std/asyncdispatch`, the two dispatchers deadlock in ways that
reproduce once in twenty runs. When adding a Nim package to
`codegen.nim.packages`, check its async backend before pinning it.

## The consequence to design around

`waitFor` **blocks the calling thread** for the whole RPC round-trip. That is fine
for the module (dispatch is one call at a time), but it means a UI must call the
module **off its render thread** — QtRO/QML async invocation — or a slow RPC (or the
LEZ's minutes-long proof) freezes the interface. The module cannot make the call
non-blocking without changing the lidl contract to return futures, which the host
does not speak. So responsiveness is the caller's job, not the module's.

Two smaller consequences, both handled:
- **Reuse the connected client.** `evm_rpc` caches one `RpcHttpClient` per URL;
  connecting on every call was pure latency. A failed call evicts its client so the
  next reconnects (a dropped keep-alive heals itself).
- **A failed `waitFor` is a `WalletError`, never a sentinel.** Same rule as
  everywhere on the read path: a chain error must not read as a zero balance.

## The third way it goes wrong: a `waitFor` with no budget (exo-14f, 2026-10-02)

"Fine for the module" above assumed every call comes back. The endpoint is the user's
own, untrusted infrastructure (invariant 8), and one that accepts the connection and
never answers holds `waitFor` — the module thread, and every UI call queued behind it —
for as long as it likes. A lidl call cannot return early on its own; only a deadline
can end it. So **no chain call waits without a budget**: `wallet/rpc_budget.nim`'s
`bounded(fut, budget)` is `waitFor fut.wait(budget)`, ONE deadline over connect,
request, headers and body, and past it the future is cancelled and `RpcTimeoutError`
raised. Reads get 5 s, broadcasts 30 s, the liveness probe 1.5 s.

Three details that each looked fine and were not:

- **std/httpclient's `timeout` is not a deadline.** It bounds each `recv`; its connect
  (`net.dial`) has none, so an address that drops SYNs hangs it for the kernel's TCP
  timeout (~2 min). `probeRpc` had a 1.5 s "timeout" with exactly that hole.
  `drivers/safe_rpc.nim` moved to the chronos client for this reason.
- **A poll loop counted in iterations multiplies the budget.** `coordinate_submit`
  polled finality 21 times; with a 5 s read budget that is ~105 s. A wait is a
  wall-clock window that also stops at the first failed read
  (`settlement.watchWithin`): at most the window plus one read.
- **Null is a value only where the protocol says so.** A null receipt is "not mined
  yet"; a null nonce, balance, height or transaction hash is a failed read and raises.
- **Making a read raise can crash its caller (Nim 2.2.10).** `rpcReceiptStatus` used to
  swallow every error; once it raised, `EvmAdapter.finality` segfaulted intermittently.
  Its body was `case rpcReceiptStatus(…)` with every branch assigning `result`, and
  the compiler's `allPathsAsgnResult` does not ask whether a `case` *selector* can
  raise, so it skipped zero-initializing `result`. When the call raised, the proc
  returned an unbuilt `Finality`, and ORC destroys a call's return value even on the
  raise path, so the caller freed garbage. The fix: bind the call first
  (`let status = …; case status`). The C shows it: no `nimZeroMem(&result)` in the
  callee, and `if (*nimErr_) { eqdestroy(&T_) …}` in the caller. ASan
  (`-d:useMalloc --passC:-fsanitize=address`) turns the one-in-two crash into a
  deterministic one. Check this whenever a call that never raised starts to.

Not bounded: resolving a hostname (the OS resolver runs synchronously before the first
byte). `tests/rpc_budget_test.nim` holds every call to its budget against a local
socket that accepts and never replies.

## A budget per call is not a budget per poll (exo-14f.1, 2026-10-05)

The budgets bound ONE call, and the UI polls. `coordinate_accounts` runs every 10 s and
reads each disclosed Safe twice (`chainViewOf`, then `bypassesOf`), each a probe and one
or two reads. Against a node that answers `eth_chainId` and holds `eth_call`, two Safe
accounts cost about 20 s in one call, which is the UI call's own timeout. `connectivity`
probes every 5 s, and the pumps on the intents tick read receipts every 2 s. Each read
costs its full budget, so the module thread is busy most of every window, and every UI
call waits behind it.

So an endpoint that gives no answer **cools down** (`wallet/rpc_budget.nim`). For a
short time a read or a probe to it is not sent: it raises `RpcCoolingError`, an
`RpcTimeoutError`, at once. The message names the call that went unanswered, when it
went unanswered, and the next try, for example `not sent: the endpoint did not answer
eth_call within 5s at 14:02:11; next try at 14:02:26`. The first call after the
cooldown is sent. Any successful answer ends the cooldown. The decisions:

- **15 s, doubled per no-answer in a row, up to 60 s.** 15 s skips at least one
  accounts poll. A fixed cooldown still costs one budget per cooldown for as long as the
  node is down: about 5 s of every 20 s with the pumps reading. The cap keeps that to
  one budget a minute and still uses a recovered node within a minute. Naming the
  endpoint again in Settings ends its cooldown at once.
- **A broadcast is always sent.** It is the user's own action, never a poll, and muster
  does not refuse it because an earlier read went unanswered. Its no-answer still starts
  a cooldown for the reads. The reads that come before a send (nonce, gas price) do
  respect the cooldown, so a payment made inside one fails at once and says when to
  try again.
- **A status line says "not asked", never "unreachable".** `probeRpc` and the Safe's
  owner, module, guard and threshold reads frame the detail themselves:
  `RPC not asked: it did not answer …; next try at …`. The connectivity row, an
  account's "unknown" check and readiness show it as it is.
- **Keyed by URL, never written into a message.** A hosted RPC takes its key in the
  path. The LEZ client wrote the sequencer URL into every error; it no longer does.
