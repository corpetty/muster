## Signed hash-linked log and its reducer (spec:
## contracts/specs/derived-exo-548.spec.json, invariant 4).
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

import std/[algorithm, tables, sets]
import ../dcbor/dcbor
import ../hashing/hash_input

type
  EventId* = string   ## hex of the event's content digest

  Event* = object
    parents*: seq[EventId]   ## causal refs (hash-links to prior events)
    key*: string
    value*: string

  State* = object
    entries*: Table[string, string]

proc eventId*(e: Event): EventId =
  ## Content address: the digest of a domain-separated record over the event's
  ## parents (order-normalised) and payload. Identical events share an id.
  var ps = e.parents
  sort(ps)
  var parentsArr: seq[CborValue]
  for p in ps: parentsArr.add cbText(p)
  toHex(digest(hashInput("muster.event.v1", @[
    ("parents", cbArray(parentsArr)),
    ("key", cbText(e.key)),
    ("value", cbText(e.value)),
  ])))

proc canonicalOrder*(events: seq[Event]): seq[Event] =
  ## Deduplicated topological order: an event follows all of its present
  ## parents; among ready events the smallest id goes first. A pure function of
  ## the event SET — independent of the order events were supplied in.
  var byId = initTable[EventId, Event]()
  for e in events:
    byId[eventId(e)] = e   # dedup: same id overwrites with identical content

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

  var ready: seq[EventId]
  for id in byId.keys:
    if indeg[id] == 0: ready.add id

  result = @[]
  while ready.len > 0:
    sort(ready)                 # deterministic tiebreak: smallest id first
    let id = ready[0]
    ready.delete(0)
    result.add byId[id]
    var unblocked = children[id]
    sort(unblocked)
    for c in unblocked:
      indeg[c] = indeg[c] - 1
      if indeg[c] == 0: ready.add c

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

proc ingest*(log: var Log, e: Event) =
  ## At-least-once safe: re-ingesting an event (same id) is a no-op.
  let id = eventId(e)
  if id notin log.events:
    log.events[id] = e

proc allEvents*(log: Log): seq[Event] =
  for e in log.events.values: result.add e

proc state*(log: Log): State =
  ## State is reduce(log) — recomputed from the persisted set, never a shadow
  ## copy that could drift from it.
  reduce(log.allEvents())
