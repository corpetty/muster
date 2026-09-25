## Regression: a malformed 65-byte signature is REJECTED, never fatal.
##
## First found driving approve() through the cdylib ABI with a garbage signature: a
## recovery id outside 0..3 reached libsecp256k1's parse_compact and tripped its
## illegal-argument callback, which calls abort() — an uncatchable process kill (DoS
## on a hostile contribution). nim-secp256k1 (ADR-014) now refuses the recovery id
## itself, but as a raised Secp256k1Error — and nothing between the log and the
## driver catches it, so ONE hostile approval in the log made reduce(log) raise for
## every member of the room (invariant 4), and one hostile join-request binding broke
## the admit list. The rule this test holds: a malformed signature is simply not a
## valid one — the verifier returns false / "" / a refusal, the fold leaves it
## uncounted, and the room still converges.
##
## Needs the secp closure + libsodium — see tests/README.md.

import std/strutils
import ../src/crypto/secp256k1
import ../src/crypto/curve25519
import ../src/crypto/binding
import ../src/crypto/keystore
import ../src/intents/authorization
import ../src/intents/materialization
import ../src/coordination/intents
import ../src/drivers/driver as drivercore
import ../src/drivers/eip191
import ../src/drivers/safe

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# An owner keypair for the valid-path sanity checks.
var sk: array[32, byte]
for i in 0 ..< 32: sk[i] = byte(i + 1)
let owner = addressOf(sk)

var hash: array[32, byte]
for i in 0 ..< 32: hash[i] = 0xAB'u8

# Every out-of-range v byte — the abort window was v in {4..26} ∪ {31..255}.
const badV = [4'u8, 5, 12, 26, 31, 64, 100, 200, 255]

# 1. A valid owner signature still recovers (the fix doesn't break the happy path).
let good = signRecoverable(hash, sk)
doAssert recoversToOwner(hash, good, @[owner]), "valid owner signature must recover"

# 2. Every out-of-range v byte must be rejected gracefully, never raise or crash.
for v in badV:
  var s = good
  s[64] = v
  doAssert not recoversToOwner(hash, s, @[owner]),
    "v=" & $v & " must be rejected without aborting"

# 3. Valid recid but all-zero r/s — recovery fails cleanly → not an owner.
var garbage: Signature65
garbage[64] = 27                       # recid 0, in range; r/s are zero
doAssert not recoversToOwner(hash, garbage, @[owner]), "garbage r/s must be rejected"

# 4. A valid signature must not recover to a DIFFERENT owner set.
var sk2: array[32, byte]
for i in 0 ..< 32: sk2[i] = byte(i + 100)
doAssert not recoversToOwner(hash, good, @[addressOf(sk2)]),
  "a signature must not recover to a non-signer"
echo "1-4. recoversToOwner: every malformed signature rejected, the valid one recovers OK"

# 5. The drivers that read owner signatures: a malformed contribution is not valid
#    and identifies no one — the answer the fold keys on.
block:
  var bad = good
  bad[64] = 4
  let m = Materialization(bytes: @hash)
  let safeDrv = newSafeDriver(31337, owner, owners = @[owner], threshold = 1)
  safeDrv.expectMaterialization(m)
  doAssert not safeDrv.verifyContribution(Contribution(bytes: @bad), 1)
  doAssert safeDrv.identifyContributor(m, Contribution(bytes: @bad)) == ""
  doAssert safeDrv.verifyContribution(Contribution(bytes: @good), 1)
  let psDrv = newPersonalSignDriver(signers = @[owner], threshold = 1)
  psDrv.expectMaterialization(m)
  doAssert not psDrv.verifyContribution(Contribution(bytes: @bad), 1)
  doAssert psDrv.identifyContributor(m, Contribution(bytes: @bad)) == ""
  echo "5. Safe + EIP-191 drivers: a malformed contribution is not valid and names no one OK"

# 6. The fold: a hostile member publishes a malformed approval (no attestation, so it
#    reaches the driver). reduce(log) must not raise, must not count it, and the room
#    must still reach executable on the honest approvals.
block:
  var skA, skB: array[32, byte]
  for i in 0 ..< 32: (skA[i] = byte(i + 1); skB[i] = byte(i + 50))
  let foldDrv: DriverFor = proc(kind: string): drivercore.Driver =
    newPersonalSignDriver(signers = @[addressOf(skA), addressOf(skB)], threshold = 2)
  const effectJson = """{"effect":"statement","text":"a hostile approval must not break the room"}"""
  let id = intentIdFor(effectJson, "eip191")
  let mat = canonicalize(foldDrv("eip191"), effectFromJson(effectJson))
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = mat.bytes[i]
  var hostile = signRecoverable(h, skA)
  hostile[64] = 4
  var events = @[policyDeclEvent(id, "eip191"), proposeEvent(id, effectJson),
                 contributeEvent(id, "0xattacker", hexOf(hostile)),
                 contributeEvent(id, hexOf(addressOf(skA)), hexOf(signRecoverable(h, skA)))]
  doAssert intentState(events, foldDrv, id) == "collecting",
    "one honest approval of two; the malformed one is not counted"
  events.add contributeEvent(id, hexOf(addressOf(skB)), hexOf(signRecoverable(h, skB)))
  doAssert intentState(events, foldDrv, id) == "executable",
    "the room still converges past a hostile approval"
  echo "6. the fold: a malformed approval in the log is uncounted, the room converges OK"

# 7. A join-request binding carrying a malformed signature does not bind (the admit
#    list reads bindingBinds for every pending requester).
block:
  var seed7: array[32, byte]
  for i in 0 ..< 32: seed7[i] = 7
  let enc = encFromSeed(seed7).identity()
  let ctx = LinkContext(account: "0x5FbD...safe", slot: "0", expiry: 1000)
  var st = issueBinding(proc(h: array[32, byte]): Signature65 = signRecoverable(h, sk), enc, ctx)
  doAssert bindingBinds(st, @[owner], now = 0), "the well-formed binding binds"
  for v in badV:
    st.sig[64] = v
    doAssert not bindingBinds(st, @[owner], now = 0), "v=" & $v & " binding must not bind"
  echo "7. binding: a malformed link signature does not bind, no raise OK"

# 8. An authorization whose signature is malformed is REFUSED with a reason (the
#    refuse-on-mismatch check), never raised out of the verifier.
block:
  var s1, s2: array[32, byte]
  for i in 0 ..< 32: (s1[i] = 7; s2[i] = 8)
  let ks = newInMemoryKeystore(s1, s2)
  var a = issueAuthorization(ks, "0xabc", "safe.execute", "chain:31337", "safe:0x5fbd",
                             @[1'u8, 2, 3, 4], 1_000)
  doAssert checkAuthorization(a, now = 500).ok, "the well-formed grant verifies"
  for v in badV:
    a.signature[64] = v
    let r = checkAuthorization(a, now = 500)
    doAssert not r.ok and r.reason.len > 0, "v=" & $v & " grant must be refused with a reason"
  echo "8. authorization: a malformed grant signature is refused, no raise OK"

echo "malformed_sig: every malformed signature rejected — none fatal, the room converges"
