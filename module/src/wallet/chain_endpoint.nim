## Where an EVM JSON-RPC call goes (exo-d4d.3, R2; docs/design/real-use-basecamp.md §5.3).
##
## An endpoint is a string, as it always was, in one of two forms:
##   * a URL (`http://…`, `https://…`): muster calls it itself (rpc_budget.jsonRpc). The
##     standalone runner, anvil and the chain-bound tests use this;
##   * `logos:eth_rpc_module/<chainId>`: the call goes over lp_* to the platform's
##     eth_rpc_module, which holds the person's chains and endpoints device-wide (invariant 8:
##     still theirs, set once in eth_rpc_ui; Tor and verified reads included). Muster never
##     sees the URL.
##
## Keeping the string means every caller that took a URL takes either form unchanged; which
## one a call gets is decided where the endpoint is chosen, per chain.
##
## eth_rpc_module answers every read with {ok:true, result, route} or {ok:false, error}.
## `route` is how the answer was obtained: "verified" (proof-backed by the light client),
## "proxied" (through the proxy, on trust) or "direct". A URL's answers are "direct".
##
## This file is pure: the lp_* half is a hook the plugin installs (nim-lib/eth_rpc_client.nim),
## so tests stand a fake eth_rpc_module behind it.

import std/[json, strutils]
import ./rpc_budget

const PlatformPrefix* = "logos:eth_rpc_module/"

type
  EndpointKind* = enum ekDirect, ekPlatform
  ChainEndpoint* = object
    case kind*: EndpointKind
    of ekDirect: url*: string
    of ekPlatform: chainId*: int
  PlatformRpc* = proc(chainId: int, meth: string, params: JsonNode, budgetMs: int): JsonNode {.nimcall, gcsafe.}
    ## eth_rpc_module's envelope for one JSON-RPC call, or nil when it did not answer.
  RoutedResult* = tuple[result: JsonNode, route: string]

var platformRpc: PlatformRpc   # set once at load; called on the module's dispatch thread

proc setPlatformRpc*(f: PlatformRpc) =
  ## The plugin installs the lp_* call at load; tests install a fake. nil removes it.
  platformRpc = f

proc platformEndpoint*(chainId: int): string = PlatformPrefix & $chainId

proc isPlatform*(endpoint: string): bool = endpoint.startsWith(PlatformPrefix)

proc parseEndpoint*(endpoint: string): ChainEndpoint =
  ## A URL is direct; the platform form names a chain. Anything else raises: an endpoint
  ## muster cannot place is never guessed at.
  if endpoint.isPlatform:
    let rest = endpoint[PlatformPrefix.len .. ^1]
    var id = -1
    if rest.len > 0 and rest.allCharsInSet(Digits):
      try: id = parseInt(rest)
      except ValueError: discard
    if id <= 0: raise newException(RpcError, "not a chain id in endpoint " & endpoint)
    return ChainEndpoint(kind: ekPlatform, chainId: id)
  if endpoint.startsWith("http://") or endpoint.startsWith("https://"):
    return ChainEndpoint(kind: ekDirect, url: endpoint)
  raise newException(RpcError, "not an RPC endpoint (a URL or " & PlatformPrefix & "<chainId>)")

proc envelopeResult*(env: JsonNode, meth: string): RoutedResult =
  ## The result inside eth_rpc_module's envelope. No envelope, `ok:false`, or no `result`
  ## raises RpcError naming the call: a failed read never reads as a value.
  if env == nil or env.kind != JObject:
    raise newException(RpcError, meth & ": eth_rpc_module did not answer")
  if not env{"ok"}.getBool(false):
    raise newException(RpcError, meth & ": " & env{"error"}.getStr("eth_rpc_module refused"))
  if not env.hasKey("result"):
    raise newException(RpcError, meth & ": eth_rpc_module answered no result")
  (env["result"], env{"route"}.getStr("direct"))

proc chainRpc*(endpoint, meth: string, params: JsonNode, budget: Duration, send = false): RoutedResult =
  ## One JSON-RPC call to `endpoint` within `budget` → its result (JNull when the chain
  ## answered null; whether null is an answer is the caller's to say) and its route.
  let ep = parseEndpoint(endpoint)
  case ep.kind
  of ekDirect:
    (jsonRpc(ep.url, meth, params, budget, send), "direct")   # send: past rpc_budget's cooling
  of ekPlatform:
    if platformRpc == nil:
      raise newException(RpcError, meth & ": eth_rpc_module is not reachable from this host")
    envelopeResult(platformRpc(ep.chainId, meth, params, int(budget.milliseconds)), meth)

# ── the person's chain registry, as eth_rpc_module holds it ─────────────────────
type PlatformChain* = object
  chainId*: int
  name*: string
  testnet*, enabled*, inScope*: bool

proc parseChainConfigs*(r: JsonNode): tuple[ok: bool, scope: string, chains: seq[PlatformChain]] =
  ## list_chain_configs' reply (rpc.rs @42cc465): {ok, scope, chains: [{chainId, inScope,
  ## name?, testnet?, enabled?, …}]}, mainnets first. inScope is eth_rpc_module's own verdict
  ## against the person's device-wide scope ("mainnets" | "testnets" | "both").
  if r == nil or not r{"ok"}.getBool(false): return (false, "", @[])
  result.ok = true
  result.scope = r{"scope"}.getStr("")
  for c in r{"chains"}.getElems():
    let id = c{"chainId"}.getInt(-1)
    if id <= 0: continue
    result.chains.add PlatformChain(chainId: id, name: c{"name"}.getStr(""),
      testnet: c{"testnet"}.getBool(false), enabled: c{"enabled"}.getBool(true),
      inScope: c{"inScope"}.getBool(false))

proc offered*(c: PlatformChain): bool =
  ## A chain muster offers: enabled, and shown by the person's scope.
  c.enabled and c.inScope
