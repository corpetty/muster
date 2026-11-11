## A room's charter as a driver (exo-267.1; docs/design/logos-world-plan.md Phase 1).
##
## A charter is the room's founding entry: its name and purpose, the members it governs,
## role slots the members name, a policy table from action class to driver kind, an
## optional account (a circle's LEZ multisig) and round schedule, and the rule for
## changing all of it. It is a proposal like any other, under the `charter` kind, and
## this driver is what decides it.
##
## The people who decide a charter are named IN ITS EFFECT (the electorate) together
## with how many of them must agree (k), as a split names its parties (describeFor,
## exo-a90.2). A room-roster driver would re-count every past charter against whoever is
## in the room now, so a member joining could unmake the charter in force; naming the
## electorate makes "did this take force" a fact about the proposal alone. Whether the
## electorate and k are the RIGHT ones — the founding members all, or the charter in
## force's own members and amend k — is the fold's to judge (coordination/charter.nim),
## since only the log says which charter is in force. This driver holds the shape:
##   * a founding charter (prev "") is decided by every member its body names, and only
##     by them — anything else is refused at signing and never canonicalizes to bytes an
##     agreement can name;
##   * a contribution is an electorate member's Ed25519 room-key signature over the
##     materialization, dCBOR [domain, schema, prev, [electorate…], k, body];
##   * the body is a closed vocabulary: no org-type field can ride in it (a circle is a
##     charter TEMPLATE, never a type), and every charter has a rule for changing rules.

import std/[json, strutils, sequtils, algorithm]
import ../dcbor/dcbor
import ../crypto/curve25519
import ../intents/materialization
import ./driver
import ./manifest
import ./profile

const
  CharterKind* = "charter"
  CharterSchema* = "muster.effect.charter.v1"
  CharterDomain = "muster.charter.v1"
  AmendRule* = "amend-charter"      ## the action class every charter must govern
  BodyKeys = ["name", "purpose", "members", "amend", "roles", "rules", "account", "schedule"]

type
  CharterRole* = object
    slot*: string                   ## the core's handle; never read for meaning
    name*: string                   ## what the members call it
    holders*: seq[string]           ## members holding it (room identity hex)

  CharterSchedule* = object
    cadenceSec*: int64              ## how often a round falls due
    share*: string                  ## each member's share per round, decimal in the asset's base unit
    asset*: string
    order*: seq[string]             ## who receives in round 1, 2, … (members, each once)

  CharterBody* = object
    name*, purpose*: string
    members*: seq[string]           ## the electorate the charter governs (room identity hex)
    amendK*: int                    ## how many members must agree to change the charter
    roles*: seq[CharterRole]
    rules*: seq[(string, string)]   ## action class -> policy, sorted by class
    account*: string                ## CAIP-10 of the charter's account, "" = none
    hasSchedule*: bool
    schedule*: CharterSchedule

  CharterDriver* = ref object of Driver
    roster*: seq[string]            ## the room's members (identity hex), for the sign-path check
    pending: seq[byte]

proc isIdentity(s: string): bool =
  ## A room identity: the 64-byte encryption identity, Ed25519 ++ X25519, lowercase hex —
  ## the name the room and a split give a member.
  s.len == 128 and s.allIt(it in HexDigits) and s == s.toLowerAscii()

proc edHalf(identity: string): string = identity[0 ..< 64]   ## the Ed25519 key a room key signs with

proc isDecimal(s: string): bool = s.len > 0 and s.allIt(it in Digits)

proc stringsOf(n: JsonNode): (bool, seq[string]) =
  if n.kind != JArray: return (false, @[])
  for x in n:
    if x.kind != JString: return (false, @[])
    result[1].add x.getStr()
  result[0] = true

proc allDistinct(xs: seq[string]): bool = xs.deduplicate().len == xs.len

proc parseCharterBody*(j: JsonNode): tuple[ok: bool, body: CharterBody, why: string] =
  ## A charter body, or why it is not one. Closed vocabulary: an unknown key — an org
  ## type above all — refuses the body rather than riding along unread.
  template no(msg: string) = return (false, CharterBody(), msg)
  if j.kind != JObject: no("a charter body is an object")
  for k in j.keys:
    if k notin BodyKeys: no("unknown charter field: " & k)
  var b: CharterBody
  b.name = j{"name"}.getStr()
  if b.name.strip().len == 0: no("a charter has a name")
  b.purpose = j{"purpose"}.getStr()
  let (mok, ms) = stringsOf(j{"members"})
  if not mok or ms.len == 0: no("a charter names its members")
  for m in ms:
    if not isIdentity(m): no("a member is a room identity (128 lowercase hex): " & m)
  if not allDistinct(ms): no("a member appears twice")
  b.members = ms
  let amend = j{"amend"}
  if amend.isNil or amend.kind != JObject or amend{"k"}.isNil or amend{"k"}.kind != JInt: no("a charter says how it is amended: amend {k}")
  b.amendK = amend["k"].getInt()
  if b.amendK < 1 or b.amendK > ms.len: no("1 <= amend k <= members")
  if j.hasKey("roles"):
    if j["roles"].kind != JArray: no("roles is a list")
    for r in j["roles"]:
      let (hok, hs) = stringsOf(r{"holders"})
      if r.kind != JObject or r{"slot"}.getStr().len == 0 or r{"name"}.getStr().len == 0 or not hok:
        no("a role is {slot, name, holders}")
      for h in hs:
        if h notin ms: no("a role holder is not a member")
      if b.roles.anyIt(it.slot == r["slot"].getStr()): no("a role slot appears twice")
      b.roles.add CharterRole(slot: r["slot"].getStr(), name: r["name"].getStr(), holders: hs)
  let rules = j{"rules"}
  if rules.isNil or rules.kind != JObject: no("a charter has a policy table: rules {class: policy}")
  for k, v in rules:
    if v.kind != JString or v.getStr().len == 0 or k.len == 0: no("a rule maps an action class to a policy")
    b.rules.add (k, v.getStr())
  b.rules.sort(proc (x, y: (string, string)): int = cmp(x[0], y[0]))
  if not b.rules.anyIt(it[0] == AmendRule and it[1] == CharterKind):
    no("every charter has a rule for changing rules: " & AmendRule & " -> " & CharterKind)
  b.account = j{"account"}.getStr()
  if b.account.len > 0 and b.account.count(':') < 2: no("the account is CAIP-10: <namespace>:<reference>:<address>")
  if j.hasKey("schedule"):
    let s = j["schedule"]
    let (ook, order) = stringsOf(s{"order"})
    if s.kind != JObject or s{"cadence"}.isNil or s{"cadence"}.kind != JInt or not ook:
      no("a schedule is {cadence, share, asset, order}")
    b.hasSchedule = true
    b.schedule = CharterSchedule(cadenceSec: s["cadence"].getBiggestInt(), share: s{"share"}.getStr(),
                                 asset: s{"asset"}.getStr(), order: order)
    if b.schedule.cadenceSec <= 0: no("a schedule's cadence is positive")
    if not isDecimal(b.schedule.share): no("a schedule's share is a decimal amount")
    if b.schedule.asset.len == 0: no("a schedule names its asset")
    if not allDistinct(order) or order.anyIt(it notin ms): no("the round order lists members, each once")
  (true, b, "")

proc circleTemplate*(name, purpose: string, members: seq[string], amendK: int,
                     account = "", share = "", asset = "", cadenceSec = 0'i64): JsonNode =
  ## The savings circle as a charter TEMPLATE: members who pay in each round and receive
  ## in turn, the order as given, payouts and member changes decided on the circle's
  ## account. A template only fills a body; nothing downstream asks whether a room is a
  ## circle (doctrine: capabilities, never types).
  result = %*{"name": name, "purpose": purpose, "members": members, "amend": {"k": amendK},
              "roles": [], "rules": {AmendRule: CharterKind}}
  if account.len > 0:
    result["account"] = %account
    let ns = account.split(':')[0]
    let kind = (if ns == "lez": "lez-multisig" elif ns == "eip155": "safe" else: "")
    if kind.len > 0:
      result["rules"]["payout"] = %(kind & "@" & account)
      result["rules"]["member-change"] = %(kind & "@" & account)
  if share.len > 0:
    result["schedule"] = %*{"cadence": cadenceSec, "share": share, "asset": asset, "order": members}

# ── the effect ────────────────────────────────────────────────────────────────
proc fieldOf(e: Effect, name: string): (bool, CborValue) =
  for (k, v) in e.fields:
    if k == name: return (true, v)

type CharterEffect* = object
  prev*: string
  electorate*: seq[string]
  k*: int
  bodyText*: string
  body*: CharterBody

proc charterOf*(e: Effect): tuple[ok: bool, c: CharterEffect, why: string] =
  ## The charter an effect carries, or why it carries none. Holds the founding rule; the
  ## amendment rule needs the log (coordination/charter.nim).
  template no(msg: string) = return (false, CharterEffect(), msg)
  if e.schemaId != CharterSchema: no("not a charter")
  var c: CharterEffect
  let (pok, p) = e.fieldOf("prev")
  if not pok or p.kind != ckText: no("a charter names the charter it amends (prev, \"\" to found)")
  c.prev = p.t
  let (eok, el) = e.fieldOf("electorate")
  if not eok or el.kind != ckArray: no("a charter names who decides it (electorate)")
  for x in el.arr:
    if x.kind != ckText or not isIdentity(x.t): no("an elector is a room identity (128 lowercase hex)")
    c.electorate.add x.t
  if c.electorate.len == 0 or not allDistinct(c.electorate): no("the electorate is non-empty and distinct")
  let (kok, kv) = e.fieldOf("k")
  if not kok or kv.kind != ckUint: no("a charter says how many electors decide it (k)")
  c.k = int(kv.u)
  if c.k < 1 or c.k > c.electorate.len: no("1 <= k <= electorate")
  let (bok, bt) = e.fieldOf("body")
  if not bok or bt.kind != ckText: no("a charter carries its body")
  c.bodyText = bt.t
  var bj: JsonNode
  try: bj = parseJson(bt.t)
  except CatchableError: no("the body is JSON")
  let (ok, body, why) = parseCharterBody(bj)
  if not ok: no(why)
  c.body = body
  if c.prev.len == 0 and (sorted(c.electorate) != sorted(body.members) or c.k != body.members.len):
    no("a founding charter is decided by every member it names, and only by them")
  (true, c, "")

proc foundingEffect*(body: JsonNode): string =
  ## The effect JSON that founds a room's charter: every member it names decides it.
  var members: seq[string]
  for m in body{"members"}.getElems(): members.add m.getStr()
  $(%*{"effect": "charter", "prev": "", "electorate": members, "k": members.len, "body": body})

proc amendEffectJson*(prev: string, electorate: seq[string], k: int, body: JsonNode): string =
  $(%*{"effect": "charter", "prev": prev, "electorate": electorate, "k": k, "body": body})

# ── the driver ────────────────────────────────────────────────────────────────
proc newCharterDriver*(roster: seq[string] = @[]): CharterDriver =
  CharterDriver(roster: roster.mapIt(it.toLowerAscii().replace("0x", "")))

method describe*(d: CharterDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: CharterDomain, finality: finImmediate, threshold: 1)

method describeFor*(d: CharterDriver, e: Effect): DriverDescriptor =
  result = d.describe()
  let (ok, c, _) = charterOf(e)
  if ok: result.threshold = c.k

method electorateFor*(d: CharterDriver, e: Effect): int =
  let (ok, c, _) = charterOf(e)
  if ok: c.electorate.len else: 0

method canonicalize*(d: CharterDriver, e: Effect): Materialization =
  ## dCBOR [domain, schema, prev, [electorate…, sorted], k, body]; a malformed charter is a
  ## sentinel no elector is named in, so nothing can agree to it.
  let (ok, c, why) = charterOf(e)
  if not ok:
    return Materialization(bytes: encode(cbArray(@[cbText(CharterDomain), cbText("invalid: " & why)])))
  Materialization(bytes: encode(cbArray(@[cbText(CharterDomain), cbText(CharterSchema), cbText(c.prev),
    cbArray(sorted(c.electorate).mapIt(cbText(it))), cbUint(uint64(c.k)), cbText(c.bodyText)])))

proc electorateOf(mat: seq[byte]): seq[string] =
  try:
    let v = decode(mat)
    if v.kind == ckArray and v.arr.len == 6 and v.arr[0].kind == ckText and v.arr[0].t == CharterDomain and
       v.arr[3].kind == ckArray:
      for x in v.arr[3].arr:
        if x.kind == ckText: result.add x.t
  except CatchableError: discard

proc edOf(identity: string): Ed25519Pub =
  for i in 0 ..< 32: result[i] = byte(parseHexInt(identity[2*i .. 2*i+1]))

proc electorOf(mat: seq[byte], c: Contribution): string =
  ## "ed:<hex>" of the elector whose room key signed `mat`, else "".
  if c.bytes.len != 64: return ""
  var sig: Ed25519Sig
  for i in 0 ..< 64: sig[i] = c.bytes[i]
  for who in electorateOf(mat):
    if who.len == 128 and edVerify(edOf(who), mat, sig): return "ed:" & edHalf(who)
  ""

method expectMaterialization*(d: CharterDriver, m: Materialization) = d.pending = m.bytes

method verifyContribution*(d: CharterDriver, c: Contribution, round: int): bool =
  electorOf(d.pending, c).len > 0

method identifyContributor*(d: CharterDriver, m: Materialization, c: Contribution): string =
  electorOf(m.bytes, c)

method mayContribute*(d: CharterDriver, e: Effect, names: seq[string]): Eligibility =
  let (ok, c, _) = charterOf(e)
  if not ok: return elNo
  let mine = bareNames(names)
  for who in c.electorate:
    if edHalf(who) in mine or who in mine: return elYes
  elNo

method signRefusal*(d: CharterDriver, e: Effect): string =
  ## A malformed charter, a founding not decided by all it names, or — on this client's
  ## propose / sign path — an elector who is not in the room: nobody could agree for them.
  let (ok, c, why) = charterOf(e)
  if not ok: return why
  if d.roster.len > 0:
    for who in c.electorate & c.body.members:
      if who notin d.roster: return "a member the charter names (" & who[0 ..< 12] & "…) is not in this room"
  ""

method manifest*(d: CharterDriver, effect: Effect): ActionManifest =
  ## A decision the room keeps: the electorate's room keys, nothing leaves the room.
  ActionManifest(declared: true, agreement: d.describeFor(effect),
                 requirements: @[req(rqAuthority, "charter-elector", rpContributor)])

method profile*(d: CharterDriver): FamilyProfile =
  ## room.threshold, its electorate named per proposal: final in the room.
  roomProfile("room.threshold", d.describe(), 0)
