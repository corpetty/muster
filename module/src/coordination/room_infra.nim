## The room's infrastructure, as the drivers dictate it (exo-428).
##
## A room depends on nothing outside itself until a proposal says so. The room's own
## baseline is the delivery node its encrypted transport rides (and the store node that
## sees its metadata, FS-9) — that is the conversation, not any driver. Everything else
## — an RPC endpoint, a chain to settle on, a funded zone account — is INTRODUCED by a
## proposal whose driver declares it in its manifest (drivers/manifest.nim). So a room
## that only decides or talks never touches an RPC; the first Safe proposal on the log
## brings the RPC (and the chain it must serve) into view, naming itself as the reason.
##
## A pure fold over the log (invariant 4): every instance with the same event set shows
## the same needs, in canonical order, however they arrived. Only the instance's OWN
## prerequisites are folded (party = instance): what THIS client must reach. A driver
## that has not declared its manifest yields an `undeclared` need — shown, never guessed.

import std/[tables, strutils]
import ../log/log
import ../drivers/driver
import ../drivers/manifest
import ./intents
export manifest

type
  Introducer* = tuple[intentId, policy: string]

  InfraNeed* = object
    declared*: bool               ## false = a proposal's driver has not declared its manifest
    requirement*: Requirement     ## the infra/environment prerequisite (unset when undeclared)
    introducedBy*: seq[Introducer] ## the proposals that brought it in, canonical order

proc needKey(n: InfraNeed): string =
  if not n.declared: "undeclared" else: $n.requirement.kind & ":" & n.requirement.name

proc proposedIntents(events: seq[Event]): seq[string] =
  ## Every proposed intent id, once, in canonical log order.
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len >= 3 and p[0] == "intent" and p[2] == "propose" and p[1] notin result:
      result.add p[1]

proc roomInfraNeeds*(events: seq[Event], driverFor: DriverFor): seq[InfraNeed] =
  ## The infrastructure the room's proposals require of THIS instance: the union of
  ## every proposed intent's instance-party infra + environment requirements, deduped by
  ## (kind, name), each naming the proposals that introduced it. Empty for a room with
  ## no proposals — the room itself needs only its transport, which the caller shows.
  var at = initTable[string, int]()
  for id in proposedIntents(events):
    let policy = intentPolicyOf(events, id)
    let m = driverFor(policy).manifest(effectFromJson(effectJsonOf(events, id)))
    var found: seq[InfraNeed]
    if not m.declared:
      found.add InfraNeed(declared: false)
    else:
      for r in m.requirements:
        if r.kind in {rqInfra, rqEnvironment} and r.party == rpInstance:
          found.add InfraNeed(declared: true, requirement: r)
    for n in found:
      let k = n.needKey
      if k notin at:
        at[k] = result.len
        result.add n
      let who: Introducer = (id, policy)
      if who notin result[at[k]].introducedBy:
        result[at[k]].introducedBy.add who

proc introducedObservers*(events: seq[Event], driverFor: DriverFor): seq[Observer] =
  ## The outside observers the room's proposals name in their declared disclosure —
  ## who COULD see something once those proposals settle. The room member and the
  ## store node are the baseline and are not listed here; an RPC provider or a chain
  ## observer appears only once a proposal whose driver discloses to it is on the log.
  for id in proposedIntents(events):
    let m = driverFor(intentPolicyOf(events, id)).manifest(effectFromJson(effectJsonOf(events, id)))
    if not m.declared:
      # an undeclared driver may disclose to anyone; the chain observer is where the
      # flow view already files its `undeclared` row, so it must stay visible.
      if obChainObserver notin result: result.add obChainObserver
      continue
    for d in m.discloses:
      if d.to notin {obRoomMember, obStoreNode} and d.to notin result:
        result.add d.to
