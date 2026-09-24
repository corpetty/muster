## The live room signing path — the exact code the hosted coordinate_* methods run,
## lifted out of the module glue so it can be driven in-process (exo-ef1).
##
## Why this file exists: invariant 10's machinery lived in the core model and was
## proven there, while the path a real approval takes lived inline in
## nim-lib/muster_module.nim behind module globals, where no probe could reach it —
## so the model stayed green while the live path never called it. Everything the
## glue does on propose / contribute is here, parameterized by the session, the
## keystore, and the driver resolver; the glue is thin plumbing over it.

import std/[json, tables, strutils]
import ../log/log
import ../crypto/keystore
import ../crypto/binding
import ../crypto/curve25519
import ../drivers/driver
import ../drivers/safe
import ../drivers/eip191
import ../drivers/kinds      # supported(): refuse a kind this client has no driver for
import ../drivers/profile    # the family profile: what settles, and where
import ../drivers/inapp      # in-app signing as a driver hook (exo-a50.2.4)
import ../drivers/interop    # signers outside muster (exo-a50.2.6)
import ../intents/materialization
import ../intents/lifecycle
import ../intents/signing_payload
import ./session
import ./intents
import ./attest

proc hex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

const DefaultIntentTtl* = 7'i64 * 24 * 3600
  ## How long a proposal stays signable when the proposer names no lifetime.

proc liveProposeIntent*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor,
                        policy, effectJson: string, nowSec: int64, msgSeq: uint64,
                        account: string, ttlSec = DefaultIntentTtl): string =
  ## Propose an intent into the room: declare its policy, publish the propose and the
  ## context every attestation on it binds to (invariant 2: the driver's environment,
  ## `account` — the Safe, or the room for a room-native decision — the intent id as
  ## the slot, and an expiry `ttlSec` from now), and announce it into the thread as an
  ## intent-ref card. Returns the intent id.
  # The intent id commits to its policy, so the SAME effect under two policies is two
  # distinct intents (an intent is a policy boundary). The policy is declared in the
  # log keyed by that id, so every member folds this intent under the same driver.
  # A kind this client has no driver for is refused — never proposed under a guess
  # (exo-a50.1.2): nobody here could verify a contribution to it.
  if not driverFor(policy).supported(): return "unsupported-driver"
  # The driver's own gate (exo-a50.1.4): e.g. a Safe delegatecall to a target this
  # client has not allowlisted is never put in front of the room.
  let refusal = driverFor(policy).signRefusal(effectFromJson(effectJson))
  if refusal.len > 0: return "refused: " & refusal
  let id = intentIdFor(effectJson, policy)
  s.publish(policyDeclEvent(id, policy))
  s.publish(proposeEvent(id, effectJson))
  let ttl = (if ttlSec > 0: ttlSec else: DefaultIntentTtl)
  s.publish(contextEvent(id, SigningContext(
    environment: driverFor(policy).environment(), account: account, slot: id,
    expiry: uint64(max(0'i64, nowSec) + ttl))))
  # Announce the proposal INTO the conversation: a reference card, authored and
  # timestamped like any message, so the proposal appears inline in the thread. The
  # card is a positional reference, never the source of truth.
  let author = hex0x(ks.encIdentity().toBytes())
  let refBody = $(%*{"kind": "intent-ref", "intentId": id})
  let (_, ev) = newMessageEvent(author, nowSec, refBody, msgSeq)
  s.publish(ev)
  id

proc liveContribute*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor,
                     intentId, signatureHex, keyRef: string,
                     bindingCtx: LinkContext, nowSec: uint64 = 0): string =
  ## Add a contribution to a proposed intent. If `signatureHex` is EMPTY, sign in-app
  ## with the keystore — no paste: the room-native drivers (threshold/frost/invoke)
  ## endorse with the Ed25519 encryption key, Safe/eip191 sign the 32-byte digest with
  ## the secp key. `keyRef` selects WHICH held key signs (exo-45e K2b/K5); an empty
  ## ref uses the primary key. The secret never leaves the keystore. Returns the
  ## intent's state after the contribution, or a refusal word.
  ##
  ## Invariants 2 + 10 on the live path (exo-ef1): nothing is published after the
  ## intent's declared expiry, and an IN-APP approval is refused outright — nothing
  ## published — unless the intent has a real context and every input that reached
  ## its bytes can be accounted for. Every in-app approval then carries a muster
  ## attestation from the SAME key over P (attest.nim). A pasted signature was made
  ## outside muster: it is published as-is and graded unattested, never shown as
  ## committed.
  s.poll()
  let events = s.log.allEvents()
  let drv = driverFor(intentPolicyOf(events, intentId))   # THIS intent's own policy
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return "unknown-intent"
  # Under a kind this client has no driver for, nothing is signed or published: which
  # key, which bytes, what would count — none of it is known (exo-a50.1.2).
  if not drv.supported(): return "unsupported-driver"
  # The driver's own gate on THIS client's signature (exo-a50.1.4): an in-app approval
  # of, e.g., a Safe delegatecall to an unallowlisted target is refused, publishing
  # nothing. A pasted signature was made elsewhere; it is folded (and graded) as usual.
  if signatureHex.len == 0:
    let refusal = drv.signRefusal(effectFromJson(effectJson))
    if refusal.len > 0: return "refused: " & refusal
  let ctx = intentContext(events, intentId)
  if not ctx.isPlaceholder and ctx.expired(nowSec): return "expired"
  let inApp = signatureHex.len == 0
  var p: seq[byte]
  if inApp:
    if ctx.isPlaceholder: return "no-context"
    if not intentInputs(events, driverFor, intentId).allAccountable: return "unaccountable-input"
    p = attestationPayload(events, driverFor, intentId)
    if p.len == 0: return "unaccountable-input"
  var sig = signatureHex
  var inAppSecpRef = ""   # nonempty iff we secp-signed IN-APP: publish that key's F-14 binding
  var attestHex = ""      # the muster attestation over P, made with the same key (in-app only)
  if sig.len == 0:
    let mat = canonicalize(drv, effectFromJson(effectJson))
    # An unknown ref is refused — never a silent fall-through to a different key than
    # the caller chose (K2b). An empty ref means the primary key.
    if keyRef.len > 0 and not ks.hasKey(keyRef): return "unknown-key"
    # A driver that signs in-app itself (a Bitcoin multisig: DER / Schnorr per input,
    # exo-a50.2.4) does so through the keystore seam; the rest are signed below.
    let hook = drv.signInApp(effectFromJson(effectJson), ks, attestationDigest(p))
    if hook.handled:
      # the hook signs with the key it names; a caller who chose another is refused
      if keyRef.len > 0 and keyRef != hook.keyRef: return "unknown-key"
      sig = hex0x(hook.contribution)
      attestHex = hex0x(hook.attestation)
      inAppSecpRef = hook.keyRef
    elif drv of SafeDriver or drv of PersonalSignDriver:
      var h: array[32, byte]
      for i in 0 ..< min(32, mat.bytes.len): h[i] = mat.bytes[i]
      sig = hex0x(if keyRef.len > 0: ks.signWith(keyRef, h) else: ks.sign(h))
      let d = attestationDigest(p)
      attestHex = hex0x(if keyRef.len > 0: ks.signWith(keyRef, d) else: ks.sign(d))
      inAppSecpRef = (if keyRef.len > 0: keyRef else: refOf(ks.address()))
    else:
      sig = hex0x(if keyRef.len > 0: ks.edSignWith(keyRef, mat.bytes) else: ks.edSign(mat.bytes))
      attestHex = hex0x(if keyRef.len > 0: ks.edSignWith(keyRef, p) else: ks.edSign(p))
  # The intent's policy verifies the contribution — "" iff it isn't a valid one.
  let who = contributorOf(drv, effectJson, sig)
  if who.len == 0: return "rejected"
  # Tag the contribution with the round this intent is currently collecting, so a
  # multi-round driver (FROST) can have the same member contribute once per round.
  let folded = reduceIntents(events, driverFor)
  let curRound = (if intentId in folded: folded[intentId].collection.round else: 1)
  # A muster attestation that doesn't verify as the recovered contributor would be
  # rejected by every member's fold — refuse it here rather than publish it.
  if inApp and not verifyAttestation(who, p, attestHex): return "attestation-mismatch"
  # Link the approval to the proposal and to every approval its signer has seen
  # (exo-403): a member who later reads this approval but not those can tell its
  # history reaches events it cannot read, instead of mistaking a partial view for
  # the whole one. Content-addressed, so the fold still dedups by (who, round).
  var parents: seq[EventId]
  for e in events:
    if e.key == "intent/" & intentId & "/propose" or
       e.key.startsWith("intent/" & intentId & "/sig/"):
      parents.add eventId(e)
  let sigEv = contributeEvent(intentId, who, sig, round = curRound, parents = parents)
  s.publish(sigEv)
  if inApp: s.publish(attestEvent(intentId, who, curRound, attestHex, parents = @[eventId(sigEv)]))
  # F-14/K5: when we secp-signed IN-APP with a chosen owner key, publish that key's
  # binding so the room can check the approval came from an admitted member. A PASTED
  # signature gets none: we do not hold that key, so we cannot vouch for it.
  if inAppSecpRef.len > 0:
    let st = ks.bindingForKey(inAppSecpRef, bindingCtx)
    s.publish(keyBindingEvent(intentId, who, hex0x(encodeLink(st))))
  intentState(s.log.allEvents(), driverFor, intentId)

# ── signers outside muster (exo-a50.2.6; seam S8) ────────────────────────────
type
  OutsideExport* = object
    ok*: bool
    error*: string        ## unknown-intent | unsupported-driver | no-outside-format
    format*: string       ## "psbt"
    encoded*: string      ## what the outside signer takes

  OutsideImport* = object
    ok*: bool
    error*: string        ## unknown-intent | unsupported-driver | not-readable | not-this-spend |
                          ## no-signatures | a refusal from the contribution (expired, rejected)
    detail*: string
    imported*: seq[string] ## signers whose approval this import published
    already*: seq[string]  ## signers the room already had an approval from (not re-published)
    state*: string         ## the intent's state after the import

proc liveExportOutside*(s: CoordinationSession, driverFor: DriverFor, intentId: string): OutsideExport =
  ## The proposal's effect in its driver's outside-signer format (a Bitcoin spend: a
  ## PSBT). Nothing is signed or published; a driver with no such format says so.
  s.poll()
  let events = s.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return OutsideExport(error: "unknown-intent")
  let drv = driverFor(intentPolicyOf(events, intentId))
  if not drv.supported(): return OutsideExport(error: "unsupported-driver")
  let req = drv.exportOutside(effectFromJson(effectJson))
  if not req.handled: return OutsideExport(error: "no-outside-format")
  OutsideExport(ok: true, format: req.format, encoded: req.encoded)

proc liveImportOutside*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor,
                        intentId, encoded: string, bindingCtx: LinkContext,
                        nowSec: uint64 = 0): OutsideImport =
  ## An outside signer's response: the DRIVER reads every contribution in it (verified
  ## like a native one), and each is published as a PASTED approval — it counts toward
  ## the threshold and every member grades it unattested ("signed outside muster"),
  ## never committed. A response to a different effect is refused whole, publishing
  ## nothing; a signer the room already has an approval from is not re-published.
  s.poll()
  let events = s.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return OutsideImport(error: "unknown-intent")
  let drv = driverFor(intentPolicyOf(events, intentId))
  if not drv.supported(): return OutsideImport(error: "unsupported-driver")
  var got: seq[ImportedContribution]
  try: got = drv.importOutside(effectFromJson(effectJson), encoded)
  except InteropMismatch as e: return OutsideImport(error: "not-this-spend", detail: e.msg)
  except InteropError as e: return OutsideImport(error: "not-readable", detail: e.msg)
  if got.len == 0:
    return OutsideImport(error: "no-signatures",
                         detail: "it carries no signature by one of the account's keys over the whole proposal")
  for (signer, c) in got:
    var seen = false
    for e in events:
      if e.key.startsWith("intent/" & intentId & "/sig/" & signer): seen = true
    if seen:
      result.already.add signer
      continue
    let st = liveContribute(s, ks, driverFor, intentId, hex0x(c.bytes), "", bindingCtx, nowSec)
    if st in ["unknown-intent", "unsupported-driver", "expired", "rejected"]:
      result.error = st
      result.detail = "the approval by " & signer & " was not added"
      result.state = intentState(s.log.allEvents(), driverFor, intentId)
      return
    result.imported.add signer
  result.ok = true
  result.state = intentState(s.log.allEvents(), driverFor, intentId)

proc liveSubmitPrecheck*(s: CoordinationSession, driverFor: DriverFor,
                         intentId: string, nowSec: uint64 = 0): string =
  ## What must hold before a room intent is settled: "" when it may proceed, else the
  ## refusal. Only a Safe-policy intent settles on-chain, and only once executable.
  s.poll()
  let events = s.log.allEvents()
  let policy = intentPolicyOf(events, intentId)
  # what settles is the family's own settlement (exo-a50.1.5): a family whose profile
  # settles nowhere (a room family) has nothing to put on-chain — read, never a string
  if driverFor(policy).profile().settlement == "none" or not driverFor(policy).supported():
    return "not-onchain"
  if intentState(events, driverFor, intentId) != "executable": return "not-executable"
  let ctx = intentContext(events, intentId)
  if ctx.isPlaceholder: return "no-context"
  if ctx.expired(nowSec): return "expired"
  ""

proc liveReannounce*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor,
                     nowSec: int64, msgSeq: var uint64): int =
  ## Re-publish every still-OPEN intent — its policy declaration, its propose, its
  ## signing context and recorded reads, and its thread card — into the CURRENT epoch.
  ## A member admitted after a proposal was made can't read anything from before their
  ## epoch (F-16), so without this they could neither fold the intent nor attest to it.
  ## Content-addressed, so re-publishing is idempotent (same ids) — it only re-seals the
  ## events under the new epoch. Approvals are NOT re-shared: what members signed
  ## before the joiner arrived stays in its epoch. Returns how many were re-announced.
  s.poll()
  let events = s.log.allEvents()
  let folded = reduceIntents(events, driverFor)
  let author = hex0x(ks.encIdentity().toBytes())
  for id, it in folded:
    if $it.state in ["final", "submitted", "settling"]: continue
    let effect = effectJsonOf(events, id)
    if effect.len == 0: continue
    s.publish(policyDeclEvent(id, intentPolicyOf(events, id)))
    s.publish(proposeEvent(id, effect))
    for e in events:
      if e.key == "intent/" & id & "/context" or e.key.startsWith("intent/" & id & "/read/"):
        s.publish(e)
    inc msgSeq
    let refBody = $(%*{"kind": "intent-ref", "intentId": id})
    let (_, ev) = newMessageEvent(author, nowSec, refBody, msgSeq)
    s.publish(ev)
    inc result
