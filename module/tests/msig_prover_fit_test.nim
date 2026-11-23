## Which prover module a private lez-msig needs, and whether the loaded one proves for the zone's
## LEZ line (exo-cc7; src/wallet/msig_prover.nim). The v0.3 and v0.4 lines are separate builds,
## so they are separate modules a host may hold side by side:
##   1. a v0.4 zone needs lez_msig_v04_module, a v0.3 zone lez_msig_module;
##   2. a prover reporting line "v0.4" fits a v0.4 zone, not a v0.3 one;
##   3. one reporting no line (lez_msig_module) fits a v0.3 zone, not a v0.4 one, and the answer
##      names the module to install;
##   4. a prover that reports nothing (the test CLI, chosen by its caller) is taken at its word;
##   5. the driver's manifest names the module its hook picks for the account's chain.

import std/json
import stint
import ../src/wallet/msig_prover
import ../src/drivers/[lez_msig, manifest, driver]
import ../src/coordination/intent_events
import ../src/lez/msig as msigbytes

var fails = 0
template check(cond: bool, what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc fails

check(proverModuleFor("v0.4") == "lez_msig_v04_module" and proverModuleFor("v0.3") == "lez_msig_module",
      "each line names its own module")
let v04 = %*{"ok": true, "line": "v0.4", "busy": false}
let v03 = %*{"ok": true, "busy": false}
check(proverFits(v04, "v0.4").ok, "the v0.4 module fits a v0.4 zone")
check(not proverFits(v04, "v0.3").ok, "and not a v0.3 one")
check(proverFits(v04, "v0.3").want == "lez_msig_module (LEZ v0.3)", "which names the v0.3 module")
check(proverFits(v03, "v0.3").ok, "the v0.3 module fits a v0.3 zone")
let f = proverFits(v03, "v0.4")
check(not f.ok and f.want == "lez_msig_v04_module (LEZ v0.4)", "and not a v0.4 one, which names the v0.4 module")
check(proverFits(%*{}, "v0.4").ok and proverFits(newJNull(), "v0.3").ok, "a prover reporting nothing is taken at its word")

# 5. the manifest's module requirement follows the hook
proc moduleOf(m: ActionManifest): string =
  for r in m.requirements:
    if r.kind == rqModule: return r.name
let p = MsigProposal(multisig: newSeq[byte](32), zone: newSeq[byte](32), epoch: 0, nonce: 0,
                     action: MsigAction(kind: akTransfer, to: newSeq[byte](32), amount: 1.u128),
                     expiresMs: 1, proposer: newSeq[byte](32))
let d = newLezMsigDriver(LezMsigAccount(chain: "lez:dev04", private: true, program: newSeq[byte](32), createKey: newSeq[byte](32),
                                           zone: newSeq[byte](32), address: newSeq[byte](32), accountId: "lez:dev04:00"))
let e = effectFromJson(lezMsigEffect(p))
check(moduleOf(d.manifest(e)) == "lez_msig_module", "unset, the hook names the v0.3 module")
lezMsigProverFor = proc(chain: string): string = (if chain == "lez:dev04": proverModuleFor("v0.4") else: proverModuleFor("v0.3"))
check(moduleOf(d.manifest(e)) == "lez_msig_v04_module", "set, the manifest names the v0.4 module for a v0.4 zone")

if fails > 0:
  echo fails, " failed"
  quit 1
echo "msig_prover_fit_test: all passed"
