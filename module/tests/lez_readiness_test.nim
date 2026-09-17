## LEZ account readiness (exo-44b L1, docs/design/lez-wallet-delegation.md): muster DETECTS
## whether this instance has a set-up, funded LEZ account and, when not, points at the LEZ
## Wallet App — it never provisions. lezAccountStatus reads the zone (via LezCore) as
## met/missing/unknown; readiness grades a `lez-account` infra requirement through the
## host's lezReady closure, with the LEZ-Wallet-App remedy. Links secp + stint + libsodium.

import std/strutils
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/coordination/readiness
import ../src/wallet/types
import ../src/wallet/lez_core
import ../src/wallet/lez_readiness

# A LezCore whose reads RAISE — the unreachable-zone case (never a false zero).
type UnreachableLez = ref object of LezCore
method listAccounts(c: UnreachableLez): seq[LezAccount] =
  raise newException(WalletError, "sequencer timeout")

proc gradeOf(core: LezCore, minRaw: string): Grade {.gcsafe.} =
  let (s, d) = lezAccountStatus(core, minRaw)
  case s
  of "met": (rdMet, d)
  of "missing": (rdMissing, d)
  else: (rdUnknown, d)

# Build the readiness closure with `core` as a PARAM (not a captured global), so it is
# gcsafe — the shape the host uses over its own LezCore.
proc mkLezReady(core: LezCore, minRaw: string): proc(): Grade {.gcsafe.} =
  (proc(): Grade {.gcsafe.} = gradeOf(core, minRaw))

# ── 1. no account → missing; the detail names the LEZ Wallet App ──────────────────
block:
  let fake = newFakeLezCore()
  let (s, d) = lezAccountStatus(fake)
  doAssert s == "missing" and "LEZ Wallet App" in d, d
  echo "1. no LEZ account → missing, remedy names the LEZ Wallet App OK"

# ── 2. an account, unfunded: met for 'just an account', missing for a spend ────────
block:
  let fake = newFakeLezCore()
  discard fake.createAccount(lakPublic)
  doAssert lezAccountStatus(fake, "0").state == "met", "an account with no spend needed is ready"
  doAssert lezAccountStatus(fake, "500").state == "missing", "a spend needs funds — underfunded"
  echo "2. account exists: met for a receive, missing (underfunded) for a spend OK"

# ── 3. funded via the faucet (claimPinata) → met for the spend ────────────────────
block:
  let fake = newFakeLezCore()
  let a = fake.createAccount(lakPublic)
  discard fake.claimPinata("pinata-1", a.id)          # the fake faucet credits 1e9
  let (s, d) = lezAccountStatus(fake, "500")
  doAssert s == "met" and "balance" in d, d
  echo "3. funded account → met for the spend OK"

# ── 4. the zone unreachable → unknown, never missing (inv 8, no false zero) ────────
block:
  let (s, d) = lezAccountStatus(UnreachableLez())
  doAssert s == "unknown" and "unreachable" in d, d
  echo "4. unreachable zone → unknown, never a false missing/zero OK"

# ── 5. readiness grades a lez-account requirement through the host closure ─────────
block:
  let desc = newStubDriver(finality = finImmediate, membership = mmAnonymous).describe()
  let m = ActionManifest(declared: true, agreement: desc,
                         requirements: @[req(rqInfra, "lez-account")])
  # unprovisioned → the item is missing, and the remedy names the LEZ Wallet App.
  block:
    let fake = newFakeLezCore()
    var f = HostFacts()
    f.lezReady = mkLezReady(fake, "0")
    let r = assessReadiness(m, probeFromFacts(f))
    doAssert not r.ready and r.items.len == 1
    doAssert r.items[0].status == rdMissing
    doAssert "LEZ Wallet App" in r.items[0].remedy, r.items[0].remedy
  # provisioned + funded → met, ready.
  block:
    let fake = newFakeLezCore()
    let a = fake.createAccount(lakPublic)
    discard fake.claimPinata("p", a.id)
    var f = HostFacts()
    f.lezReady = mkLezReady(fake, "1")
    doAssert assessReadiness(m, probeFromFacts(f)).ready
  # no probe wired → unknown, never a silent met.
  block:
    let r = assessReadiness(m, probeFromFacts(HostFacts()))
    doAssert r.items[0].status == rdUnknown and not r.ready
  echo "5. readiness grades a lez-account requirement: missing→remedy, funded→met, no-probe→unknown OK"

echo "lez_readiness_test: all OK"
