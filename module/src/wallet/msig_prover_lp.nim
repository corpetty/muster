## The private posture's prover as the Logos module `lez_msig_module`, over lp_* (exo-efa). Kept
## apart from msig_prover.nim so a test without a Logos host links without lp_*, as
## monero_backend_lp.nim is kept apart from monero_backend.nim.

import std/json
import logos_sdk/ffi
import ./msig_prover

# ── the Logos module, over lp_* ───────────────────────────────────────────────
const
  ProverModule* = "lez_msig_module"
  CallMs = cint(15_000)          ## every call answers at once: a proof is a job, not a call

type LpMsigProver* = ref object of MsigProver
  client: ptr LpClient

proc newLpMsigProver*(origin = "muster_module"): LpMsigProver =
  ## Raises when the module is not loaded: readiness asks the host's registry before muster
  ## calls a module (coordination/module_registry.nim), so a caller checks that first.
  let c = lp_client_create(ProverModule.cstring, origin.cstring, nil, nil)
  if c == nil: raise newException(IOError, ProverModule & " is not loaded")
  LpMsigProver(client: c)

proc call(p: LpMsigProver, meth: string, arg: string): JsonNode =
  var res, err: cstring
  let rc = lp_invoke(p.client, meth.cstring, ($ %*[arg]).cstring, CallMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil:
    return %*{"error": "unreachable", "detail": (if err != nil: $err else: "lp_invoke rc " & $rc)}
  try:
    result = parseJson($res)
    if result.kind == JString: result = parseJson(result.getStr())
  except CatchableError as e:
    result = %*{"error": "unreadable", "detail": e.msg}

method health*(p: LpMsigProver): JsonNode =
  var res, err: cstring
  let rc = lp_invoke(p.client, "health".cstring, "[]".cstring, CallMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil: return %*{"error": "unreachable"}
  try:
    result = parseJson($res)
    if result.kind == JString: result = parseJson(result.getStr())
  except CatchableError: result = %*{"error": "unreadable"}
method derive*(p: LpMsigProver, req: JsonNode): JsonNode = p.call("derive", $req)
method submit*(p: LpMsigProver, req: JsonNode): JsonNode =
  let mode = req{"mode"}.getStr("exec")
  # topup is lez_msig_module 0.2.0's (the LEZ v0.4 line, exo-cc7); 0.1.0 answers it unknown
  p.call((if mode in ["fund", "scan", "topup"]: mode else: "exec"), $req)
method job*(p: LpMsigProver, id: string): JsonNode = p.call("job", id)
method forget*(p: LpMsigProver, id: string) = discard p.call("forget", id)
method send*(p: LpMsigProver, req: JsonNode): JsonNode = p.call("send", $req)
