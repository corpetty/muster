## The platform half of wallet/chain_endpoint.nim (exo-d4d.3, R2): eth_rpc_module over lp_*.
## Not pure, so like keystore_probe.nim it is compiled only into the plugin.
##
## Each chain read is one synchronous lp_invoke of eth_rpc_module.raw_rpc, bounded by the
## caller's budget plus a margin for the hop: the same blocking shape as the URL path's
## waitFor on the module thread (wallet/rpc_budget.nim), with the same rule that no call waits
## without a budget. eth_rpc_module is `concurrency: multi`, so a slow chain does not queue
## another app's read behind ours.
##
## Muster reads the person's chain registry and never writes it (invariant 8: the endpoints
## are theirs, set in eth_rpc_ui). The one exception is init_defaults, which the platform asks
## every consumer to call and which writes only what is absent.

import std/json
import logos_sdk/ffi
import ./chain_endpoint
import ./keystore_status   # ksReply: an lp reply however it arrives (object, string, envelope)

const
  EthRpcModule* = "eth_rpc_module"
  Ours = "muster_module"
  HopMarginMs = 2_000      ## the lp hop and eth_rpc_module's own work, on top of the read's budget
  RegistryMs = 3_000.cint  ## a registry read: no network, local to eth_rpc_module

var client: ptr LpClient

proc reached(): bool =
  ## Created on first use with our name as origin, so eth_rpc_module sees muster_module.
  if client == nil:
    client = lp_client_create(EthRpcModule.cstring, Ours.cstring, nil, nil)
  client != nil

proc invoke(meth: string, args: JsonNode, timeoutMs: cint): JsonNode =
  ## eth_rpc_module's reply as JSON, or nil when it did not answer.
  if not reached(): return nil
  var res, err: cstring
  let rc = lp_invoke(client, meth.cstring, ($args).cstring, timeoutMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil: return nil
  ksReply($res)

proc lpPlatformRpc(chainId: int, meth: string, params: JsonNode, budgetMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    invoke("raw_rpc", %*[chainId, meth, $params], cint(budgetMs + HopMarginMs))

proc installEthRpc*() =
  ## Route `logos:eth_rpc_module/<id>` endpoints through eth_rpc_module.
  setPlatformRpc(lpPlatformRpc)

proc ethRpcInitDefaults*(): bool =
  ## The platform's rule: any consumer calls it at start; it seeds only what is absent.
  let r = invoke("init_defaults", newJArray(), RegistryMs)
  r != nil and r{"ok"}.getBool(false)

proc ethRpcChains*(): tuple[ok: bool, scope: string, chains: seq[PlatformChain]] =
  ## The person's chain registry as eth_rpc_module holds it. ok = false when it did not answer.
  parseChainConfigs(invoke("list_chain_configs", newJArray(), RegistryMs))
