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
