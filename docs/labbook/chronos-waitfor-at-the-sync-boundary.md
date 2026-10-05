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

### The Bitcoin node (exo-496, 2026-10-05)

`wallet/btc_adapter.nim` was left on std/httpclient by exo-14f, with the same unbounded
connect. It moved to the budget too, with two differences from the EVM seams:

- **Not nim-json-rpc's client.** `RpcHttpClient` raises on a non-2xx status before it
  reads the body. bitcoind answers a JSON-RPC 1.0 error with HTTP 500 (404 for an
  unknown method) and the error object in the body, so that client would turn "min
  relay fee not met (-26)" into "Internal Server Error". The adapter drives chronos's
  `HttpSessionRef` / `HttpClientRequestRef` itself and reads the body whatever the
  status.
- **One call can legitimately run for minutes.** `scantxoutset` reads every coin in
  the node's UTXO set, over 10^8 on mainnet; Core gives it a `status` action that
  reports progress. A regtest node answers at once. It gets `ScanBudget`
  (5 min, a judgment, not a measurement), and two of chronos's own timers had to move with it: the
  session's headers timeout (120 s by default) is set past the budget, or chronos
  would end the scan first; the connect stays within a read's budget, or an address
  that drops SYNs would hold the module thread for the whole scan budget, longer than
  the kernel's timeout this fixes. Past the budget the node's scan keeps running, and
  the node refuses a retry until it ends ("Scan already in progress"). Muster does not
  send `abort`: it stops the node's one running scan, whichever client started it.

The test's fourth endpoint is an address that drops SYNs: a listener that never
accepts, its accept queue (backlog 0) filled by one connection. Linux drops every
later SYN, so the client's connect hangs exactly as it does against a firewalled
host. The test checks that premise before it relies on it.
