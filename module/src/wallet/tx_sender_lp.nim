## The platform half of wallet/tx_sender.nim (exo-d4d.5, R4): tx_sender_module over lp_*.
## Not pure, so like keystore_probe.nim it is compiled only into the plugin.
##
## prepare and send are synchronous calls on the module thread with tx_sender's own budgets
## (prepare 18 s, send → keystore 5 s): the same blocking shape as a payment muster signed
## itself. send_status is polled by the split pump; each poll is bounded too. tx_sender_module
## records the runtime-attested caller on every send, so the person sees "[asked by
## muster_module]" beneath the purpose; that needs origin = our module name.

import std/json
import logos_sdk/ffi
import ./tx_sender
import ./keystore_status   # ksReply: an lp reply however it arrives

const
  TxSenderModule* = "tx_sender_module"
  Ours = "muster_module"

var client: ptr LpClient

proc reached(): bool =
  if client == nil:
    client = lp_client_create(TxSenderModule.cstring, Ours.cstring, nil, nil)
  client != nil

proc lpTxSender(meth: string, args: JsonNode, timeoutMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    if not reached(): return nil
    var res, err: cstring
    let rc = lp_invoke(client, meth.cstring, ($args).cstring, cint(timeoutMs), addr res, addr err)
    defer:
      if res != nil: lp_string_free(res)
      if err != nil: lp_string_free(err)
    if rc != LP_OK or res == nil: return nil
    ksReply($res)

proc installTxSender*() =
  ## Send payments through tx_sender_module (parts_evm.nim's platform path).
  setTxSender(lpTxSender)
