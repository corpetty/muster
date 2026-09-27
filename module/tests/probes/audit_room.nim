## Shared fixture for the exo-403 probes: the exo-ef1 live room (real drivers,
## LocalTransport, the hosted propose / contribute / reannounce path) plus what an
## audit needs — pasted and mis-attested approvals, settlement with a chain reference,
## a member (Carol) admitted mid-intent, and readers for the canonical file.
## Build: see live_room.nim.

import ./live_room
import ../../src/coordination/audit
import ../../src/intents/materialization
import ../../src/dcbor/dcbor
export live_room, audit, dcbor

proc key32(hex: string): array[32, byte] =
  var h = hex
  if h.startsWith("0x"): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seedOf(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

## Carol: a room member who is NOT a signer (anvil account 3 — not a Safe owner, not
## on the threshold roster). She can read and export, never approve.
let carolKs* = newInMemoryKeystore(
  key32("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seedOf(3))

proc hexOf*(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc ksOf*(who: string): Keystore = (if who == "alice": aliceKs else: bobKs)
proc sessOf*(r: Room, who: string): CoordinationSession = (if who == "alice": r.alice else: r.bob)

proc declineAs*(r: Room, who, id: string) =
  ## The card's Deny, as the hosted module sends it: named by the member's encryption
  ## identity and signed by it (exo-f76) — an unsigned decline never reaches the room.
  r.sessOf(who).publishAuthored(ksOf(who), declineEvent(id, hexOf(ksOf(who).encIdentity().toBytes())))

proc messageAs*(r: Room, who: string, ts: int64, body: string, nonce: uint64) =
  ## A chat line, authored and signed as the hosted module posts it (exo-f76).
  let (_, m) = newMessageEvent(hexOf(ksOf(who).encIdentity().toBytes()), ts, body, nonce)
  r.sessOf(who).publishAuthored(ksOf(who), m)

proc pasteAs*(r: Room, who, policy, id: string): string =
  ## An approval made OUTSIDE muster: the member's key signs the materialization
  ## directly (a hardware wallet would), and the signature is pasted in.
  let ks = ksOf(who)
  let mat = canonicalize(liveDriverFor(policy), effectFromJson(effectJsonOf(r.events(), id)))
  var sig = ""
  if policy == "safe":
    var h: array[32, byte]
    for i in 0 ..< 32: h[i] = mat.bytes[i]
    sig = hexOf(ks.sign(h))
  else: sig = hexOf(ks.edSign(mat.bytes))
  liveContribute(r.sessOf(who), ks, liveDriverFor, id, sig, "", bindCtx(), Now)

proc misattestAs*(r: Room, who, policy, id: string) =
  ## A pasted approval that also carries a bogus attestation: the fold rejects it.
  discard r.pasteAs(who, policy, id)
  let sigs = sigEventsFor(r.events(), id)
  let w = sigs[^1].key.split('/')[3]
  r.sessOf(who).publish(attestEvent(id, w, 1, "0x" & "cd".repeat(65)))

const ChainRef* = "0x" & "5e".repeat(32)

proc settle*(r: Room, id: string, final = true) =
  r.alice.publish(submitEvent(id, chainRef = ChainRef))
  if final: r.alice.publish(finalEvent(id, chainRef = ChainRef))

proc exportAs*(r: Room, who, id: string): AuditResult =
  exportAudit(r.sessOf(who).log.allEvents(), liveDriverFor, id, ksOf(who))

# ── Carol joins mid-intent: request → alice admits (re-key) → alice re-announces ──
proc joinCarol*(r: var Room): CoordinationSession =
  let carol = newCoordinationSession(newLocalTransport(r.net), newEpochJoiner(carolKs), r.topic)
  carol.requestJoin(carolKs.bindingFor(bindCtx()))
  r.alice.poll()
  r.alice.admit(carolKs.encIdentity())
  r.bob.poll(); carol.poll()
  discard liveReannounce(r.alice, aliceKs, liveDriverFor, int64(Now), r.seqNo)
  r.bob.poll(); carol.poll()
  carol

# ── reading the canonical file ────────────────────────────────────────────────
proc fileOf*(a: AuditResult): CborValue = decode(a.bytes)
proc txt*(v: CborValue): string = (if v.kind == ckText: v.t else: "")
proc arrOf*(v: CborValue): seq[CborValue] = (if v.kind == ckArray: v.arr else: @[])
proc lineageKeys*(f: CborValue): seq[string] =
  for e in f.field("lineage").arrOf: result.add e.field("key").txt
proc lineageIds*(f: CborValue): seq[string] =
  for e in f.field("lineage").arrOf: result.add e.field("id").txt
proc approvalGradesOf*(f: CborValue): seq[(string, string)] =
  for a in f.field("approvals").arrOf: result.add (a.field("who").txt, a.field("grade").txt)
