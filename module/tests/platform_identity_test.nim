## The room identity held by the platform (exo-833): PlatformIdentityKeystore over a fake
## signer_manager_module that answers as the real one does (corpetty/logos-signer-manager-module
## feat/ed25519-record, held end to end by its doctests/identity-e2e.sh). The fake is backed by a
## local identity, so every answer must be byte for byte what a local keystore with the same key
## gives: the platform moves where the key lives, never what is signed.

import std/[json, strutils, tables]
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/crypto/binding
import ../src/crypto/join_request
import ../src/crypto/platform_identity
import ../src/hashing/hash_input
import ../src/hashing/sha256
import ../src/dcbor/dcbor

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add toHex(x.int, 2).toLowerAscii()

proc bytesOf(h: string): seq[byte] =
  for i in countup(0, h.len - 1, 2): result.add byte(parseHexInt(h[i .. i + 1]))

type FakeManager = ref object
  keys: EncKeys
  unlocked: bool
  results: Table[string, seq[string]]
  calls: seq[string]
  seq: int

proc port(m: FakeManager): ManagerPort =
  result = proc(meth: string, args: JsonNode): JsonNode =
    m.calls.add meth
    case meth
    of "request_approval":
      let intent = parseJson(args[0].getStr())
      if intent["identity"].getStr() != hexOf(m.keys.identity().ed):
        return %*{"ok": false, "error": "no signer offers the account"}
      var answers: seq[string]
      for leg in intent["legs"]:
        case leg["kind"].getStr()
        of "record":
          let rec = bytesOf(leg["record"].getStr())
          answers.add hexOf(m.keys.edSign(sha256(rec)))
        of "open": answers.add hexOf(m.keys.sealOpen(bytesOf(leg["sealed"].getStr())))
        of "secret": answers.add hexOf(m.keys.derivedSecret(bytesOf(leg["record"].getStr())))
        else: return %*{"ok": false, "error": "unknown leg"}
      inc m.seq
      let h = "smh_" & $m.seq
      m.results[h] = answers
      %*{"ok": true, "handle": h, "receipt": "smc_" & $m.seq,
         "state": (if m.unlocked: "settled" else: "offered")}
    of "fetch_result":
      %*{"ok": true, "signed": m.results.getOrDefault(args[0].getStr())}
    of "ack_result", "cancel_approval": %*{"ok": true}
    else: nil

var s1, idSeed, otherSeed: array[32, byte]
s1[0] = 1
idSeed[0] = 7
otherSeed[0] = 9
let local = newInMemoryKeystore(s1, idSeed)          # what muster would hold today
let inner = newInMemoryKeystore(s1, otherSeed)       # the authorization key, with an unrelated identity
let mgr = FakeManager(keys: encFromSeed(idSeed), unlocked: true)
let pk = hexOf(encFromSeed(idSeed).identity().ed)
let ks = newPlatformIdentityKeystore(inner, mgr.port(), pk)
let room = "/muster/1/room-a/proto"

block:
  # 1. The identity is the platform's, the authorization key the wrapped keystore's.
  doAssert ks.encIdentity() == local.encIdentity(), "the identity, Ed25519 and its X25519 form"
  doAssert ks.encIdentity() != inner.encIdentity()
  doAssert ks.address() == inner.address()
  echo "1. the identity is the platform key's; the authorization key stays local OK"

block:
  # 2. A record is signed through the manager, byte for byte as a local keystore signs it.
  let hi = hashInput("muster.event.author.v1", @[("room", cbText(room)), ("n", cbUint(3))])
  doAssert ks.edSignRecord(hi) == local.edSignRecord(hi)
  let jr = ks.joinRequestFor(room, 1_000)
  doAssert joinRequestValid(jr, room, 0) and jr.sig == local.joinRequestFor(room, 1_000).sig
  doAssert mgr.calls[0 .. 2] == @["request_approval", "fetch_result", "ack_result"]
  echo "2. records signed through the manager equal the local signatures OK"

block:
  # 3. A grant sealed to the identity opens through the manager; the founding key is the same.
  let boxed = sealTo(ks.encIdentity().x, @[1'u8, 2, 3])
  doAssert ks.sealOpen(boxed) == @[1'u8, 2, 3]
  doAssert ks.foundingKey(room) == local.foundingKey(room)
  echo "3. sealed grants open, and the founding key matches, through the manager OK"

block:
  # 4. The binding vouches for the platform identity with the local authorization key (F-14).
  let ctx = LinkContext(account: room, slot: "0", expiry: 1_000)
  let st = ks.bindingFor(ctx)
  doAssert st.enc == ks.encIdentity() and bindingBinds(st, @[inner.address()], now = 0)
  echo "4. the binding binds the authorization key to the platform identity OK"

block:
  # 5. Locked: the request is cancelled, never waited on, and the refusal says what to do.
  mgr.unlocked = false
  mgr.calls = @[]
  var msg = ""
  try: discard ks.edSignRecord(hashInput("muster.event.author.v1", @[("n", cbUint(4))]))
  except KeystoreError as e: msg = e.msg
  doAssert msg.startsWith("identity-locked"), msg
  doAssert mgr.calls == @["request_approval", "cancel_approval"]
  doAssert ks.locked, "the refusal is remembered, so the status can offer the unlock"
  mgr.unlocked = true
  discard ks.edSignRecord(hashInput("muster.event.author.v1", @[("n", cbUint(5))]))
  doAssert not ks.locked, "a request that settles again clears it"
  echo "5. a locked identity is refused with its remedy, its request cancelled OK"

block:
  # 6. Raw bytes are refused: the platform signs only records it can show.
  var refused = false
  try: discard ks.edSign(@[1'u8, 2])
  except KeystoreError: refused = true
  doAssert refused
  # A manager that does not answer is an error, never a zero.
  let silent = newPlatformIdentityKeystore(inner, (proc(m: string, a: JsonNode): JsonNode = nil), pk)
  refused = false
  try: discard silent.foundingKey(room)
  except KeystoreError: refused = true
  doAssert refused
  echo "6. raw bytes and a silent manager are refused OK"

block:
  # 7. Asking the person: the key and the unlock are the manager's access requests, decided in
  # the keys app. Muster asks for its own key, unlocked for muster alone without a prompt, and
  # reads where the ask stands without waiting: waiting, done once (collected and acknowledged),
  # or ended with nothing to collect.
  var calls: seq[string]
  var asked: JsonNode
  var step = "offered"
  var answer = newJNull()
  let access = proc(meth: string, args: JsonNode): JsonNode =
    calls.add meth
    case meth
    of "request_identity", "request_unlock":
      asked = parseJson(args[0].getStr())
      %*{"ok": true, "handle": "acc_1", "receipt": "rcp_1", "state": "offered"}
    of "approval_status":
      if args[1].getStr() != "rcp_1": return %*{"ok": false, "error": "not_authorized"}
      %*{"ok": true, "state": step, "reason": (if step == "settled" and answer.kind == JNull: %"rejected" else: newJNull())}
    of "fetch_result":
      if answer.kind == JNull: %*{"ok": false, "error": "no result for this handle"}
      else: %*{"ok": true, "result": answer}
    of "ack_result": %*{"ok": true}
    else: nil

  let a = askIdentity(access, "default")
  doAssert a.kind == "identity" and a.handle == "acc_1" and a.receipt == "rcp_1"
  doAssert asked["purpose"].getStr() == "room-identity" and asked["context"].getStr() == "default"
  doAssert asked["unlock"]["apps"] == %["muster_module"] and not asked["unlock"]["confirm"].getBool(true)
  doAssert pollAsk(access, a)["state"].getStr() == "waiting"
  step = "rendered"
  doAssert pollAsk(access, a)["step"].getStr() == "rendered"
  step = "settled"
  answer = %*{"account": "kr_00", "publicKey": pk, "context": "muster_module/default"}
  calls = @[]
  let done = pollAsk(access, a)
  doAssert done["state"].getStr() == "done" and done["result"]["publicKey"].getStr() == pk
  doAssert calls == @["approval_status", "fetch_result", "ack_result"], "collected once, then acknowledged"

  # The unlock names the account it was given, for muster alone, without a prompt.
  let u = askUnlock(access, "kr_00")
  doAssert u.kind == "unlock" and asked["account"].getStr() == "kr_00"
  doAssert asked["apps"] == %["muster_module"] and not asked["confirm"].getBool(true)
  # Rejected: settled with nothing to collect, and nothing acknowledged.
  answer = newJNull()
  calls = @[]
  let ended = pollAsk(access, u)
  doAssert ended["state"].getStr() == "ended" and ended["reason"].getStr() == "rejected", $ended
  doAssert "ack_result" notin calls
  # A request the manager no longer knows has ended; a manager that does not answer is waited on.
  doAssert pollAsk(access, PlatformAsk(kind: "unlock", handle: "acc_1", receipt: "other"))["reason"].getStr() == "unknown-request"
  let silent = proc(m: string, a: JsonNode): JsonNode = nil
  doAssert pollAsk(silent, u)["state"].getStr() == "waiting"
  var refused = false
  try: discard askIdentity(silent, "default")
  except KeystoreError: refused = true
  doAssert refused, "an ask the manager does not answer is an error, never a handle"
  echo "7. the key and its unlock are asked in the keys app, collected once, ended when refused OK"

echo "platform_identity_test: all OK"
