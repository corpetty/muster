## A hand-built fold fixture as the live path would leave it (exo-af5, exo-ea8).
##
## Under a driver only the room binds (threshold, FROST, invoke, charter, split), an
## approval counts only with an attestation over P, and P's context is the one a proposer
## of the intent signed. A fixture that hands the fold bare `propose` + `sig` events used
## to fold as if every signature were attested; `withAttestations` adds what the live path
## publishes beside them — the proposer's claim, its context, and each signer's
## attestation over the P the fold re-derives — so a fixture states the same thing it
## always meant to: these members approved, in this room.
##
## Events built here are not author-signed (a fold over a plain seq never checks that);
## through a session, the live path signs them.

import std/strutils
import ../../src/log/log
import ../../src/crypto/curve25519
import ../../src/drivers/driver
import ../../src/intents/signing_payload
import ../../src/coordination/intent_events
import ../../src/coordination/attest

const FixtureRoom* = "/muster/1/fixture/proto"
const FixtureExpiry* = 4_000_000_000'u64

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

type SecpSigner* = tuple[address: string, sign: proc(digest: array[32, byte]): string]
  ## a secp contributor named by its 0x address; `sign` returns the 65-byte signature hex

proc withAttestations*(events: seq[Event], driverFor: DriverFor, intentId: string,
                       signers: openArray[EncKeys] = [], secp: openArray[SecpSigner] = [],
                       proposer = "", account = FixtureRoom, expiry = FixtureExpiry): seq[Event] =
  ## `events` plus, for `intentId`: a proposer claim and its context (unless a proposer's
  ## context is there already), and for every contribution by one of `signers` (named
  ## "ed:<key>" or "frost:<key>") or `secp` (named by address) an attestation over P,
  ## parented on that contribution. `proposer` defaults to the first signer.
  result = events
  var prop = proposer
  if prop.len == 0 and signers.len > 0: prop = "0x" & hexOf(signers[0].identity().toBytes())
  if prop.len == 0 and secp.len > 0: prop = secp[0].address
  if prop.len > 0 and intentContext(result, intentId).isPlaceholder:
    result.add proposerEvent(intentId, prop)
    let drv = driverFor(intentPolicyOf(result, intentId))
    result.add contextEvent(intentId, SigningContext(environment: drv.environment(), account: account,
                                                     slot: intentId, expiry: expiry), author = prop)
  let p = attestationPayload(result, driverFor, intentId)
  if p.len == 0: return
  var added: seq[Event]
  for e in result:
    let k = e.key.split('/')
    if k.len < 5 or k[0] != "intent" or k[1] != intentId or k[2] != "sig": continue
    let who = k[3]
    let round = (try: parseInt(k[4]) except ValueError: 1)
    var sig = ""
    if who.startsWith("ed:") or who.startsWith("frost:"):
      let pk = who[who.find(':') + 1 .. ^1].toLowerAscii()
      for s in signers:
        if hexOf(s.identity().ed) == pk: sig = "0x" & hexOf(edSign(s, p))
    else:
      for s in secp:
        if s.address.toLowerAscii() == who.toLowerAscii(): sig = s.sign(attestationDigest(p))
    if sig.len > 0:
      added.add attestEvent(intentId, who, round, sig, parents = @[eventId(e)])
  result.add added
