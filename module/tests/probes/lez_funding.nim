## Funding for the LEZ v0.3 e2e tests on any zone (exo-eb6.4.5): LEZ v0.3 has no faucet, so
## native LEZ reaches a test's accounts from the zone's FUNDER (infra/lez/funder.sh) — the
## local zone's genesis funder, or on the testnet the one account someone holding native LEZ
## funded. Each account a test makes gets MUSTER_LEZ_E2E_FUND base units (default 1 LEZ, as
## on the local zone; the testnet wants less: a test's keys are dropped with what they hold).

import std/[os, osproc, strutils]
import ../../src/bitcoin/tx                 # toHex

let funderScript* = currentSourcePath.parentDir.parentDir.parentDir.parentDir / "infra" / "lez" / "funder.sh"

proc e2eFund*(): string =
  ## What a test sends each account it makes, in base units.
  getEnv("MUSTER_LEZ_E2E_FUND", "1000000000")

proc fundFrom*(zone: string, id: seq[byte], amount: string) =
  ## The zone's funder sends `amount` to `id`. `zone` is the sequencer's URL (or local|testnet).
  let (o, code) = execCmdEx(quoteShell(funderScript) & " --zone " & quoteShell(zone) & " fund " &
                            toHex(id) & " " & amount)
  doAssert code == 0, "the zone's funder could not send (infra/lez/funder.sh --zone " & zone & " account): " & o

proc deployFrom*(zone, bin: string): string =
  ## Deploy a v0.3 program through program_loader, the zone's funder paying → its account id (hex).
  let (o, code) = execCmdEx(quoteShell(funderScript) & " --zone " & quoteShell(zone) & " deploy " & quoteShell(bin))
  doAssert code == 0, "the deploy failed: " & o
  let at = o.find("(hex ")
  doAssert at >= 0 and o.len >= at + 5 + 64, "the deploy names no program account: " & o
  o[at + 5 ..< at + 5 + 64]
