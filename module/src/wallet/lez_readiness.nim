## LEZ account readiness (exo-44b L1, docs/design/lez-wallet-delegation.md §2-3): does
## THIS instance have a set-up, funded LEZ account for an action? Read from the zone via
## the LezCore seam — the same reads the wallet already does — and reported as a plain
## (state, detail) tuple so the coordination readiness layer wraps it into a Grade
## without this module depending on it (no wallet↔coordination cycle).
##
## Muster only DETECTS here; PROVISIONING (create/activate/faucet/shield) is delegated to
## the first-party LEZ Wallet App (§1). So the `missing` detail names that app as the
## remedy. Never a false zero (invariant 8 / the wallet contract): a read that raises or
## returns empty is `unknown`, never `missing`.

import ./lez_core        # LezCore, listAccounts, getBalanceRaw, LezAccountKind
import ./types           # cmpDec

proc lezAccountStatus*(core: LezCore, minRaw = "0"): tuple[state, detail: string] {.gcsafe.} =
  ## "met"     — an account exists and holds at least `minRaw` (minRaw "0" = just an account).
  ## "missing" — no account, or under `minRaw`: set up / top up in the LEZ Wallet App.
  ## "unknown" — the zone could not be read (sequencer unreachable, inv 8): never met/missing.
  var accs: seq[LezAccount]
  try: accs = core.listAccounts()
  except CatchableError as e:
    return ("unknown", "LEZ zone unreachable — cannot confirm your account: " & e.msg)
  if accs.len == 0:
    return ("missing", "no LEZ account yet — set one up in the LEZ Wallet App")
  var best = "0"
  var anyRead = false
  for a in accs:
    var b = ""
    try: b = core.getBalanceRaw(a.id, a.kind == lakPublic)
    except CatchableError: continue        # one account's read failed — try the others
    if b.len == 0: continue                # empty = unknown for this account, never a zero
    anyRead = true
    if cmpDec(b, best) > 0: best = b
  if not anyRead:
    return ("unknown", "LEZ account exists but its balance could not be read (zone unreachable)")
  if minRaw == "0" or cmpDec(best, minRaw) >= 0:
    return ("met", "LEZ account ready (balance " & best & ")")
  ("missing", "LEZ account underfunded (have " & best & ", need " & minRaw &
              ") — top up in the LEZ Wallet App")
