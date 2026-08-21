## InboundQueue — the foreign-thread seam for the delivery callback.
##
## delivery_module invokes our `messageReceived` callback on ITS thread, which
## Nim's GC does not own. Allocating GC memory there (parseJson, seq) risks
## corruption / use-after-free. So the callback does the minimum — copy the raw
## event bytes into malloc'd memory and enqueue under a lock, no Nim GC — and the
## module's own thread later `drain`s the queue and does the GC-bearing work
## (parse, decrypt, dispatch) safely. This is the storage-nim async-callback
## pattern (the `abandoned`-flag seam), reduced to what Muster needs.
##
## Pure Nim, no FFI, so it is unit-tested directly.

import std/locks

type
  RawNode = ptr RawNodeObj
  RawNodeObj = object
    data: pointer      # malloc'd copy of the raw event bytes (untraced)
    len: int
    next: RawNode

  InboundQueue* = object
    lock: Lock
    head: RawNode      # LIFO push; drain reverses to FIFO

proc initInboundQueue*(q: var InboundQueue) =
  ## In-place: a Lock must not be copied by value, so callers hold the queue as a
  ## field/var and init it here.
  initLock(q.lock)
  q.head = nil

proc enqueue*(q: var InboundQueue, data: openArray[byte]) {.gcsafe.} =
  ## Called from the foreign (delivery) thread. Uses only `alloc`/`copyMem` (the
  ## untraced allocator) + the lock — never Nim GC — so it is safe on a thread the
  ## Nim runtime does not manage.
  let node = cast[RawNode](alloc0(sizeof(RawNodeObj)))
  node.len = data.len
  if data.len > 0:
    node.data = alloc(data.len)
    copyMem(node.data, unsafeAddr data[0], data.len)
  acquire(q.lock)
  node.next = q.head
  q.head = node
  release(q.lock)

proc enqueue*(q: var InboundQueue, data: cstring) {.gcsafe.} =
  ## Convenience for the FFI callback: copies `data` up to its NUL terminator
  ## (strlen, no Nim GC). The event JSON delivery hands us is a cstring.
  if data == nil: return
  let n = data.len
  let node = cast[RawNode](alloc0(sizeof(RawNodeObj)))
  node.len = n
  if n > 0:
    node.data = alloc(n)
    copyMem(node.data, data, n)
  acquire(q.lock)
  node.next = q.head
  q.head = node
  release(q.lock)

proc drain*(q: var InboundQueue): seq[seq[byte]] =
  ## Called from the module's own (Nim) thread. Detaches the pending nodes under
  ## the lock, converts each to a GC seq (safe here), and frees the malloc'd
  ## memory. Returns messages oldest-first.
  acquire(q.lock)
  var n = q.head
  q.head = nil
  release(q.lock)
  var newestFirst: seq[seq[byte]]
  while n != nil:
    var b = newSeq[byte](n.len)
    if n.len > 0: copyMem(addr b[0], n.data, n.len)
    newestFirst.add b
    let nxt = n.next
    if n.data != nil: dealloc(n.data)
    dealloc(n)
    n = nxt
  for i in countdown(newestFirst.high, 0): result.add newestFirst[i]

proc close*(q: var InboundQueue) =
  ## Free anything still queued and release the lock.
  var n = q.head
  while n != nil:
    let nxt = n.next
    if n.data != nil: dealloc(n.data)
    dealloc(n)
    n = nxt
  q.head = nil
  deinitLock(q.lock)
