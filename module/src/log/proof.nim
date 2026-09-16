## Log proofs — an exportable, self-verifying slice of the coordination log
## (docs/design/action-manifest.md §4 want 1 / M4, epic exo-002; extends invariant 4
## and the F-20 provenance rung, exo-1ec.5).
##
## A proof is the event set itself in canonical order plus what a verifier needs to
## refuse a tampered one: every event's claimed content id (recomputed on verify —
## invariant 5, deterministic bytes), the requirement that every parent an event
## names is IN the proof (a parent-closed sub-DAG, so nothing can be silently
## dropped from the middle of a chain), the canonical order (so the slice can't be
## re-sequenced), and the state digest reduce(events) must reach. The proof also
## carries the membership epochs it spans: whoever holds those epoch keys can open
## the events and check it; nobody else can read it, let alone forge it (inv 7).
## A proof proves the log; it says nothing about the world (chain results are
## external reads and stay graded as such in the provenance fold).

import std/[algorithm, json]
import ../dcbor/dcbor
import ../hashing/hash_input
import ./log
export log

type
  LogProof* = object
    events*: seq[Event]     ## canonical order
    ids*: seq[EventId]      ## the claimed content id of each event, same order
    digest*: string         ## stateDigest(reduce(events))
    epochFrom*, epochTo*: int  ## the membership epochs the slice spans (inv 7 scoping)

proc buildProof*(events: seq[Event], epochFrom = 0, epochTo = 0): LogProof =
  ## Pure function of the event SET: any supply order or duplication yields the
  ## identical proof (invariant 4).
  result.events = canonicalOrder(events)
  for e in result.events: result.ids.add eventId(e)
  result.digest = stateDigest(reduce(result.events))
  result.epochFrom = epochFrom
  result.epochTo = epochTo

proc proofDigest*(p: LogProof): string =
  ## A content address for the whole proof (domain-separated, inv 5) — what a
  ## receipt or a later proof can cite.
  var ids: seq[CborValue]
  for id in p.ids: ids.add cbText(id)
  toHex(digest(hashInput("muster.log-proof.v1", @[
    ("ids", cbArray(ids)), ("digest", cbText(p.digest)),
    ("epochFrom", cbUint(uint64(max(0, p.epochFrom)))),
    ("epochTo", cbUint(uint64(max(0, p.epochTo))))])))

proc verifyProof*(p: LogProof): tuple[ok: bool, reason: string] =
  ## Refuse-on-mismatch. Recompute everything the proof claims; the first
  ## discrepancy names itself.
  if p.events.len != p.ids.len:
    return (false, "ids/events length mismatch")
  var present: seq[EventId]
  for i, e in p.events:
    let id = eventId(e)
    if id != p.ids[i]:
      return (false, "event " & $i & " content does not match its claimed id")
    present.add id
  present.sort()
  for i, e in p.events:
    for parent in e.parents:
      if binarySearch(present, parent) < 0:
        return (false, "event " & $i & " names a parent outside the proof — the slice is not parent-closed")
  let ordered = canonicalOrder(p.events)
  for i in 0 ..< ordered.len:
    if eventId(ordered[i]) != p.ids[i]:
      return (false, "events are not in canonical order")
  if stateDigest(reduce(p.events)) != p.digest:
    return (false, "state digest does not match reduce(events)")
  if p.epochFrom > p.epochTo:
    return (false, "epoch range is inverted")
  (true, "")

proc toJson*(p: LogProof): JsonNode =
  var evs = newJArray()
  for e in p.events:
    var ps = newJArray()
    for x in e.parents: ps.add %x
    evs.add %*{"parents": ps, "key": e.key, "value": e.value}
  var ids = newJArray()
  for id in p.ids: ids.add %id
  %*{"format": "muster.log-proof.v1", "events": evs, "ids": ids, "digest": p.digest,
     "epochFrom": p.epochFrom, "epochTo": p.epochTo, "proofDigest": p.proofDigest()}

proc proofFromJson*(j: JsonNode): LogProof =
  ## Strict: unknown shape raises (a proof that cannot be parsed is not a proof).
  if j.kind != JObject or j{"format"}.getStr() != "muster.log-proof.v1":
    raise newException(ValueError, "not a muster.log-proof.v1")
  for e in j["events"]:
    var ev = Event(key: e["key"].getStr(), value: e["value"].getStr())
    for x in e["parents"]: ev.parents.add x.getStr()
    result.events.add ev
  for id in j["ids"]: result.ids.add id.getStr()
  result.digest = j["digest"].getStr()
  result.epochFrom = j{"epochFrom"}.getInt()
  result.epochTo = j{"epochTo"}.getInt()
