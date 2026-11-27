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

method health*(p: MsigProver): JsonNode {.base.} =
  ## The prover's own report: {ok, line ("v0.4" from lez_msig_v04_module; absent from lez_msig_module, the v0.3 line), …}.
  %*{}

const
  ProverModuleV03* = "lez_msig_module"      ## 0.1.x, LEZ v0.3 (programs/lez-msig)
  ProverModuleV04* = "lez_msig_v04_module"  ## 0.2.x, LEZ v0.4 (programs/lez-msig/lez04)

proc proverModuleFor*(zoneLine: string): string =
  ## The prover module for a zone's LEZ line (exo-cc7). The lines cannot share one build, so
  ## each is its own module and a host may hold both; muster calls the one its zone needs.
  if zoneLine == "v0.4": ProverModuleV04 else: ProverModuleV03

proc proverFits*(health: JsonNode, zoneLine: string): tuple[ok: bool, want: string] =
  ## Whether a prover proves for the zone's LEZ line (exo-cc7): a guard on what the chosen
  ## module reports of itself. A module that answers health without a line is the v0.3 one; a
  ## prover that reports nothing (the test CLI, chosen by its caller) is taken at its word.
  ## `want` names the module to install.
  let want = proverModuleFor(zoneLine) & (if zoneLine == "v0.4": " (LEZ v0.4)" else: " (LEZ v0.3)")
  if health.kind != JObject or not health.hasKey("ok"): return (true, want)
  let line = health{"line"}.getStr("v0.3")
  (line == (if zoneLine == "v0.4": "v0.4" else: "v0.3"), want)

type MsigPosture* = object
  ## What `lez_msig_open` opens (exo-c0c): private unless the spec asks for public.
  ok*: bool
  private*: bool
  error*: string     ## "" | bad-spec | no-prover | refused
  install*: string   ## no-prover: the package to install
  detail*: string

proc msigPostureOf*(spec: JsonNode, zoneLine: proc(): string,
                    proverLoaded: proc(line: string): bool): MsigPosture =
  ## A lez-msig is private by default (RFP-005, docs/design/lez-msig.md §1): `private` absent
  ## opens a private one, `private: false` a public one, and only that. Private needs the zone
  ## line's prover module loaded; without it the open is refused, naming the module to install,
  ## and never falls back to public on its own. `zoneLine` raises when the zone cannot be read.
  let p = (if spec.kind == JObject: spec{"private"} else: nil)
  if p != nil and p.kind != JBool:
    return MsigPosture(error: "bad-spec", detail: "private is true or false")
  let asked = p != nil
  if asked and not p.getBool():
    return MsigPosture(ok: true, private: false)
  let orPublic = (if asked: "" else: "; or open a public one with private: false, which puts every member's key and every action on chain")
  var line: string
  try: line = zoneLine()
  except CatchableError as e:
    return MsigPosture(error: "refused", detail: "cannot read the zone's LEZ line: " & e.msg & orPublic)
  if not proverLoaded(line):
    let name = proverModuleFor(line)
    return MsigPosture(error: "no-prover", install: name,
                       detail: "a private multisig's transactions on this zone (LEZ " & line & ") are proved by " &
                               name & ": install it first" & orPublic)
  MsigPosture(ok: true, private: true)

method derive*(p: MsigProver, req: JsonNode): JsonNode {.base.} =
  %*{"error": "unavailable", "detail": "no prover"}
method submit*(p: MsigProver, req: JsonNode): JsonNode {.base.} =
  ## {mode: exec | fund | topup | scan, …} → {job} at once, or {error, detail}. topup is the LEZ
  ## v0.4 line's (lez_msig_v04_module).
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
