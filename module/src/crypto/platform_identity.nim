## The room identity held by the platform (exo-833). The member's Ed25519 identity key lives in
## the person's keystore_module, from the recovery phrase it already keeps, and muster reaches it
## only through signer_manager_module, which shows every request and checks every signature. The
## authorization key (secp256k1) and everything else stay with the keystore this one wraps.
##
## What the identity does, and how:
##   edSignRecord — a `record` leg: the manager reads the record, shows it, hashes it itself.
##   sealOpen     — an `open` leg: a sealed box addressed to the identity's X25519 form.
##   foundingKey  — a `secret` leg over the room's founding record (exo-7b3).
##   encIdentity  — the public key the person's keys app made for muster, and its X25519 form.
##
## Every call is synchronous (the Keystore seam is), so it works inside the unlock the person
## granted muster with `confirm: false`: the manager settles such a request as it arrives. A
## request it would show to the person instead is cancelled and refused with what to do, never
## waited on, since a blocked module thread stalled sends once already (exo-eb6.1).
##
## edSign over raw bytes is refused: the platform signs only records it can show (rule 2 of
## docs/design/wallet-signer-spec.md). The routine signatures go through edSignRecord; the
## approval-bearing ones (live, vote, the Monero multisig rounds) still need a local identity.

import std/[json, strutils]
import ./keystore
import ./curve25519
import ./secp256k1
import ./binding
import ../hashing/hash_input
import ../frost/chilldkg

type
  ManagerPort* = proc(meth: string, args: JsonNode): JsonNode {.closure.}
    ## One call to signer_manager_module: its method and positional arguments; its parsed reply,
    ## or nil when it did not answer.
  PlatformIdentityKeystore* = ref object of Keystore
    inner*: Keystore          ## the authorization key and everything that is not the identity
    port: ManagerPort
    identity: EncIdentity
    publicKey: string         ## hex, as the manager names the identity
    locked*: bool             ## the last request was refused unsettled: muster's unlock is gone

const LockedRemedy* =
  "identity-locked: unlock muster's room identity in the keys app (signer_manager_module " &
  "request_unlock, apps [muster_module], confirm false), or approve this request there"

proc hexOf(b: openArray[byte]): string =
  result = newStringOfCap(b.len * 2)
  for x in b: result.add toHex(x.int, 2).toLowerAscii()

proc bytesOf(h: string): seq[byte] =
  let s = h.strip()
  if s.len mod 2 != 0: raise newException(KeystoreError, "platform identity: odd hex")
  for i in countup(0, s.len - 1, 2):
    result.add byte(parseHexInt(s[i .. i + 1]))

proc newPlatformIdentityKeystore*(inner: Keystore, port: ManagerPort, publicKeyHex: string): PlatformIdentityKeystore =
  ## `publicKeyHex` is the identity key the manager gave muster (request_identity's publicKey).
  let pk = bytesOf(publicKeyHex)
  if pk.len != EdPubBytes: raise newException(KeystoreError, "platform identity: a public key is 32 bytes")
  var ed: Ed25519Pub
  for i in 0 ..< EdPubBytes: ed[i] = pk[i]
  PlatformIdentityKeystore(inner: inner, port: port, identity: identityOfEd(ed),
                           publicKey: publicKeyHex.strip().toLowerAscii())

proc call(p: PlatformIdentityKeystore, meth: string, args: JsonNode): JsonNode =
  let r = p.port(meth, args)
  if r == nil: raise newException(KeystoreError, "platform identity: signer_manager_module did not answer " & meth)
  r

proc ask(p: PlatformIdentityKeystore, purpose: string, legs: seq[JsonNode]): seq[string] =
  ## One identity request through the manager, collected only if it settled as it arrived.
  let intent = %*{"identity": p.publicKey, "purpose": purpose, "legs": legs}
  let r = p.call("request_approval", %*[$intent])
  if not r{"ok"}.getBool(false):
    raise newException(KeystoreError, "platform identity: " & r{"error"}.getStr("refused"))
  let (handle, receipt) = (r{"handle"}.getStr(), r{"receipt"}.getStr())
  if r{"state"}.getStr() != "settled":
    discard p.port("cancel_approval", %*[handle, receipt])
    p.locked = true
    raise newException(KeystoreError, LockedRemedy)
  p.locked = false
  let f = p.call("fetch_result", %*[handle, receipt])
  discard p.port("ack_result", %*[handle, receipt])
  if not f{"ok"}.getBool(false) or f{"signed"}.kind != JArray or f{"signed"}.len != legs.len:
    raise newException(KeystoreError, "platform identity: no result for " & purpose)
  for x in f{"signed"}: result.add x.getStr()

# ── asking the person, through the keys app ─────────────────────────────────────
# Getting the key and opening it again for muster are the manager's access requests, which the
# person decides in the keys app (keystore.accounts.open {handle}). Muster holds the receipt,
# reads where the request stands, and collects the result once; it never waits on the person.

type PlatformAsk* = object
  kind*: string               ## "identity" (a key of muster's own) or "unlock" (open it for muster)
  handle*, receipt*: string

proc unlockForMuster*(): JsonNode = %*{"apps": ["muster_module"], "confirm": false}
  ## Routine records signed without a prompt, for muster alone (rule 5 of the wallet/signer spec).

proc asked(port: ManagerPort, kind, meth: string, params: JsonNode): PlatformAsk =
  let r = port(meth, %*[$params])
  if r == nil: raise newException(KeystoreError, "platform identity: signer_manager_module did not answer " & meth)
  if not r{"ok"}.getBool(false):
    raise newException(KeystoreError, "platform identity: " & r{"error"}.getStr("refused"))
  PlatformAsk(kind: kind, handle: r{"handle"}.getStr(), receipt: r{"receipt"}.getStr())

proc askIdentity*(port: ManagerPort, context: string): PlatformAsk =
  ## An identity key of muster's own, derived for muster_module/<context> and unlocked for muster.
  var params = %*{"purpose": "room-identity", "context": context,
                  "reason": "Muster signs your room messages with it and opens what rooms seal to you"}
  params["unlock"] = unlockForMuster()
  asked(port, "identity", "request_identity", params)

proc askUnlock*(port: ManagerPort, account: string): PlatformAsk =
  ## The identity key muster already has, opened for muster again once its unlock ran out.
  var params = %*{"account": account,
                  "reason": "Muster signs your room messages with it and opens what rooms seal to you"}
  for k, v in unlockForMuster(): params[k] = v
  asked(port, "unlock", "request_unlock", params)

proc pollAsk*(port: ManagerPort, a: PlatformAsk): JsonNode =
  ## Where an ask stands: {state: "waiting", step} while the person has not decided,
  ## {state: "done", result} once (the result is collected and acknowledged), or
  ## {state: "ended", reason} when it settled with nothing to collect (rejected, cancelled,
  ## expired_no_ack) or the manager no longer knows it.
  let st = port("approval_status", %*[a.handle, a.receipt])
  if st == nil: return %*{"state": "waiting", "step": "unknown"}
  if not st{"ok"}.getBool(false): return %*{"state": "ended", "reason": "unknown-request"}
  let step = st{"state"}.getStr()
  if step != "settled": return %*{"state": "waiting", "step": step}
  let f = port("fetch_result", %*[a.handle, a.receipt])
  if f == nil or not f{"ok"}.getBool(false) or f{"result"}.isNil or f{"result"}.kind == JNull:
    return %*{"state": "ended", "reason": st{"reason"}.getStr("settled")}
  discard port("ack_result", %*[a.handle, a.receipt])
  %*{"state": "done", "result": f{"result"}}

method edSignRecord*(p: PlatformIdentityKeystore, hi: HashInput): Ed25519Sig =
  let got = p.ask("sign a muster record (" & hi.domain & ")",
                  @[%*{"kind": "record", "record": hexOf(encodeHashInput(hi))}])
  let b = bytesOf(got[0])
  if b.len != EdSigBytes: raise newException(KeystoreError, "platform identity: a signature is 64 bytes")
  for i in 0 ..< EdSigBytes: result[i] = b[i]
  # The manager has checked it; checking again costs nothing and keeps the seam honest.
  if not edVerify(p.identity.ed, digest(hi), result):
    raise newException(KeystoreError, "platform identity: the signature does not verify")

method edSign*(p: PlatformIdentityKeystore, msg: openArray[byte]): Ed25519Sig =
  raise newException(KeystoreError,
    "platform identity signs records only: this signature is over raw bytes (a local identity signs it)")

method edSignWith*(p: PlatformIdentityKeystore, r: KeyRef, msg: openArray[byte]): Ed25519Sig =
  p.edSign(msg)

method encIdentity*(p: PlatformIdentityKeystore): EncIdentity = p.identity

method sealOpen*(p: PlatformIdentityKeystore, sealed: seq[byte]): seq[byte] =
  bytesOf(p.ask("open a sealed room message", @[%*{"kind": "open", "sealed": hexOf(sealed)}])[0])

method foundingKey*(p: PlatformIdentityKeystore, room: string): array[32, byte] =
  let b = bytesOf(p.ask("re-open a room this member founded",
                        @[%*{"kind": "secret", "record": hexOf(encodeHashInput(foundingRecord(room)))}])[0])
  if b.len != 32: raise newException(KeystoreError, "platform identity: a secret is 32 bytes")
  for i in 0 ..< 32: result[i] = b[i]

method bindingFor*(p: PlatformIdentityKeystore, ctx: LinkContext): LinkStatement =
  ## The authorization key vouches for the platform identity, as F-14 binds the two.
  let inner = p.inner
  issueBinding((proc(h: array[32, byte]): Signature65 = inner.sign(h)), p.identity, ctx)

# ── everything else is the wrapped keystore's ──────────────────────────────────

method address*(p: PlatformIdentityKeystore): Address = p.inner.address()
method sign*(p: PlatformIdentityKeystore, msgHash: array[32, byte]): Signature65 = p.inner.sign(msgHash)
method keyRefs*(p: PlatformIdentityKeystore): seq[KeyRef] = p.inner.keyRefs()
method signWith*(p: PlatformIdentityKeystore, r: KeyRef, msgHash: array[32, byte]): Signature65 =
  p.inner.signWith(r, msgHash)
method btcPubKey*(p: PlatformIdentityKeystore): seq[byte] = p.inner.btcPubKey()
method signEcdsaDer*(p: PlatformIdentityKeystore, msgHash: array[32, byte]): seq[byte] = p.inner.signEcdsaDer(msgHash)
method signSchnorr*(p: PlatformIdentityKeystore, msg: array[32, byte]): seq[byte] = p.inner.signSchnorr(msg)
method lezMemberKey*(p: PlatformIdentityKeystore, label: string): seq[byte] = p.inner.lezMemberKey(label)
method lezMemberSign*(p: PlatformIdentityKeystore, label: string, msgHash: array[32, byte]): seq[byte] =
  p.inner.lezMemberSign(label, msgHash)
method frostHostPubkey*(p: PlatformIdentityKeystore, label: string): seq[byte] = p.inner.frostHostPubkey(label)
method frostHostSign*(p: PlatformIdentityKeystore, label: string, digest: array[32, byte]): seq[byte] =
  p.inner.frostHostSign(label, digest)
method frostHostAttest*(p: PlatformIdentityKeystore, label: string, digest: array[32, byte]): seq[byte] =
  p.inner.frostHostAttest(label, digest)
method frostDkgStep1*(p: PlatformIdentityKeystore, label: string, params: SessionParams): seq[byte] =
  p.inner.frostDkgStep1(label, params)
method frostDkgStep2*(p: PlatformIdentityKeystore, label: string, params: SessionParams, cmsg1: seq[byte]): seq[byte] =
  p.inner.frostDkgStep2(label, params, cmsg1)
method frostDkgFinalize*(p: PlatformIdentityKeystore, label: string, params: SessionParams,
                         cmsg2: seq[byte]): tuple[output: DkgOutput, recoveryData: seq[byte]] =
  p.inner.frostDkgFinalize(label, params, cmsg2)
method frostNonceCommit*(p: PlatformIdentityKeystore, label, session: string, recoveryData: seq[byte],
                         msgs: seq[seq[byte]]): seq[seq[byte]] =
  p.inner.frostNonceCommit(label, session, recoveryData, msgs)
method frostPartialSign*(p: PlatformIdentityKeystore, label, session: string, recoveryData: seq[byte], ids: seq[int],
                         pubnonces: seq[seq[seq[byte]]], msgs: seq[seq[byte]]): seq[seq[byte]] =
  p.inner.frostPartialSign(label, session, recoveryData, ids, pubnonces, msgs)
