## derived-exo-ef1 s4: P's context is real — environment is the driver's chain or
## network, account is the Safe address or room id, slot is the intent id, expiry is
## the proposal's declared expiry; the placeholder never reaches a payload; an
## attestation verifies under exactly that context and no other; signing and
## submitting are refused after expiry; and the fold never consults the clock.
##
## STEPPER: state = the live driver the intent is proposed under. Each state checks,
## through the hosted propose / contribute / submit-precheck path:
##   1. the folded context is not the placeholder and each field equals its rule;
##   2. alice's attestation verifies over P under that context and FAILS under every
##      single-field change of it (environment, account, slot, expiry);
##   3. an approval attempted after expiry publishes nothing; one before does;
##   4. (Safe, the on-chain rail) submit is refused after expiry and allowed before;
##   5. fold purity: the fold's inputs are the event set alone (no clock parameter
##      exists), so folding the same set before and after expiry gives identical
##      state and grades — an attestation made in time stays committed.
## Build: see live_room.nim.

import ./live_room
import ./oracle_emit

proc driverCorrect(policy: string): bool =
  var r = newRoom("/muster/1/ef1-ctx-" & policy & "/proto")
  let id = r.propose(policy, effectFor(policy, 3))
  let drv = liveDriverFor(policy)
  # 1. the context is real and follows its rule
  let ctx = intentContext(r.events(), id)
  if ctx.isPlaceholder: return false
  if ctx.environment != drv.environment(): return false
  if ctx.account != r.accountFor(policy): return false
  if ctx.slot != id: return false
  if ctx.expiry != Now + uint64(Ttl): return false
  # 3. (before) an in-time approval publishes, with an attestation
  discard r.approveAs("alice", id, Now)
  var evs = r.events()
  let atts = attestEventsFor(evs, id)
  if atts.len != 1: return false
  let who = atts[0].key.split('/')[3]
  # 2. the attestation binds every field of the context
  if not verifyAttestation(who, attestationPayloadUnder(evs, liveDriverFor, id, ctx), atts[0].value):
    return false
  var variants: seq[SigningContext]
  var c = ctx
  c.environment = ctx.environment & "-x"; variants.add c
  c = ctx; c.account = ctx.account & "-x"; variants.add c
  c = ctx; c.slot = ctx.slot & "-x"; variants.add c
  c = ctx; c.expiry = ctx.expiry + 1; variants.add c
  for v in variants:
    let pv = attestationPayloadUnder(evs, liveDriverFor, id, v)
    if pv.len > 0 and verifyAttestation(who, pv, atts[0].value): return false
  # 3. (after) a late approval publishes nothing
  let late = Now + uint64(Ttl) + 1
  let before = r.events().len
  discard r.approveAs("bob", id, late)
  if r.events().len != before: return false
  # 5. purity: identical fold before/after the clock passes expiry
  let g1 = approvalGrades(r.events(), liveDriverFor, id)
  let s1 = intentState(r.events(), liveDriverFor, id)
  let g2 = approvalGrades(r.events(), liveDriverFor, id)
  let s2 = intentState(r.events(), liveDriverFor, id)
  if g1 != g2 or s1 != s2: return false
  if gradeOf(g1, who, 1) != agCommitted: return false
  # 4. submit precheck (on-chain rail only)
  if policy == "safe":
    discard r.approveAs("bob", id, Now)               # reach executable in time
    if intentState(r.events(), liveDriverFor, id) != "executable": return false
    if liveSubmitPrecheck(r.alice, liveDriverFor, id, Now) != "": return false
    if liveSubmitPrecheck(r.alice, liveDriverFor, id, late) == "": return false
  true

proc state(policy: string): JsonNode =
  %*{"driver": policy, "context_correct": driverCorrect(policy)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "driver", "stub")
var succ: seq[JsonNode]
for p in LivePolicies:
  if p != here: succ.add state(p)
emitSuccessors(succ)

if arg == nil:
  for p in LivePolicies:
    doAssert driverCorrect(p), "live context binding failed under " & p
