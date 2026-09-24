## ChillDKG (exo-fae, Phase D3): a port of the draft's reference
## (bip-chilldkg/python/chilldkg_ref, mllwchrry/bips @ 2b9b0b1, bitcoin/bips#2227) — VSS,
## SimplPedPop, EncPedPop, CertEq — held to EVERY vector the draft ships
## (tests/vectors/chilldkg/, vendored), each file's test count checked, each error by its
## exact type, message and blamed participant(s), as the reference's own tests.py does:
##   1. hostpubkey_gen and params_hash (incl. invalid / duplicate host keys, t out of range);
##   2. participant step 1 (the encrypted shares + VSS commitment + proof of possession);
##   3. participant step 2 (the certifying signature) and its faults — a coordinator that
##      lies, a participant's bad commitment / proof / nonce, an invalid share (which calls
##      for investigation);
##   4. participant finalize (the certificate checked, the DKG output, the recovery data);
##   5. participant investigate (who sent the bad share, or that the coordinator lied);
##   6. coordinator step 1, finalize (blaming a bad certifying signature) and investigate;
##   7. recovery from the recovery data alone (with and without the host secret key).
## Needs the secp closure + stint — see tests/README.md.

import std/[json, os, options, strutils, sequtils]
import ../src/frost/chilldkg
import ../src/bitcoin/tx       # hexToBytes

let dir = currentSourcePath().parentDir() / "vectors" / "chilldkg"
proc load(name: string): JsonNode = parseJson(readFile(dir / (name & "_vectors.json")))
proc hb(n: JsonNode): seq[byte] = hexToBytes(n.getStr())
proc hx(b: seq[byte]): string = (for x in b: result.add toUpperAscii(toHex(x, 2)))
proc paramsOf(j: JsonNode): SessionParams =
  SessionParams(hostpubkeys: j["hostpubkeys"].getElems().mapIt(hexToBytes(it.getStr())), t: j["t"].getInt())
proc outputJson(o: DkgOutput): JsonNode =
  %*{"secshare": (if o.secshare.isSome: %hx(o.secshare.get) else: newJNull()),
     "threshPk": hx(o.threshPk), "pubshares": o.pubshares.mapIt(hx(it))}
proc paramsJson(p: SessionParams): JsonNode = %*{"hostpubkeys": p.hostpubkeys.mapIt(hx(it)), "t": p.t}

proc errorJson(e: ref DkgError): JsonNode =
  ## the reference's exception_asdict: the class, the ids it carries, and its message if any
  result = %*{"type": e.kind}
  if e.participantId >= 0: result["participantId"] = %e.participantId
  if e.participantId1 >= 0: result["participantId1"] = %e.participantId1
  if e.participantId2 >= 0: result["participantId2"] = %e.participantId2
  if e.message.len > 0: result["message"] = %e.message

proc sameJson(a, b: JsonNode): bool =
  ## key order never matters; values must match exactly
  if a.kind == JObject and b.kind == JObject:
    if a.len != b.len: return false
    for k, v in a:
      if not b.hasKey(k) or not sameJson(v, b[k]): return false
    return true
  if a.kind == JArray and b.kind == JArray:
    if a.len != b.len: return false
    for i in 0 ..< a.len:
      if not sameJson(a[i], b[i]): return false
    return true
  a == b

proc raisesAs(want: JsonNode, body: proc()) =
  var got: JsonNode = nil
  try: body()
  except DkgError as e: got = errorJson(e)
  doAssert got != nil, "no error raised; want " & $want
  doAssert sameJson(got, want), "got " & $got & ", want " & $want

var total = 0

# ── 1. host keys and params ────────────────────────────────────────────────────
block:
  let v = load("hostpubkey_gen")
  for tc in v["validTestCases"]: doAssert hostpubkeyGen(hb(tc["hostseckey"])) == hb(tc["expectedHostpubkey"])
  for tc in v["errorTestCases"]: raisesAs(tc["expectedError"], proc() = discard hostpubkeyGen(hb(tc["hostseckey"])))
  doAssert v["totalTests"].getInt() == v["validTestCases"].len + v["errorTestCases"].len
  let p = load("params_hash")
  for tc in p["validTestCases"]: doAssert paramsHash(paramsOf(tc["params"])) == hb(tc["expectedParamsHash"])
  for tc in p["errorTestCases"]: raisesAs(tc["expectedError"], proc() = discard paramsHash(paramsOf(tc["params"])))
  total += v["totalTests"].getInt() + p["totalTests"].getInt()
  echo "1. hostpubkey_gen + params_hash: ", v["totalTests"].getInt() + p["totalTests"].getInt(), " vectors OK"

# ── 2. participant step 1 ──────────────────────────────────────────────────────
block:
  let v = load("participant_step1")
  var n = 0
  for g in v["testGroups"]:
    for tc in g["validTestCases"]:
      let (_, pmsg1) = participantStep1(hb(tc["hostseckey"]), paramsOf(tc["params"]), hb(tc["random"]))
      doAssert pmsg1 == hb(tc["expectedPmsg1"]), "step1 tc " & $tc["tcId"]
      inc n
    for tc in g["errorTestCases"]:
      raisesAs(tc["expectedError"], proc() =
        discard participantStep1(hb(tc["hostseckey"]), paramsOf(tc["params"]), hb(tc["random"])))
      inc n
  doAssert n == v["totalTests"].getInt()
  total += n
  echo "2. participant step 1: ", n, " vectors OK"

# ── 3. participant step 2 ──────────────────────────────────────────────────────
block:
  let v = load("participant_step2")
  var n = 0
  for g in v["testGroups"]:
    let params = paramsOf(g["params"])
    let hsk = hb(g["hostseckey"])
    let (st1, pmsg1) = participantStep1(hsk, params, hb(g["random"]))
    doAssert pmsg1 == hb(g["pmsg1"])
    for tc in g["validTestCases"]:
      let (_, pmsg2) = participantStep2(hsk, st1, hb(tc["cmsg1"]), hb(g["auxRand"]))
      doAssert pmsg2 == hb(tc["expectedPmsg2"]), "step2 tc " & $tc["tcId"]
      inc n
    for tc in g["errorTestCases"]:
      let caseHsk = (if tc.hasKey("hostseckey"): hb(tc["hostseckey"]) else: hsk)
      let caseAux = (if tc.hasKey("auxRand"): hb(tc["auxRand"]) else: hb(g["auxRand"]))
      raisesAs(tc["expectedError"], proc() = discard participantStep2(caseHsk, st1, hb(tc["cmsg1"]), caseAux))
      inc n
  doAssert n == v["totalTests"].getInt()
  total += n
  echo "3. participant step 2: ", n, " vectors (the certifying signature and every fault) OK"

# ── 4. participant finalize ────────────────────────────────────────────────────
block:
  let v = load("participant_finalize")
  var n = 0
  for g in v["testGroups"]:
    let params = paramsOf(g["params"])
    let hsk = hb(g["hostseckey"])
    let (st1, pmsg1) = participantStep1(hsk, params, hb(g["random"]))
    doAssert pmsg1 == hb(g["pmsg1"])
    let (st2, pmsg2) = participantStep2(hsk, st1, hb(g["cmsg1"]), hb(g["auxRand"]))
    doAssert pmsg2 == hb(g["pmsg2"])
    for tc in g["validTestCases"]:
      let (outp, rec) = participantFinalize(st2, hb(tc["cmsg2"]))
      doAssert sameJson(outputJson(outp), tc["expectedOutput"]["dkgOutput"]), "finalize tc " & $tc["tcId"]
      doAssert rec == hb(tc["expectedOutput"]["recoveryData"])
      inc n
    for tc in g["errorTestCases"]:
      raisesAs(tc["expectedError"], proc() = discard participantFinalize(st2, hb(tc["cmsg2"])))
      inc n
  doAssert n == v["totalTests"].getInt()
  total += n
  echo "4. participant finalize: ", n, " vectors (certificate checked, DKG output, recovery data) OK"

# ── 5. participant investigate ─────────────────────────────────────────────────
block:
  let v = load("participant_investigate")
  var n = 0
  for g in v["testGroups"]:
    let params = paramsOf(g["params"])
    let hsk = hb(g["hostseckey"])
    let (st1, pmsg1) = participantStep1(hsk, params, hb(g["random"]))
    doAssert pmsg1 == hb(g["pmsg1"])
    for tc in g["errorTestCases"]:
      let cmsg1 = hb(g["cmsg1Pool"][tc["cmsg1Index"].getInt()])
      var inv: ref DkgError = nil
      try: discard participantStep2(hsk, st1, cmsg1, hb(g["auxRand"]))
      except DkgError as e: inv = e
      doAssert inv != nil and inv.kind == "UnknownFaultyParticipantOrCoordinatorError"
      let cinv = hb(tc["cinvMsg"])
      raisesAs(tc["expectedError"], proc() = participantInvestigate(inv, cinv))
      inc n
  doAssert n == v["totalTests"].getInt()
  total += n
  echo "5. participant investigate: ", n, " vectors (the faulty sender found, or the coordinator) OK"

# ── 6. the coordinator ─────────────────────────────────────────────────────────
block:
  let v1 = load("coordinator_step1")
  var n = 0
  for g in v1["testGroups"]:
    let pool = g["pmsg1Pool"]
    for tc in g["validTestCases"]:
      let pm = tc["pmsg1Indices"].getElems().mapIt(hb(pool[it.getInt()]))
      let (_, cmsg1) = coordinatorStep1(pm, paramsOf(tc["params"]))
      doAssert cmsg1 == hb(tc["expectedCmsg1"]), "coord step1 tc " & $tc["tcId"]
      inc n
    for tc in g["errorTestCases"]:
      let pm = tc["pmsg1Indices"].getElems().mapIt(hb(pool[it.getInt()]))
      raisesAs(tc["expectedError"], proc() = discard coordinatorStep1(pm, paramsOf(tc["params"])))
      inc n
  doAssert n == v1["totalTests"].getInt()
  let v2 = load("coordinator_finalize")
  var m = 0
  for g in v2["testGroups"]:
    let params = paramsOf(g["params"])
    let (cst, cmsg1) = coordinatorStep1(g["pmsgs1"].getElems().mapIt(hb(it)), params)
    doAssert cmsg1 == hb(g["cmsg1"])
    let pool = g["pmsg2Pool"]
    for tc in g["validTestCases"]:
      let pm = tc["pmsg2Indices"].getElems().mapIt(hb(pool[it.getInt()]))
      let (cmsg2, cout, crec) = coordinatorFinalize(cst, pm)
      doAssert cmsg2 == hb(tc["expectedOutput"]["cmsg2"])
      doAssert sameJson(outputJson(cout), tc["expectedOutput"]["dkgOutput"])
      doAssert crec == hb(tc["expectedOutput"]["recoveryData"])
      inc m
    for tc in g["errorTestCases"]:
      let pm = tc["pmsg2Indices"].getElems().mapIt(hb(pool[it.getInt()]))
      raisesAs(tc["expectedError"], proc() = discard coordinatorFinalize(cst, pm))
      inc m
  doAssert m == v2["totalTests"].getInt()
  let v3 = load("coordinator_investigate")
  var k = 0
  for g in v3["testGroups"]:
    for tc in g["validTestCases"]:
      let cinvs = coordinatorInvestigate(g["pmsgs1"].getElems().mapIt(hb(it)), paramsOf(g["params"]))
      doAssert cinvs == tc["expectedCinvMsgs"].getElems().mapIt(hb(it))
      inc k
  doAssert k == v3["totalTests"].getInt()
  total += n + m + k
  echo "6. coordinator step 1 / finalize / investigate: ", n + m + k, " vectors OK"

# ── 7. recovery ────────────────────────────────────────────────────────────────
block:
  let v = load("recover")
  for tc in v["validTestCases"]:
    let rd = hb(tc["recoveryData"])
    let (o, p) = (if tc["hostseckey"].kind == JNull: coordinatorRecover(rd)
                  else: participantRecover(hb(tc["hostseckey"]), rd))
    doAssert sameJson(outputJson(o), tc["expectedOutput"]["dkgOutput"]) and sameJson(paramsJson(p), tc["expectedOutput"]["params"])
  for tc in v["errorTestCases"]:
    let rd = hb(tc["recoveryData"])
    if tc["hostseckey"].kind == JNull:
      raisesAs(tc["expectedError"], proc() = discard coordinatorRecover(rd))
    else:
      let hsk = hb(tc["hostseckey"])
      raisesAs(tc["expectedError"], proc() = discard participantRecover(hsk, rd))
  doAssert v["totalTests"].getInt() == v["validTestCases"].len + v["errorTestCases"].len
  total += v["totalTests"].getInt()
  echo "7. recovery: ", v["totalTests"].getInt(), " vectors OK"

echo "frost_chilldkg_test: ChillDKG held to all ", total, " draft vectors — all OK"
