## The action manifest seam (docs/design/action-manifest.md, exo-002.1), pure Nim:
## the default is UNDECLARED and shown as such; a declared manifest must be
## consistent with its own describe(); the baseline disclosure names the store node
## on every action; the stub follows its descriptor so probes can randomize it.
## Real drivers are graded through checkConformance in conformance_test.nim.

import std/strutils
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/manifest

let effect = Effect(schemaId: "x", fields: @[("a", cbUint(1'u64))])

# ── 1. the base default is undeclared, and undeclared is a consistency failure ──
type Bare = ref object of Driver
method describe(d: Bare): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "bare", membership: mmAnonymous,
                   finality: finImmediate, threshold: 1)
block:
  let m = Bare().manifest(effect)
  doAssert not m.declared
  doAssert m.agreement == Bare().describe()
  doAssert consistencyFailures(m) == @["manifest is undeclared"]
  echo "1. undeclared by default, and undeclared FAILS consistency OK"

# ── 2. the baseline names the store node on every action, and it cannot be dropped ──
block:
  let m = newStubDriver().manifest(effect)
  let full = m.fullDisclosure()
  doAssert "timing" in full.visibleTo(obStoreNode) and "topic" in full.visibleTo(obStoreNode)
  doAssert "effect" in full.visibleTo(obRoomMember)
  doAssert full.outsideBoundary().len == 2   # timing + topic; nothing else for an immediate stub
  echo "2. baseline disclosure names the store node (FS-9) OK"

# ── 3. the stub follows its own descriptor (probes randomize finality/membership) ──
block:
  for fin in [finImmediate, finProbabilistic, finExternal]:
    for mem in [mmAnonymous, mmNamed]:
      let d = newStubDriver(finality = fin, membership = mem)
      let m = d.manifest(effect)
      doAssert m.declared and m.consistent(), $fin & "/" & $mem & ": " & $consistencyFailures(m)
      doAssert m.agreement == d.describe()
  echo "3. the stub's manifest is consistent under every finality × membership OK"

# ── 4. the consistency rules catch a lying manifest ──────────────────────────────
block:
  let ext = newStubDriver(finality = finExternal, membership = mmNamed).describe()
  var m = ActionManifest(declared: true, agreement: ext)
  let f = consistencyFailures(m)
  doAssert "external finality but no environment requirement" in f
  doAssert "external finality but nothing disclosed to the chain observer" in f
  doAssert "external finality but no write touch" in f
  doAssert "named membership but no contributor authority requirement" in f
  m.requirements = @[req(rqEnvironment, "chain:1"), req(rqAuthority, "owner", rpContributor)]
  m.discloses = @[row("amount", obChainObserver)]
  m.touches = @[touch("chain:1", tmWrite)]
  doAssert m.consistent(), $consistencyFailures(m)
  m.requirements.add req(rqInfra, "")
  doAssert not m.consistent()
  echo "4. a manifest that contradicts its describe() (or names nothing) FAILS OK"

# ── 4b. the exo-45e party + material rules (docs/design/material-and-disclosure.md) ─
block:
  let desc = newStubDriver(finality = finImmediate, membership = mmAnonymous).describe()
  # a proposer/counterparty requirement must NAME an effect field.
  var m = ActionManifest(declared: true, agreement: desc,
    requirements: @[req(rqAddress, "payee", rpCounterparty)])   # default needs → no field
  doAssert not m.consistent(), "a counterparty requirement with no effect field must fail"
  doAssert consistencyFailures(m)[0].contains("names no effect field")

  # with a field declared but ABSENT from the effect, it still fails (nowhere to land).
  m.requirements = @[req(rqAddress, "payee", rpCounterparty, need(mcAddress, "chain:1", "to"))]
  let noTo = Effect(schemaId: "x", fields: @[("value", cbUint(1'u64))])
  doAssert not m.consistent(noTo), "binding an effect field the effect lacks must fail"
  # and passes once the effect carries the field.
  let withTo = Effect(schemaId: "x", fields: @[("to", cbText("0xabc")), ("value", cbUint(1'u64))])
  doAssert m.consistent(withTo), $consistencyFailures(m, withTo)

  # kind and declared material class must not drift for a participant requirement.
  m.requirements = @[req(rqAuthority, "owner", rpContributor, need(mcAddress, "safe:0x"))]
  doAssert not m.consistent(), "an authority requirement declaring class address must fail"
  doAssert consistencyFailures(m)[0].contains("expected authority")
  echo "4b. party + material vocabulary: proposer/counterparty field + class alignment OK"

# ── 5. fieldText reads the effect (the invoke driver's module/method live there) ──
block:
  let e = Effect(schemaId: "muster.invoke.lez_core.transfer_private.v1",
                 fields: @[("module", cbText("lez_core")), ("method", cbText("transfer_private")),
                           ("n", cbUint(1'u64))])
  doAssert e.fieldText("module") == "lez_core" and e.fieldText("method") == "transfer_private"
  doAssert e.fieldText("n") == "" and e.fieldText("missing") == ""
  echo "5. fieldText reads text fields off the effect OK"

echo "manifest_test: all OK"

# ── 6. the conformance suite itself goes RED for an undeclared driver ────────────
import ../src/drivers/conformance
type Undeclared = ref object of Driver
method describe(d: Undeclared): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "undeclared", membership: mmAnonymous,
                   finality: finImmediate, threshold: 1)
method verifyContribution(d: Undeclared, c: Contribution, round: int): bool = true
block:
  let tampered = Effect(schemaId: "x", fields: @[("a", cbUint(2'u64))])
  let r = checkConformance(Undeclared(), effect, tampered, Contribution(bytes: @[1'u8]))
  doAssert not r.allPass()
  var sawManifest = false
  for f in r.failed():
    if "manifest is declared and consistent" in f: sawManifest = true
  doAssert sawManifest, $r.failed()
  doAssert r.failed().len == 1, "only the manifest check should fail: " & $r.failed()
  echo "6. an undeclared driver FAILS the conformance suite (and nothing else) OK"
