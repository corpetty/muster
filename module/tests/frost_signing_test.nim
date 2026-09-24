## FROST signing (exo-d7e, Phase D2): a port of the BIP-445 draft's reference
## (bip-0445/python/frost_ref/signing.py, siv2r/bips @ 8e25d57, bitcoin/bips#2070), held to
## EVERY vector the draft ships (tests/vectors/bip-0445/, vendored verbatim):
##   1. nonce_gen: the deterministic core of nonce generation, every optional input;
##   2. nonce_agg: aggregation, including an aggregate at infinity, and the signer an
##      invalid public nonce is blamed on;
##   3. sign / verify: partial signatures for every signer set, sessions with and without
##      the public shares; every sign error by its exact message; verification failures;
##      verification errors (a blamed pubnonce);
##   4. tweaks: plain and x-only tweaks, chained; every tweak error;
##   5. deterministic signing: pubnonce + partial signature, with and without aux
##      randomness and the other signers' aggregate nonce;
##   6. aggregation: the partial signatures sum to one BIP-340 signature that verifies
##      under the (tweaked) threshold key; a bad psig is blamed on its signer;
##   7. a secnonce is spent by signing: signing twice with it is refused.
## Needs the secp closure + stint — see tests/README.md.

import std/[json, os, options, strutils, sequtils]
import ../src/frost/secp
import ../src/frost/signing
import ../src/bitcoin/[tx, keys]

let dir = currentSourcePath().parentDir() / "vectors" / "bip-0445"
proc load(name: string): JsonNode = parseJson(readFile(dir / (name & "_vectors.json")))
proc hb(n: JsonNode): seq[byte] = hexToBytes(n.getStr())
proc hbs(n: JsonNode): seq[seq[byte]] = n.getElems().mapIt(hexToBytes(it.getStr()))
proc ints(n: JsonNode): seq[int] = n.getElems().mapIt(it.getInt())
proc maybe(n: JsonNode): Option[seq[byte]] = (if n.kind == JNull: none(seq[byte]) else: some(hexToBytes(n.getStr())))
proc pick(all: seq[seq[byte]], idx: JsonNode): seq[seq[byte]] = idx.getElems().mapIt(all[it.getInt()])

proc expectError(tc: JsonNode, body: proc()) =
  ## The vector's error, exactly: a ValueError by message, an InvalidContributionError by
  ## the blamed signer (null = the coordinator) and, when given, the contribution kind.
  let err = tc["error"]
  var raised = false
  try: body()
  except InvalidContributionError as e:
    raised = true
    doAssert err["type"].getStr() == "InvalidContributionError", "got InvalidContributionError, want " & $err
    let want = (if err["signer_index"].kind == JNull: -1 else: err["signer_index"].getInt())
    doAssert e.signerIndex == want, "blamed " & $e.signerIndex & ", want " & $want
    if err.hasKey("contrib"): doAssert e.contrib == err["contrib"].getStr(), e.contrib & " vs " & $err["contrib"]
  except ValueError as e:
    raised = true
    doAssert err["type"].getStr() == "ValueError" and e.msg == err["message"].getStr(),
      "got ValueError(" & e.msg & "), want " & $err
  doAssert raised, "no error raised; want " & $err

# ── 1. nonce_gen ───────────────────────────────────────────────────────────────
block:
  let v = load("nonce_gen")
  var n = 0
  for tc in v["valid_tests"]:
    let (sec, pub) = nonceGenInternal(hb(tc["rand"]), maybe(tc["secshare"]), maybe(tc["pubshare"]),
                                      maybe(tc["thresh_pk_xonly"]), maybe(tc["msg"]), maybe(tc["extra_in"]))
    doAssert hexOf(sec) == tc["expected"][0].getStr().toLowerAscii() and
             hexOf(pub) == tc["expected"][1].getStr().toLowerAscii(), "nonce_gen " & $n
    inc n
  echo "1. nonce_gen: ", n, " vectors OK"

# ── 2. nonce_agg ───────────────────────────────────────────────────────────────
block:
  let v = load("nonce_agg")
  let all = hbs(v["pubnonces"])
  var n = 0
  for tc in v["valid_tests"]:
    doAssert hexOf(nonceAgg(pick(all, tc["pubnonce_indices"]))) == tc["expected"].getStr().toLowerAscii()
    inc n
  for tc in v["error_tests"]:
    expectError(tc, proc() = discard nonceAgg(pick(all, tc["pubnonce_indices"])))
    inc n
  echo "2. nonce_agg: ", n, " vectors (valid + blamed) OK"

# ── 3. sign / verify ───────────────────────────────────────────────────────────
block:
  let v = load("sign_verify")
  var n = 0
  for g in v["test_groups"]:
    let (nn, t) = (g["n"].getInt(), g["t"].getInt())
    let threshPk = hb(g["thresh_pk"])
    let pubshares = hbs(g["pubshares"])
    let pubnonces = hbs(g["pubnonces"])
    let secshares = hbs(g["secshares"])
    let secnonces = hbs(g["secnonces"])
    for i in 0 ..< nn: doAssert pubshares[i] == compressedPubKey(secshares[i])
    for tc in g["valid_tests"]:
      let ids = ints(tc["ids"])
      let ps = (if tc["pubshare_indices"].kind == JNull: none(seq[seq[byte]])
                else: some(pick(pubshares, tc["pubshare_indices"])))
      let pn = pick(pubnonces, tc["pubnonce_indices"])
      let agg = hb(tc["aggnonce"])
      doAssert nonceAgg(pn) == agg
      let msg = hb(tc["msg"])
      let myId = tc["my_id"].getInt()
      let ctx = SessionContext(n: nn, t: t, ids: ids, pubshares: ps, threshPk: threshPk, aggnonce: agg, msg: msg)
      var sn = secnonces[tc["secnonce_index"].getInt()]
      let psig = sign(sn, secshares[tc["secshare_index"].getInt()], myId, ctx)
      doAssert hexOf(psig) == tc["expected"].getStr().toLowerAscii(), "sign " & $n
      if ps.isSome:
        doAssert partialSigVerify(psig, pn, nn, t, ids, ps.get, threshPk, @[], @[], msg, ids.find(myId))
      inc n
    for tc in g["sign_error_tests"]:
      let ctx = SessionContext(n: nn, t: t, ids: ints(tc["ids"]), pubshares: some(pick(pubshares, tc["pubshare_indices"])),
                               threshPk: threshPk, aggnonce: hb(tc["aggnonce"]), msg: hb(tc["msg"]))
      var sn = secnonces[tc["secnonce_index"].getInt()]
      let ss = secshares[tc["secshare_index"].getInt()]
      let myId = tc["my_id"].getInt()
      expectError(tc, proc() = discard sign(sn, ss, myId, ctx))
      inc n
    for tc in g["verify_fail_tests"]:
      doAssert not partialSigVerify(hb(tc["psig"]), pick(pubnonces, tc["pubnonce_indices"]), nn, t, ints(tc["ids"]),
                                    pick(pubshares, tc["pubshare_indices"]), threshPk, @[], @[], hb(tc["msg"]),
                                    tc["signer_index"].getInt()), "verify_fail " & $n
      inc n
    for tc in g["verify_error_tests"]:
      expectError(tc, proc() = discard partialSigVerify(hb(tc["psig"]), pick(pubnonces, tc["pubnonce_indices"]), nn, t,
        ints(tc["ids"]), pick(pubshares, tc["pubshare_indices"]), threshPk, @[], @[], hb(tc["msg"]), tc["signer_index"].getInt()))
      inc n
  echo "3. sign / verify: ", n, " vectors (partial sigs, sign errors, verify fails, verify errors) OK"

# ── 4. tweaks ──────────────────────────────────────────────────────────────────
block:
  let v = load("tweak")
  var n = 0
  for g in v["test_groups"]:
    let (nn, t) = (g["n"].getInt(), g["t"].getInt())
    let threshPk = hb(g["thresh_pk"])
    let pubshares = hbs(g["pubshares"])
    let pubnonces = hbs(g["pubnonces"])
    let secshares = hbs(g["secshares"])
    let secnonces = hbs(g["secnonces"])
    let tweaks = hbs(g["tweaks"])
    for tc in g["valid_tests"]:
      let ids = ints(tc["ids"])
      let ps = pick(pubshares, tc["pubshare_indices"])
      let pn = pick(pubnonces, tc["pubnonce_indices"])
      let agg = hb(tc["aggnonce"])
      doAssert nonceAgg(pn) == agg
      let tw = pick(tweaks, tc["tweak_indices"])
      let modes = tc["is_xonly"].getElems().mapIt(it.getBool())
      let myId = tc["my_id"].getInt()
      let ctx = SessionContext(n: nn, t: t, ids: ids, pubshares: some(ps), threshPk: threshPk, aggnonce: agg,
                               tweaks: tw, isXonly: modes, msg: hb(tc["msg"]))
      var sn = secnonces[tc["secnonce_index"].getInt()]
      let psig = sign(sn, secshares[tc["secshare_index"].getInt()], myId, ctx)
      doAssert hexOf(psig) == tc["expected"].getStr().toLowerAscii(), "tweak " & $n
      doAssert partialSigVerify(psig, pn, nn, t, ids, ps, threshPk, tw, modes, hb(tc["msg"]), ids.find(myId))
      inc n
    for tc in g["error_tests"]:
      let ctx = SessionContext(n: nn, t: t, ids: ints(tc["ids"]), pubshares: some(pick(pubshares, tc["pubshare_indices"])),
                               threshPk: threshPk, aggnonce: hb(tc["aggnonce"]), tweaks: pick(tweaks, tc["tweak_indices"]),
                               isXonly: tc["is_xonly"].getElems().mapIt(it.getBool()), msg: hb(tc["msg"]))
      var sn = secnonces[tc["secnonce_index"].getInt()]
      let ss = secshares[tc["secshare_index"].getInt()]
      let myId = tc["my_id"].getInt()
      expectError(tc, proc() = discard sign(sn, ss, myId, ctx))
      inc n
  echo "4. tweaks: ", n, " vectors (plain / x-only, chained, errors) OK"

# ── 5. deterministic signing ───────────────────────────────────────────────────
block:
  let v = load("det_sign")
  var n = 0
  for g in v["test_groups"]:
    let (nn, t) = (g["n"].getInt(), g["t"].getInt())
    let threshPk = hb(g["thresh_pk"])
    let pubshares = hbs(g["pubshares"])
    let secshares = hbs(g["secshares"])
    for tc in g["valid_tests"]:
      let ids = ints(tc["ids"])
      let ps = (if tc["pubshare_indices"].kind == JNull: none(seq[seq[byte]])
                else: some(pick(pubshares, tc["pubshare_indices"])))
      let myId = tc["my_id"].getInt()
      let (pubnonce, psig) = deterministicSign(secshares[tc["secshare_index"].getInt()], myId, maybe(tc["aggothernonce"]),
        nn, t, ids, ps, threshPk, hbs(tc["tweaks"]), tc["is_xonly"].getElems().mapIt(it.getBool()), hb(tc["msg"]),
        maybe(tc["aux_rand"]))
      doAssert hexOf(pubnonce) == tc["expected"][0].getStr().toLowerAscii() and
               hexOf(psig) == tc["expected"][1].getStr().toLowerAscii(), "det_sign " & $n
      inc n
    for tc in g["error_tests"]:
      let ids = ints(tc["ids"])
      let ps = pick(pubshares, tc["pubshare_indices"])
      let ss = secshares[tc["secshare_index"].getInt()]
      let myId = tc["my_id"].getInt()
      expectError(tc, proc() = discard deterministicSign(ss, myId, maybe(tc["aggothernonce"]), nn, t, ids, some(ps),
        threshPk, hbs(tc["tweaks"]), tc["is_xonly"].getElems().mapIt(it.getBool()), hb(tc["msg"]), maybe(tc["aux_rand"])))
      inc n
  echo "5. deterministic signing: ", n, " vectors OK"

# ── 6. aggregation ─────────────────────────────────────────────────────────────
block:
  let v = load("sig_agg")
  var n = 0
  for g in v["test_groups"]:
    let (nn, t) = (g["n"].getInt(), g["t"].getInt())
    let threshPk = hb(g["thresh_pk"])
    let pubshares = hbs(g["pubshares"])
    let tweaks = hbs(g["tweaks"])
    for tc in g["valid_tests"]:
      let ps = (if tc["pubshare_indices"].kind == JNull: none(seq[seq[byte]])
                else: some(pick(pubshares, tc["pubshare_indices"])))
      let tw = pick(tweaks, tc["tweak_indices"])
      let modes = tc["is_xonly"].getElems().mapIt(it.getBool())
      let msg = hb(tc["msg"])
      let ctx = SessionContext(n: nn, t: t, ids: ints(tc["ids"]), pubshares: ps, threshPk: threshPk,
                               aggnonce: hb(tc["aggnonce"]), tweaks: tw, isXonly: modes, msg: msg)
      let sig = partialSigAgg(hbs(tc["psigs"]), ctx)
      doAssert hexOf(sig) == tc["expected"].getStr().toLowerAscii(), "sig_agg " & $n
      doAssert schnorrVerify(sig, msg, getXonlyPk(threshPubkeyAndTweak(threshPk, tw, modes))),
        "the aggregate is a plain BIP-340 signature under the (tweaked) threshold key"
      inc n
    for tc in g["error_tests"]:
      let ctx = SessionContext(n: nn, t: t, ids: ints(tc["ids"]), pubshares: some(pick(pubshares, tc["pubshare_indices"])),
                               threshPk: threshPk, aggnonce: hb(tc["aggnonce"]), tweaks: pick(tweaks, tc["tweak_indices"]),
                               isXonly: tc["is_xonly"].getElems().mapIt(it.getBool()), msg: hb(tc["msg"]))
      let psigs = hbs(tc["psigs"])
      expectError(tc, proc() = discard partialSigAgg(psigs, ctx))
      inc n
  echo "6. aggregation: ", n, " vectors — one BIP-340 signature under the threshold key OK"

# ── 7. a secnonce is spent ─────────────────────────────────────────────────────
block:
  let g = load("sign_verify")["test_groups"][0]
  let tc = g["valid_tests"][0]
  let ctx = SessionContext(n: g["n"].getInt(), t: g["t"].getInt(), ids: ints(tc["ids"]),
                           pubshares: none(seq[seq[byte]]), threshPk: hb(g["thresh_pk"]),
                           aggnonce: hb(tc["aggnonce"]), msg: hb(tc["msg"]))
  var sn = hbs(g["secnonces"])[tc["secnonce_index"].getInt()]
  let ss = hbs(g["secshares"])[tc["secshare_index"].getInt()]
  discard sign(sn, ss, tc["my_id"].getInt(), ctx)
  doAssert sn == newSeq[byte](64), "signing zeroes the secnonce"
  var raised = false
  try: discard sign(sn, ss, tc["my_id"].getInt(), ctx)
  except ValueError: raised = true
  doAssert raised, "a spent secnonce cannot sign again"
  echo "7. signing spends the secnonce; a second use is refused OK"

echo "frost_signing_test: BIP-445 FROST signing, held to every draft vector — all OK"
