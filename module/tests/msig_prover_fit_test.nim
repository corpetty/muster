## Whether the installed lez_msig_module proves for the zone's LEZ line (exo-cc7;
## src/wallet/msig_prover.nim `proverFits`). The v0.3 and v0.4 lines are separate builds of one
## module (0.1.0 and 0.2.0), and a host holds one:
##   1. 0.2.0 (health line "v0.4") fits a v0.4 zone, not a v0.3 one;
##   2. 0.1.0 (health without a line) fits a v0.3 zone, not a v0.4 one, and the answer names
##      the version to install;
##   3. a prover that reports nothing (the test CLI, chosen by its caller) is taken at its word.

import std/json
import ../src/wallet/msig_prover

var fails = 0
template check(cond: bool, what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc fails

let v04 = %*{"ok": true, "line": "v0.4", "busy": false}
let v03 = %*{"ok": true, "busy": false}
check(proverFits(v04, "v0.4").ok, "0.2.0 fits a v0.4 zone")
check(not proverFits(v04, "v0.3").ok, "0.2.0 does not fit a v0.3 zone")
check(proverFits(v04, "v0.3").want == "lez_msig_module 0.1.0 (LEZ v0.3)", "and names 0.1.0")
check(proverFits(v03, "v0.3").ok, "0.1.0 fits a v0.3 zone")
let f = proverFits(v03, "v0.4")
check(not f.ok and f.want == "lez_msig_module 0.2.0 (LEZ v0.4)", "0.1.0 does not fit a v0.4 zone, and 0.2.0 is named")
check(proverFits(%*{}, "v0.4").ok and proverFits(newJNull(), "v0.3").ok, "a prover reporting nothing is taken at its word")

if fails > 0:
  echo fails, " failed"
  quit 1
echo "msig_prover_fit_test: all passed"
