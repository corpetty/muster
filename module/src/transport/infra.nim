## Untrusted, user-configurable infrastructure (spec:
## contracts/specs/derived-exo-8dc.spec.json, invariant 8, catastrophic).
##
## No server holds application state, and the client phones nothing home. Its full
## state is reduce(local log + keys), so it cold-starts with every store node and
## RPC endpoint unreachable. Every destination it will contact is enumerable and
## user-visible before any traffic; every entry — defaults included — is
## replaceable; nothing a remote returns is trusted (each datum is verified
## locally before it can change state); on no path, including error and crash, does
## it originate a request outside the visible list; and updates never fetch
## automatically.

import ../log/log
export log.Event, log.reduce, log.stateDigest

type
  Endpoint* = object
    id*: string
    isDefault*: bool

  Config* = object
    endpoints*: seq[Endpoint]     ## the visible list of stores + RPC
    updateFeedEnabled*: bool      ## the default-OFF signed update feed

  Path* = enum
    pStartup, pFetch, pPublish, pError, pCrash, pShutdown, pIdle

proc newConfig*(ids: seq[string], defaults: seq[bool] = @[]): Config =
  for i, id in ids:
    result.endpoints.add Endpoint(id: id, isDefault: i < defaults.len and defaults[i])
  result.updateFeedEnabled = false   # phone-home / update feed is off by default

proc visibleList*(cfg: Config): seq[string] =
  for e in cfg.endpoints: result.add e.id

proc dialsOnPath*(cfg: Config, path: Path): seq[string] =
  ## Every outbound dial is drawn ONLY from the visible endpoint list. Startup,
  ## error, crash and shutdown paths dial nothing — in particular no analytics,
  ## crash-reporting, or beacon destination exists to dial.
  case path
  of pFetch, pPublish, pIdle: cfg.visibleList()
  else: @[]

proc localState*(events: seq[Event]): string =
  ## State is reduce(local log). Endpoint reachability is irrelevant — the client
  ## reads only its own log, so a fully-offline cold start reconstructs it.
  stateDigest(reduce(events))

proc acceptFromNode*(verifiedLocally: bool): bool =
  ## A remote datum changes state only after local verification (signature,
  ## hash-link, re-derivation). Unverified input is never accepted on the node's
  ## authority — a lying or omitting node costs availability, never integrity.
  verifiedLocally

proc wouldFetchUpdate*(cfg: Config, signedFeed: bool): bool =
  ## An update is fetched only when the default-off feed is explicitly enabled AND
  ## the feed is signed. Never automatic.
  cfg.updateFeedEnabled and signedFeed
