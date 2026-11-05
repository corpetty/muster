## Content-addressed, hash-linked log and its reducer (spec:
## contracts/specs/derived-exo-548.spec.json, invariant 4).
##
## An Event carries no signature of its own: in the room, the session seals each one
## under the membership epoch key (coordination/session.nim), which proves a member
## sent it but not which one. The kinds that name their author (message, decline,
## material share, account disclosure, FROST join) carry that author's signature in
## their value, and the room reads only those that verify (coordination/authorship.nim,
## exo-f76). This log stays kind-agnostic: it keeps whatever it received.
##
## State is always reduce(log): a pure, deterministic function of the event set.
## Events are content-addressed (their id is the digest of a domain-separated
## hash-input record — ties to invariants 5/449), so a duplicate is the same id
## and folds once. Ordering is causal (an event follows its parents) with a
## deterministic tiebreak (smallest event id), so any delivery order or
## duplication of the same event set reduces to identical state. Nothing lives
## outside the log: cold-start replay reproduces incrementally-maintained state.
##
## P0 payload is a last-write-wins key/value set; the reducer framework is what
## the invariant is about, and richer event types slot into `applyEvent` at P1.
##
## Causal order (exo-655, docs/design/causal-parents.md): `parents` is LINEAGE — what an
## entry's meaning depends on, checked by the code that guards invariants 1, 2 and 10.
## `after` is ORDER — the heads the publisher had seen. It is outside the id and nothing
## that reduces state reads it: canonicalOrder and every fold use `parents` alone.
## `causalOrder` reads both, for views only. Copies of one event may carry different
## `after`; the one whose sorted `after` has the smallest digest is kept, so the choice
## is a function of the copies held, never of their arrival order.

import std/[algorithm, tables, sets, sequtils, heapqueue]
import ../dcbor/dcbor
import ../hashing/hash_input

type
  EventId* = string   ## hex of the event's content digest

  Event* = object
    parents*: seq[EventId]   ## lineage: hash-links to the events this one's meaning depends on
    key*: string
    value*: string
    after*: seq[EventId]     ## order: the heads the publisher had seen; NOT in the id, never read by a fold
    afterSig*: string        ## an author-bearing event's author's signature over `after` (C5,
                             ## authorship.afterVerified); outside the id like `after`

  State* = object
    entries*: Table[string, string]

proc eventIdUncached*(e: Event): EventId =
  ## The digest itself, never memoized (what eventId caches).
  var ps = e.parents
  sort(ps)
  var parentsArr: seq[CborValue]
  for p in ps: parentsArr.add cbText(p)
  toHex(digest(hashInput("muster.event.v1", @[
    ("parents", cbArray(parentsArr)),
    ("key", cbText(e.key)),
    ("value", cbText(e.value)),
  ])))

var idMemo {.threadvar.}: Table[string, EventId]
  ## eventId is a pure function of (parents, key, value), and folds recompute it for the
  ## same events many times over (a room's views fold the whole log once per intent). A
  ## per-thread memo keyed by the exact inputs returns the identical id without the
  ## dCBOR encode + SHA-256 (G7). Bounded: cleared past MaxIdMemo entries.
const MaxIdMemo = 50_000

proc eventId*(e: Event): EventId =
  ## Content address: the digest of a domain-separated record over the event's
  ## parents (order-normalised) and payload. Identical events share an id.
  # length-prefixed, so no two different inputs share a key
  var memoKey = newStringOfCap(e.key.len + e.value.len + 70 * e.parents.len + 32)
  memoKey.add $e.parents.len; memoKey.add ':'
  for p in e.parents: (memoKey.add $p.len; memoKey.add ':'; memoKey.add p)
  memoKey.add $e.key.len; memoKey.add ':'; memoKey.add e.key
  memoKey.add $e.value.len; memoKey.add ':'; memoKey.add e.value
  if memoKey in idMemo: return idMemo[memoKey]
  result = eventIdUncached(e)
  if idMemo.len >= MaxIdMemo: idMemo.clear()
  idMemo[memoKey] = result

proc afterDigest*(e: Event): string =
  ## What picks the kept copy among copies of one event: the digest of its sorted `after`.
  var a = e.after
  sort(a)
  var arr: seq[CborValue]
  for x in a: arr.add cbText(x)
  toHex(digest(hashInput("muster.event.after.v1", @[("after", cbArray(arr))])))

proc keep*(a, b: Event): Event =
  ## Of two copies of the same event, the one the log keeps (smallest afterDigest).
  if afterDigest(b) < afterDigest(a): b else: a

proc canonicalOrder*(events: seq[Event]): seq[Event] =
  ## Deduplicated topological order: an event follows all of its present
  ## parents; among ready events the smallest id goes first. A pure function of
  ## the event SET — independent of the order events were supplied in.
  var byId = initTable[EventId, Event]()
  for e in events:
    let id = eventId(e)    # dedup: same id is the same content; of its copies keep one by `after`
    byId[id] = (if id in byId: keep(byId[id], e) else: e)

  var present = initHashSet[EventId]()
  for id in byId.keys: present.incl id

  var indeg = initTable[EventId, int]()
  var children = initTable[EventId, seq[EventId]]()
  for id in byId.keys:
    indeg[id] = 0
    children[id] = @[]
  for id, e in byId:
    for p in e.parents:
      if p in present:
        indeg[id] = indeg[id] + 1
        children[p].add id

  # deterministic tiebreak: smallest ready id first, from a min-heap — the same order a
  # re-sort of the ready list each step gives, in n log n instead of n² log n when most
  # events are roots (exo-53d)
  var ready = initHeapQueue[EventId]()
  for id in byId.keys:
    if indeg[id] == 0: ready.push id

  result = @[]
  while ready.len > 0:
    let id = ready.pop()
    result.add byId[id]
    for c in children[id]:
      indeg[c] = indeg[c] - 1
      if indeg[c] == 0: ready.push c

proc causalOrder*(events: seq[Event]): seq[Event] =
  ## The order views replay: topological over `parents` (hard edges, acyclic by
  ## construction — a parent's id exists before its child) and `after` (soft edges),
  ## ties by smallest id. A soft edge that would close a cycle is skipped; soft edges are
  ## tried in a fixed order (child id, then target id), so the result is a function of the
  ## event set. Every event is emitted. For views only: no fold reads this.
  var byId = initTable[EventId, Event]()
  for e in events:
    let id = eventId(e)
    byId[id] = (if id in byId: keep(byId[id], e) else: e)
  var children = initTable[EventId, seq[EventId]]()
  var indeg = initTable[EventId, int]()
  for id in byId.keys: (children[id] = @[]; indeg[id] = 0)
  proc addEdge(frm, to: EventId) =
    children[frm].add to
    indeg[to] = indeg[to] + 1
  for id, e in byId:
    for p in e.parents:
      if p in byId and p != id: addEdge(p, id)
  proc reaches(src, dst: EventId): bool =
    ## is `dst` reachable from `src` along the edges added so far?
    var stack = @[src]
    var seen = initHashSet[EventId]()
    while stack.len > 0:
      let n = stack.pop()
      if n == dst: return true
      if n in seen: continue
      seen.incl n
      for c in children[n]: stack.add c
    false
  var soft: seq[(EventId, EventId)]   # (child, target): the child follows the target
  for id, e in byId:
    for a in e.after:
      if a in byId and a != id: soft.add (id, a)
  soft.sort()
  for (child, target) in soft:
    if child in children[target]: continue      # already ordered that way
    if not reaches(child, target): addEdge(target, child)
  var ready = initHeapQueue[EventId]()
  for id in byId.keys:
    if indeg[id] == 0: ready.push id
  while ready.len > 0:
    let id = ready.pop()
    result.add byId[id]
    for c in children[id]:
      indeg[c] = indeg[c] - 1
      if indeg[c] == 0: ready.push c

proc applyEvent(s: var State, e: Event) =
  ## The P0 reducer step: last-write-wins on a key. Idempotent by construction —
  ## applying the same (key, value) twice lands the same value.
  s.entries[e.key] = e.value

proc reduce*(events: seq[Event]): State =
  result.entries = initTable[string, string]()
  for e in canonicalOrder(events):
    applyEvent(result, e)

proc stateDigest*(s: State): string =
  ## Canonical hash of state. The dCBOR map sorts keys, so the digest is a pure
  ## function of state content — two clients converge iff their digests match.
  var pairs: seq[(CborValue, CborValue)]
  for k, v in s.entries:
    pairs.add (cbText(k), cbText(v))
  toHex(digest(hashInput("muster.state.v1", @[("entries", cbMap(pairs))])))

# ── A minimal in-memory log: a deduplicated event set with incremental ingest ─
type Log* = object
  events: OrderedTable[EventId, Event]
  variants: Table[EventId, seq[Event]]   ## every distinct (after, afterSig) copy of an id, up to MaxVariants

const MaxVariants* = 64
  ## Copies of one event kept beside the chosen one, so the room's authentic view can pick
  ## the copy whose `after` its author signed (exo-dde.15) — the log itself cannot tell.

proc ingest*(log: var Log, e: Event) =
  ## At-least-once safe: re-ingesting an event (same id) is a no-op.
  ## A copy of a held event replaces it only when it is the one `keep` chooses, so the
  ## log ends up holding the same copy whatever order the copies arrive in.
  let id = eventId(e)
  var vs = log.variants.getOrDefault(id)
  var known = false
  for v in vs: (if v.after == e.after and v.afterSig == e.afterSig: known = true)
  if not known and vs.len < MaxVariants:
    vs.add e
    log.variants[id] = vs
  if id notin log.events:
    log.events[id] = e
  elif e.after != log.events[id].after:
    log.events[id] = keep(log.events[id], e)

proc find*(log: Log, id: EventId): tuple[found: bool, event: Event] =
  ## The copy the log holds under `id`, if any.
  if id in log.events: (true, log.events[id]) else: (false, Event())

proc variantsOf*(log: Log, id: EventId): seq[Event] =
  ## Every copy of `id` the log holds, each distinct (after, afterSig) in the order first
  ## seen, up to MaxVariants; none when it holds no such event.
  if id notin log.events: return
  let vs = log.variants.getOrDefault(id)
  if vs.len == 0: @[log.events[id]] else: vs

const MaxHeads* = 8   ## at most this many ids in a new event's `after`

proc heads*(log: Log): seq[EventId] =
  ## The events no other held event names, through `parents` or `after`: what a new
  ## event follows (docs/design/causal-parents.md §3.2). Sorted. Past MaxHeads (rare: a
  ## room is rarely that concurrent), the MaxHeads latest in causal order.
  var named = initHashSet[EventId]()
  for e in log.events.values:
    for p in e.parents: named.incl p
    for a in e.after: named.incl a
  for id in log.events.keys:
    if id notin named: result.add id
  if result.len > MaxHeads:
    let tips = result.toHashSet()
    var latest: seq[EventId]
    let order = causalOrder(toSeq(log.events.values))
    for i in countdown(order.len - 1, 0):
      let id = eventId(order[i])
      if id in tips: latest.add id
      if latest.len == MaxHeads: break
    result = latest
  result.sort()

proc allVariants*(log: Log): seq[Event] =
  ## Every copy the log holds, all variants of each id (the authentic view chooses among
  ## them; every fold dedups by id).
  for id in log.events.keys:
    let vs = log.variants.getOrDefault(id)
    if vs.len == 0: result.add log.events[id] else: result.add vs

proc allEvents*(log: Log): seq[Event] =
  for e in log.events.values: result.add e

proc state*(log: Log): State =
  ## State is reduce(log) — recomputed from the persisted set, never a shadow
  ## copy that could drift from it.
  reduce(log.allEvents())
