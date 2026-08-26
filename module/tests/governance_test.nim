## Driver-as-proposal (invariant 6): what a group can do evolves by PROPOSAL, not a
## fixed compile-time list. A room folds its allowed driver kinds from the log
## (roomDriverKinds): the founding set, plus any kind an `add-driver` governance
## intent the room APPROVED admits. Here the group grants itself a "unanimous"
## (n-of-n) policy by endorsing an add-driver proposal — the same propose/contribute/
## fold path as any intent, no special case. Needs libsodium (Ed25519). See tests/README.md.

import std/[strutils, algorithm]
import ../src/intents/materialization
import ../src/drivers/driver as drivercore
import ../src/drivers/threshold
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/intents

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(sig: Ed25519Sig): string =
  const d = "0123456789abcdef"
  for b in sig: (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])

# The room governs add-driver proposals under a 2-of-3 threshold (a group decision).
let a = encFromSeed(seed(1))
let b = encFromSeed(seed(2))
let c = encFromSeed(seed(3))
let drv = newThresholdDriver(@[a.identity().ed, b.identity().ed, c.identity().ed], k = 2)
let foldDrv: DriverFor = proc(kind: string): drivercore.Driver = drv

# A governance proposal: admit the "unanimous" driver kind into the room.
const addDriverJson = """{"effect":"add-driver","kind":"unanimous"}"""
let id = intentIdFor(addDriverJson, "threshold")
let m = canonicalize(drv, effectFromJson(addDriverJson))
proc endorse(k: EncKeys): string = hex(edSign(k, m.bytes))

# 1. The add-driver effect is schema-bound governance, not a payment (F-5).
doAssert effectFromJson(addDriverJson).schemaId == "muster.effect.governance.add-driver.v1",
         "add-driver selects the governance schema"
doAssert canonicalize(drv, effectFromJson(addDriverJson)).bytes !=
         canonicalize(drv, effectFromJson("""{"to":"0x11","value":1,"nonce":0}""")).bytes,
         "a governance materialization differs from a transfer's (schema-bound)"
echo "1. add-driver is schema-bound governance OK"

# 2. Before the room approves it, only the FOUNDING kinds are admitted.
block:
  let ev = @[proposeEvent(id, addDriverJson), contributeEvent(id, "A", endorse(a))]
  let kinds = roomDriverKinds(ev, foldDrv)
  doAssert "safe" in kinds and "threshold" in kinds, "the founding set is always present"
  doAssert "unanimous" notin kinds,
           "an un-approved (only-collecting) add-driver grants nothing"
echo "2. a collecting add-driver admits no new capability OK"

# 3. The group APPROVES it (threshold met) → "unanimous" is admitted to the room.
block:
  let ev = @[proposeEvent(id, addDriverJson),
             contributeEvent(id, "A", endorse(a)),
             contributeEvent(id, "B", endorse(b))]
  doAssert intentState(ev, foldDrv, id) == "executable",
           "two endorsements approve the governance proposal"
  let kinds = roomDriverKinds(ev, foldDrv)
  doAssert "unanimous" in kinds,
           "an APPROVED add-driver admits its kind — the room's capabilities grew by proposal"
  # idempotent: folding again yields the same set, and the kind appears once.
  var once = 0
  for k in kinds:
    if k == "unanimous": inc once
  doAssert once == 1, "an admitted kind folds once"
echo "3. an approved add-driver grows the room's driver set OK"

# 4. A non-member endorsement never approves the governance proposal (so never admits).
block:
  let mal = encFromSeed(seed(9))
  proc endorseMal(): string = hex(edSign(mal, m.bytes))
  let ev = @[proposeEvent(id, addDriverJson),
             contributeEvent(id, "A", endorse(a)),
             contributeEvent(id, "mallory", endorseMal())]
  doAssert intentState(ev, foldDrv, id) != "executable",
           "a non-member cannot push the proposal to approved"
  doAssert "unanimous" notin roomDriverKinds(ev, foldDrv),
           "an unapproved proposal admits nothing — capability requires the group's agreement"
echo "4. a non-member cannot grant a capability OK"

echo "governance_test: all OK"
