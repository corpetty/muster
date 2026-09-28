## exo-ec8 — a manifest says exactly what its action needs, touches and discloses:
## nothing it does not do, nothing it does left out, and one name for one thing.
##
## The action atlas (exo-661) renders every built manifest verbatim, so an imprecise one
## teaches the wrong thing. The generator (module/tools/action_corpus.nim) surfaced these:
## a Safe contract call that still asked a counterparty for a payee address; the Safe
## naming its chain "chain:31337" while its environment() says "eip155:31337"; a LEZ-FROST
## account touched twice; a LEZ multisig proposal that named neither the accounts it
## passes nor the program it calls. Read against the code, three more: the LEZ multisig
## and LEZ-FROST paths that run talk to the user's sequencer over JSON-RPC, so they need
## `lez-rpc`, not `lez_core` or a funded `lez-account` (v0.2.4 charges no fee); a Safe's
## signers and owner policy are public on chain and were not disclosed; and a touch named
## a chain and an account with the same "lez:" prefix.
##
## The rules, held over EVERY generated (kind, variant) so a new driver meets them too:
##   - a touch names a chain in CAIP-2 and an account in CAIP-10, and none repeats;
##   - an environment requirement is named exactly as the driver's environment();
##   - a Safe transfer's payee is counterparty material; a call's target is not anyone's;
##   - a transfer always asks for an amount (it moves value by definition — the composer
##     reads the slot off a template whose value is not chosen yet); a call only when it
##     sends ETH; a delegatecall never;
##   - a LEZ action names every account it passes and the program it calls;
##   - the live LEZ paths need `lez-rpc`, which readiness can grade.
## Needs the full closure (run-suite.sh supplies it).

import std/[json, sets, strutils, sequtils]
import ../tools/action_corpus
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/registry
import ../src/drivers/manifest
import ../src/coordination/readiness

let entries = corpus()["entries"]
proc e(key: string): JsonNode = entries[key]
proc reqs(key: string): seq[JsonNode] = e(key)["manifest"]["requirements"].getElems()
proc touches(key: string): seq[string] = e(key)["manifest"]["touches"].getElems().mapIt(it["target"].getStr())
proc touchMode(key, target: string): string =
  for t in e(key)["manifest"]["touches"]:
    if t["target"].getStr() == target: return t["mode"].getStr()
proc discloses(key: string, observer: string): seq[string] =
  for d in e(key)["manifest"]["discloses"]:
    if d["to"].getStr() == observer: result.add d["field"].getStr()
proc hasReq(key, kind, name: string): bool = reqs(key).anyIt(it["kind"].getStr() == kind and it["name"].getStr() == name)

# ── 1. every manifest: unique touches, CAIP-named, environment named as environment() ──
block:
  for key, entry in entries.pairs:
    let ts = touches(key)
    doAssert ts.len == ts.toHashSet().len, key & ": a touch repeats: " & $ts
    let env = entry["environment"].getStr()
    for r in reqs(key):
      if r["kind"].getStr() == "environment":
        doAssert r["name"].getStr() == env, key & ": environment requirement " & r["name"].getStr() & " ≠ environment() " & env
    for t in ts:
      doAssert not t.startsWith("chain:"), key & ": a chain is named in CAIP-2, not chain:<id> (" & t & ")"
      doAssert not t.startsWith("safe:") and not t.startsWith("lez-proposal:"),
        key & ": an account is named in CAIP-10 (" & t & ")"
  echo "1. every manifest: unique touches, CAIP-2 chains / CAIP-10 accounts, environment named as environment() OK"

# ── 2. the Safe: a transfer asks for a payee and an amount; a call or delegatecall no payee ──
block:
  let env = e("safe/transfer")["environment"].getStr()
  doAssert env == "eip155:31337"
  doAssert hasReq("safe/transfer", "address", "payee") and hasReq("safe/transfer", "asset", "amount")
  for r in reqs("safe/transfer"):
    if r["kind"].getStr() in ["address", "asset"]:
      doAssert r["needs"]["target"].getStr() == env, "material is constrained to the CAIP-2 chain"
  for key in ["safe/contract-call", "safe/delegatecall"]:
    doAssert not hasReq(key, "address", "payee"),
      key & ": `to` is the contract the proposer chose, not a counterparty's receiving address"
  let callValue = e("safe/contract-call")["effectExample"]["fields"]{"value"}.getInt(0)
  doAssert hasReq("safe/contract-call", "asset", "amount") == (callValue > 0),
    "a call asks for an amount only when it sends ETH"
  doAssert not hasReq("safe/delegatecall", "asset", "amount"), "a delegatecall moves no value (Safe's executor passes none)"
  # the composer reads the slots off a TEMPLATE transfer, before an amount is chosen
  let safe = newDriver("safe", %*{"chainId": 31337, "safe": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
                                  "owners": ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"], "threshold": 1})
  let tmpl = Effect(schemaId: "muster.effect.transfer.v1",
                    fields: @[("to", cbText("")), ("value", cbUint(0'u64)), ("nonce", cbUint(0'u64))])
  doAssert safe.manifest(tmpl).requirements.anyIt(it.kind == rqAsset and it.name == "amount" and it.party == rpProposer),
    "a template transfer (value not chosen yet) still offers the amount slot"
  for key in ["safe/transfer", "safe/contract-call", "safe/delegatecall"]:
    let chain = discloses(key, "chain-observer")
    for f in ["to", "value", "data", "operation", "nonce", "signers", "policy"]:
      doAssert f in chain, key & ": execTransaction puts " & f & " on the public record"
    doAssert "signed-tx" in discloses(key, "rpc-provider")
  let safeAcct = "eip155:31337:" & e("safe/transfer")["profile"]["account"].getStr().split(':')[^1]
  doAssert safeAcct in touches("safe/transfer") and (safeAcct & "/nonce") in touches("safe/transfer")
  doAssert (safeAcct & "/storage") in touches("safe/delegatecall") and (safeAcct & "/storage") notin touches("safe/transfer")
  echo "2. Safe: payee only on a transfer; amount on a transfer, on a call only when ETH moves, never on a delegatecall; signers + policy + nonce public OK"

# ── 3. LEZ: every passed account and the program, CAIP-10, no repeats; lez-rpc not lez_core ──
block:
  for key in ["lez-multisig/transfer", "lez-multisig/vault-init", "lez-frost/transfer"]:
    let chain = e(key)["environment"].getStr()
    let f = e(key)["effectExample"]["fields"]
    let program = (if f.hasKey("target"): f["target"] else: f["program"]).getStr()
    doAssert touchMode(key, chain & ":" & program) == "read", key & ": the program it calls is read"
    for a in f["accounts"]:
      doAssert touchMode(key, chain & ":" & a.getStr()) == "write", key & ": every account it passes may be written: " & a.getStr()
    doAssert hasReq(key, "infra", "lez-rpc"), key & ": the path that runs submits over the user's sequencer (lez-rpc)"
    doAssert not hasReq(key, "module", "lez_core"), key & ": the live path does not go through lez_core"
    doAssert not hasReq(key, "infra", "lez-account"), key & ": LEZ v0.2.4 charges no fee — no funded account is needed"
  echo "3. LEZ: program read, every passed account written, CAIP-10, lez-rpc not lez_core OK"

# ── 4. readiness can grade what the manifests now ask for ────────────────────────────
block:
  let yes = probeFromFacts(HostFacts(lezRpcUrl: "https://testnet.lez.logos.co"))
  doAssert yes.infraConfigured("lez-rpc").status == rdMet
  doAssert probeFromFacts(HostFacts()).infraConfigured("lez-rpc").status == rdMissing
  let evm = probeFromFacts(HostFacts(rpcUrl: "http://x",
    rpcProbe: proc(url: string): tuple[ok: bool, chainId: int, detail: string] {.gcsafe.} = (true, 31337, "ok")))
  doAssert evm.environmentReachable("eip155:31337").status == rdMet
  doAssert evm.environmentReachable("eip155:1").status == rdMissing
  echo "4. readiness grades lez-rpc and a CAIP-2 EVM environment OK"

echo "manifest_precision_test: all OK"
