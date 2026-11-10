## The quest record program as muster reads and writes it (exo-267.7;
## docs/design/lez-quest-program.md): the record's address, a record in every status, and
## every instruction, held byte for byte to vectors from the program's own crate
## (tests/vectors/lez-quest-v010, programs/lez-quest). A truncated or padded record is
## refused, never guessed.

import std/[json, os, strutils]
import stint
import ../src/lez/multisig
import ../src/lez/quest

let v = parseJson(readFile(currentSourcePath().parentDir() / "vectors" / "lez-quest-v010" / "vectors.json"))
proc unhex(s: string): seq[byte] =
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))
proc hx(b: seq[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))
let program = unhex(v["program"].getStr())
let issuer = unhex(v["issuer"].getStr())
let taker = unhex(v["taker"].getStr())
let confirmer = unhex(v["confirmer"].getStr())
let qid = unhex(v["quest_id"].getStr())
let terms = unhex(v["terms_hash"].getStr())
let bounty = parse(v["bounty"].getStr(), UInt128)

# ── 1. where a record lives ───────────────────────────────────────────────────
block:
  doAssert hx(questRecordSeed(issuer, qid)) == v["record_seed"].getStr()
  doAssert hx(questRecordPda(psLee02, program, issuer, qid)) == v["record_pda"].getStr()
  echo "1. the record seed and PDA match the program's own crate OK"

# ── 2. a record in every status ───────────────────────────────────────────────
block:
  let want = [("open", qsOpen, false), ("open_named", qsOpen, false), ("accepted", qsAccepted, true),
              ("confirmed", qsConfirmed, true), ("closed", qsClosed, true), ("cancelled", qsCancelled, false)]
  for (name, status, hasTaker) in want:
    let bytes = unhex(v["records"][name].getStr())
    let r = decodeQuestRecord(bytes)
    doAssert r.issuer == issuer and r.questId == qid and r.termsHash == terms and r.bounty == bounty
    doAssert r.confirmer == confirmer and r.status == status, name
    doAssert (r.statusTaker == taker) == hasTaker, name
    doAssert (r.namedTaker == taker) == (name == "open_named"), name
    doAssert encodeQuestRecord(r) == bytes, name & " re-encodes byte for byte"
    var raised = 0
    for bad in [bytes[0 ..< ^1], bytes & @[0'u8]]:
      try: discard decodeQuestRecord(bad)
      except LezDecodeError: inc raised
    doAssert raised == 2, name & ": a truncated or padded record is refused"
  echo "2. a record in each of six states decodes and re-encodes byte for byte; truncated or padded refused OK"

# ── 3. every instruction ──────────────────────────────────────────────────────
block:
  let ins = v["instructions"]
  doAssert hx(questOpen(qid, terms, bounty, confirmer)) == ins["open"].getStr()
  doAssert hx(questOpen(qid, terms, bounty, confirmer, taker)) == ins["open_named"].getStr()
  doAssert hx(questAccept(issuer, qid)) == ins["accept"].getStr()
  doAssert hx(questConfirm(issuer, qid)) == ins["confirm"].getStr()
  doAssert hx(questClose(qid, taker, bounty)) == ins["close"].getStr()
  doAssert hx(questCancel(qid, bounty)) == ins["cancel"].getStr()
  echo "3. Open (open and named), Accept, Confirm, Close, Cancel encode as the program reads them OK"

echo "lez_quest_test: all OK"
