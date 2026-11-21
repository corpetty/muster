## The private posture's prover seam (epic exo-0d3, exo-efa; docs/design/lez-msig.md §6). A
## private lez-msig execution is a privacy-preserving transaction, and proving it takes LEZ's own
## Rust prover. Muster builds and signs everything else (the instruction's bytes, the approvals)
## and hands the proof to a prover:
##   * `LpMsigProver` (msig_prover_lp.nim): the Logos module `lez_msig_module`, over lp_*. This is how muster runs it
##     in Basecamp and the runner. The proof is a job: `submit` answers at once and `job` is polled
##     on the intents tick, so no call holds the module thread.
##   * `CliMsigProver`: the module's own code as a CLI (`programs/lez-msig`'s `msig_exec`), for
##     tests that run without a Logos host. It is the same `exec_request` function, called
##     synchronously, so its "job" is done when `submit` returns.
## Requests and answers are the module's JSON (`lez_msig_module.lidl`). The group secret travels
## in the request, and a prover keeps it only for the job.

import std/[json, os, osproc, streams, strtabs, tables]

type
  MsigProver* = ref object of RootObj

method derive*(p: MsigProver, req: JsonNode): JsonNode {.base.} =
  %*{"error": "unavailable", "detail": "no prover"}
method submit*(p: MsigProver, req: JsonNode): JsonNode {.base.} =
  ## {mode: exec | fund | topup | scan, …} → {job} at once, or {error, detail}. topup is the LEZ
  ## v0.4 line's (lez_msig_module 0.2.0).
  %*{"error": "unavailable", "detail": "no prover"}
method job*(p: MsigProver, id: string): JsonNode {.base.} =
  ## {state: proving | done | failed, …the mode's answer} or {error}.
  %*{"error": "unknown-job"}
method forget*(p: MsigProver, id: string) {.base.} = discard
method send*(p: MsigProver, req: JsonNode): JsonNode {.base.} =
  ## {rpc, message, proof, witnesses: [{signature, publicKey}]} → {hash}: a proved deposit,
  ## signed in the payer's own keystore, sent.
  %*{"error": "unavailable", "detail": "no prover"}

# ── the same code as a CLI, for tests ─────────────────────────────────────────
type CliMsigProver* = ref object of MsigProver
  exe*: string                   ## programs/lez-msig's target/release/msig_exec
  env*: seq[(string, string)]    ## e.g. RISC0_DEV_MODE=1 for a dev-mode zone
  done: Table[string, JsonNode]
  n: int

proc newCliMsigProver*(exe: string, env: seq[(string, string)] = @[]): CliMsigProver =
  CliMsigProver(exe: exe, env: env)

proc run(p: CliMsigProver, req: JsonNode): JsonNode =
  var env = newStringTable()
  for (k, v) in envPairs(): env[k] = v
  for (k, v) in p.env: env[k] = v
  let pr = startProcess(p.exe, env = env, options = {poUsePath})
  pr.inputStream.write($req)
  pr.inputStream.close()
  let answer = pr.outputStream.readAll()
  discard pr.waitForExit()
  pr.close()
  try: parseJson(answer)
  except CatchableError: %*{"error": "failed", "detail": "msig_exec answered: " & answer}

method derive*(p: CliMsigProver, req: JsonNode): JsonNode =
  var r = req.copy()
  r["mode"] = %"derive"
  p.run(r)
method submit*(p: CliMsigProver, req: JsonNode): JsonNode =
  let a = p.run(req)
  inc p.n
  let id = "cli-" & $p.n
  var j = a.copy()
  j["state"] = %(if a.hasKey("error"): "failed" else: "done")
  p.done[id] = j
  %*{"job": id}
method job*(p: CliMsigProver, id: string): JsonNode =
  p.done.getOrDefault(id, %*{"error": "unknown-job"})
method forget*(p: CliMsigProver, id: string) = p.done.del(id)
method send*(p: CliMsigProver, req: JsonNode): JsonNode =
  var r = req.copy()
  r["mode"] = %"send"
  p.run(r)
