## Disclosure rows — what an action reveals, and to whom (design:
## docs/design/action-manifest.md, epic exo-002).
##
## An observer is a CLASS of party that can see something about a room action.
## The room member is inside the boundary; everything else is outside it. A
## DisclosureRow says one named piece of the action is visible to one observer
## class. The baseline rows are added by the core for every action — the effect
## and contributions to the room, the timing and topic to the store node — so no
## driver manifest can omit the observer who sees the most (FS-9: name the store
## node, never let "untrusted infrastructure" stand in for "blind infrastructure").
##
## This lives under intents/ (not drivers/) so the wallet layer can map its own
## disclosure (the LEZ rails) onto the same rows without importing the driver seam.

type
  Observer* = enum
    obRoomMember    = "room-member"     ## inside the conversation boundary
    obStoreNode     = "store-node"      ## the delivery/store infrastructure (metadata, FS-9)
    obRpcProvider   = "rpc-provider"    ## the user-configured RPC (sees a signed tx before the mempool)
    obChainObserver = "chain-observer"  ## anyone reading the public ledger
    obTargetModule  = "target-module"   ## the Logos module an invoke driver calls

  DisclosureRow* = object
    field*: string   ## what: "effect", "amount", "payer", "payee", "args", "timing", "topic"…
    to*: Observer

proc row*(field: string, to: Observer): DisclosureRow =
  DisclosureRow(field: field, to: to)

proc baselineDisclosure*(): seq[DisclosureRow] =
  ## What EVERY room action discloses regardless of driver. Added by the core.
  @[row("effect", obRoomMember),
    row("contributions", obRoomMember),
    row("timing", obStoreNode),
    row("topic", obStoreNode)]

proc visibleTo*(rows: seq[DisclosureRow], o: Observer): seq[string] =
  ## The fields one observer class can see — the per-observer column of the matrix.
  for r in rows:
    if r.to == o: result.add r.field

proc outsideBoundary*(rows: seq[DisclosureRow]): seq[DisclosureRow] =
  ## Everything that leaves the room — the part the card must show as "what will happen".
  for r in rows:
    if r.to != obRoomMember: result.add r
