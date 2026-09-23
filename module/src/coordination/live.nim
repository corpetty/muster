## The live room signing path — the exact code the hosted coordinate_* methods run,
## lifted out of the module glue so it can be driven in-process (exo-ef1).
##
## Why this file exists: invariant 10's machinery lived in the core model and was
## proven there, while the path a real approval takes lived inline in
## nim-lib/muster_module.nim behind module globals, where no probe could reach it —
## so the model stayed green while the live path never called it. Everything the
## glue does on propose / contribute is here, parameterized by the session, the
## keystore, and the driver resolver; the glue is thin plumbing over it.

import std/[json, tables]
import ../log/log
import ../crypto/keystore
import ../crypto/binding
import ../crypto/curve25519
import ../drivers/driver
import ../drivers/safe
import ../drivers/eip191
import ../intents/materialization
import ../intents/lifecycle
import ./session
import ./intents

proc hex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc liveProposeIntent*(s: CoordinationSession, ks: Keystore, policy, effectJson: string,
                        nowSec: int64, msgSeq: uint64, account = "", ttlSec = 0'i64): string =
  ## Propose an intent into the room: declare its policy, publish the propose, and
  ## announce it into the thread as an intent-ref card. Returns the intent id.
  # The intent id commits to its policy, so the SAME effect under two policies is two
  # distinct intents (an intent is a policy boundary). The policy is declared in the
  # log keyed by that id, so every member folds this intent under the same driver.
  let id = intentIdFor(effectJson, policy)
  s.publish(policyDeclEvent(id, policy))
  s.publish(proposeEvent(id, effectJson))
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
  s.poll()
  let events = s.log.allEvents()
  let drv = driverFor(intentPolicyOf(events, intentId))   # THIS intent's own policy
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return "unknown-intent"
  var sig = signatureHex
  var inAppSecpRef = ""   # nonempty iff we secp-signed IN-APP: publish that key's F-14 binding
  if sig.len == 0:
    let mat = canonicalize(drv, effectFromJson(effectJson))
    # An unknown ref is refused — never a silent fall-through to a different key than
    # the caller chose (K2b). An empty ref means the primary key.
    if keyRef.len > 0 and not ks.hasKey(keyRef): return "unknown-key"
    if drv of SafeDriver or drv of PersonalSignDriver:
      var h: array[32, byte]
      for i in 0 ..< min(32, mat.bytes.len): h[i] = mat.bytes[i]
      sig = hex0x(if keyRef.len > 0: ks.signWith(keyRef, h) else: ks.sign(h))
      inAppSecpRef = (if keyRef.len > 0: keyRef else: refOf(ks.address()))
    else:
      sig = hex0x(if keyRef.len > 0: ks.edSignWith(keyRef, mat.bytes) else: ks.edSign(mat.bytes))
  # The intent's policy verifies the contribution — "" iff it isn't a valid one.
  let who = contributorOf(drv, effectJson, sig)
  if who.len == 0: return "rejected"
  # Tag the contribution with the round this intent is currently collecting, so a
  # multi-round driver (FROST) can have the same member contribute once per round.
  let folded = reduceIntents(events, driverFor)
  let curRound = (if intentId in folded: folded[intentId].collection.round else: 1)
  s.publish(contributeEvent(intentId, who, sig, round = curRound))
  # F-14/K5: when we secp-signed IN-APP with a chosen owner key, publish that key's
  # binding so the room can check the approval came from an admitted member. A PASTED
  # signature gets none: we do not hold that key, so we cannot vouch for it.
  if inAppSecpRef.len > 0:
    let st = ks.bindingForKey(inAppSecpRef, bindingCtx)
    s.publish(keyBindingEvent(intentId, who, hex0x(encodeLink(st))))
  intentState(s.log.allEvents(), driverFor, intentId)

proc liveSubmitPrecheck*(s: CoordinationSession, driverFor: DriverFor,
                         intentId: string, nowSec: uint64 = 0): string =
  ## What must hold before a room intent is settled: "" when it may proceed, else the
  ## refusal. Only a Safe-policy intent settles on-chain, and only once executable.
  s.poll()
  let events = s.log.allEvents()
  let policy = intentPolicyOf(events, intentId)
  if policy != "safe": return "not-onchain"
  if intentState(events, driverFor, intentId) != "executable": return "not-executable"
  ""
