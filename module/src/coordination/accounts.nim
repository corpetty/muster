## Accounts live in the room, disclosed by members (exo-a50.1.3; seam S1 of
## docs/design/multisig-landscape.md; decision 2026-09-23).
##
## A room coordinates FROM accounts — a Safe, and (Phase B on) a Bitcoin vault, a LEZ
## multisig, a FROST key. An account exists to the room only once a named member
## discloses it into the log:
##
##   "account/<CAIP-10 id>/disclose/<discloser>"  value = {family, chain, address,
##                                                        label, signers, threshold}
##
## The fold is pure (invariant 4): one account per id, every discloser named, and the
## FIRST disclosure in canonical order governs — a second member who discloses a
## different signer set or threshold for the same account does not overwrite it; the
## account is flagged `conflict` so the room sees the disagreement. Whether the
## disclosure is TRUE is a separate question each reader asks of the chain
## (checkAccount over a ChainView the host reads — an external read, invariant 10):
## verified / disagrees / unknown. The fold never reads the network.
##
## An account-bound intent names its account in its policy ("safe@<id>", kinds.nim),
## and driverForPolicy resolves it against the disclosed accounts: a bare "safe", an
## undisclosed account, an account of the wrong family, or an account on a room kind is
## UNSUPPORTED — never a module-global fixture.

import std/[json, strutils, tables, algorithm, sequtils]
import ../log/log
import ../drivers/driver
import ../drivers/kinds
import ../drivers/safe
import ../drivers/eip191
import ../drivers/btc_multisig   # Bitcoin accounts (exo-a50.2.3)
import ../drivers/lez_multisig   # LEZ multisig accounts (exo-6cbe)
import ../drivers/btc_frost      # FROST accounts: the ceremony's recovery data (Phase D)
import ../drivers/lez_frost      # a FROST group's LEZ public account (exo-55e)
import ../lez/multisig as lezms
import ../lez/multisig_chain
import ../crypto/secp256k1

type
  RoomAccount* = object
    id*: string              ## CAIP-10: "<chain>:<address>", address lowercased
    family*: string          ## registry family ("evm.safe")
    chain*: string           ## CAIP-2 ("eip155:31337")
    address*: string         ## lowercased
    label*: string           ## what the discloser calls it
    signers*: seq[string]    ## as disclosed (lowercased)
    threshold*: int          ## as disclosed
    disclosedBy*: seq[string] ## every member who disclosed it, first-seen (canonical) order
    conflict*: bool          ## members disclosed different signers / threshold / config for it
    config*: string          ## the family's config, as JSON text ("" = none); a LEZ multisig
                             ## discloses {program, createKey, pda} — its address derives from it

  AccountCheck* = enum
    acVerified = "verified"
    acDisagrees = "disagrees"
    acUnknown = "unknown"

  ChainView* = tuple[known: bool, signers: seq[string], threshold: int, detail: string]
    ## what the host read from the chain for an account; known=false = could not read

proc accountId*(chain, address: string): string = chain & ":" & address.toLowerAscii()

proc splitAccountId*(id: string): tuple[chain, address: string] =
  ## CAIP-10 → (CAIP-2 chain, address): the address is after the LAST ':'.
  let i = id.rfind(':')
  if i < 0: ("", id) else: (id[0 ..< i], id[i+1 .. ^1])

proc disclosureJson(a: RoomAccount): JsonNode =
  result = %*{"family": a.family, "chain": a.chain, "address": a.address.toLowerAscii(),
              "label": a.label, "signers": a.signers.mapIt(it.toLowerAscii()), "threshold": a.threshold}
  if a.config.len > 0: result["config"] = %a.config   # only when present: older disclosures keep their bytes

proc accountDiscloseEvent*(a: RoomAccount, discloser: string): Event =
  ## A member discloses an account into the room. Keyed per discloser, so two members
  ## disclosing the same account fold as one account disclosed by both.
  Event(key: "account/" & accountId(a.chain, a.address) & "/disclose/" & discloser,
        value: $disclosureJson(a))

proc sameConfig(a, b: RoomAccount): bool =
  a.family == b.family and a.threshold == b.threshold and a.config == b.config and
    sorted(a.signers.mapIt(it.toLowerAscii())) == sorted(b.signers.mapIt(it.toLowerAscii()))

proc reduceAccounts*(events: seq[Event]): seq[RoomAccount] =
  ## Every disclosed account, in canonical order of first disclosure.
  var at = initTable[string, int]()
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len != 4 or p[0] != "account" or p[2] != "disclose": continue
    var d: RoomAccount
    try:
      let j = parseJson(e.value)
      d = RoomAccount(family: j{"family"}.getStr(), chain: j{"chain"}.getStr(),
                      address: j{"address"}.getStr().toLowerAscii(), label: j{"label"}.getStr(),
                      threshold: j{"threshold"}.getInt(), config: j{"config"}.getStr())
      if j.hasKey("signers") and j["signers"].kind == JArray:
        for s in j["signers"]: d.signers.add s.getStr().toLowerAscii()
    except CatchableError: continue
    d.id = accountId(d.chain, d.address)
    if d.id != p[1] or d.family.len == 0 or d.chain.len == 0: continue   # key and body must agree
    if d.id notin at:
      d.disclosedBy = @[p[3]]
      at[d.id] = result.len
      result.add d
    else:
      var cur = result[at[d.id]]
      if p[3] notin cur.disclosedBy: cur.disclosedBy.add p[3]
      if not sameConfig(cur, d): cur.conflict = true
      result[at[d.id]] = cur

proc findAccount*(accounts: seq[RoomAccount], id: string): tuple[found: bool, account: RoomAccount] =
  for a in accounts:
    if a.id == id.toLowerAscii() or a.id == id: return (true, a)
  (false, RoomAccount())

proc checkAccount*(a: RoomAccount, view: ChainView): tuple[status: AccountCheck, detail: string] =
  ## Does the chain agree with what was disclosed? Owner order and address case never
  ## matter; a missing or extra signer, or a different threshold, is named.
  if not view.known: return (acUnknown, "could not read the account from the chain: " & view.detail)
  let disclosed = a.signers.mapIt(it.toLowerAscii())
  let onChain = view.signers.mapIt(it.toLowerAscii())
  var diffs: seq[string]
  for s in disclosed:
    if s notin onChain: diffs.add "disclosed signer " & s & " is not a signer on-chain"
  for s in onChain:
    if s notin disclosed: diffs.add "on-chain signer " & s & " was not disclosed"
  if view.threshold != a.threshold:
    diffs.add "threshold is " & $view.threshold & " on-chain, " & $a.threshold & " as disclosed"
  if diffs.len == 0: (acVerified, "the chain agrees: " & $a.threshold & " of " & $disclosed.len)
  else: (acDisagrees, diffs.join("; "))

proc toAddress*(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< min(20, h.len div 2):
    try: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard

proc evmChainId*(chain: string): (bool, uint64) =
  if not chain.startsWith("eip155:"): return (false, 0'u64)
  try: (true, uint64(parseBiggestUInt(chain[7 .. ^1])))
  except ValueError: (false, 0'u64)

proc driverForPolicy*(policy: string, accounts: seq[RoomAccount],
                      roomBuild: proc(kind: string): Driver,
                      delegatecallAllow: seq[Address] = @[]): Driver =
  ## Resolve an intent's policy against the room's disclosed accounts. A room kind is
  ## built by the host (`roomBuild`, its roster wiring); an account-bound kind is built
  ## FROM the disclosure. Anything that cannot be resolved honestly is unsupported.
  let (kind, acct) = splitPolicy(policy)
  if not isKnownKind(kind): return newUnsupportedDriver(policy)
  if not kindNeedsAccount(kind):
    return (if acct.len > 0: newUnsupportedDriver(policy) else: roomBuild(kind))
  if acct.len == 0: return newUnsupportedDriver(policy)          # which account? never guessed
  let (found, a) = findAccount(accounts, acct)
  if not found: return newUnsupportedDriver(policy)              # not disclosed in this room
  if a.family notin kindInfo(kind).accountFamilies: return newUnsupportedDriver(policy)
  let signers = (if a.family.startsWith("evm."): a.signers.mapIt(toAddress(it)) else: @[])
  case kind
  of "safe":
    let (ok, chainId) = evmChainId(a.chain)
    if not ok: return newUnsupportedDriver(policy)
    let sd = newSafeDriver(chainId = chainId, safe = toAddress(a.address), owners = signers,
                           threshold = max(1, a.threshold))
    sd.delegatecallAllow = delegatecallAllow   # THIS client's local opt-in (exo-a50.1.4)
    sd
  of "eip191":
    # an attestation by the account's signers: one recognized signer completes it
    newPersonalSignDriver(signers = signers, threshold = 1)
  of "btc-p2wsh", "btc-tapscript":
    # a Bitcoin account: its address must commit to exactly the disclosed keys and k —
    # a disclosure that does not is refused, never trusted (exo-a50.2.3)
    let (ok, acct, _) = btcAccountOfDisclosure(a.family, a.chain, a.address, a.threshold, a.signers)
    if not ok: return newUnsupportedDriver(policy)
    newBtcMultisigDriver(acct)
  of "lez-multisig":
    # a LEZ multisig account: its address must be the state PDA its config derives
    # (exo-6cbe) — a disclosure that does not commit to its config is refused
    let (ok, acct, _) = lezMultisigAccountFromParts(a.chain, a.address, a.config, a.signers, a.threshold)
    if not ok: return newUnsupportedDriver(policy)
    newLezMultisigDriver(acct)
  of "btc-frost":
    # a FROST account (Phase D): its address must be the threshold key its recovery data
    # derives — the ceremony itself, re-derived, never taken on trust
    var rec = ""
    try: rec = parseJson(a.config)["recovery"].getStr()
    except CatchableError: return newUnsupportedDriver(policy)
    let (ok, acct, _) = frostAccountOfDisclosure(a.chain, a.address, rec)
    if not ok: return newUnsupportedDriver(policy)
    newBtcFrostDriver(acct)
  of "lez-frost":
    # a FROST group's LEZ account: its id must be the threshold key its recovery data derives
    var rec = ""
    try: rec = parseJson(a.config)["recovery"].getStr()
    except CatchableError: return newUnsupportedDriver(policy)
    let (ok, acct, _) = lezFrostAccountOfDisclosure(a.chain, a.address, rec)
    if not ok: return newUnsupportedDriver(policy)
    newLezFrostDriver(acct)
  else: newUnsupportedDriver(policy)

proc accountsJson*(accounts: seq[RoomAccount]): JsonNode =
  result = newJArray()
  for a in accounts:
    var o = disclosureJson(a)
    o["id"] = %a.id
    o["disclosedBy"] = %a.disclosedBy
    o["conflict"] = %a.conflict
    result.add o

proc allSigners*(accounts: seq[RoomAccount]): seq[Address] =
  ## Every signer any disclosed account names — what "is this key a signer here?" asks.
  for a in accounts:
    for s in a.signers:
      let ad = toAddress(s)
      if ad notin result: result.add ad

proc frostDisclosureOf*(a: RoomAccount): tuple[ok: bool, account: FrostAccount, detail: string] =
  ## A FROST disclosure, re-derived from the recovery data in its config.
  var rec: string
  try: rec = parseJson(a.config)["recovery"].getStr()
  except CatchableError: return (false, FrostAccount(), "no recovery data in the config")
  frostAccountOfDisclosure(a.chain, a.address, rec)

proc frostDisclosureCheck*(a: RoomAccount): tuple[status: AccountCheck, detail: string] =
  ## Verified without a chain read: the recovery data derives the address, or it does not.
  let (ok, _, detail) = frostDisclosureOf(a)
  ((if ok: acVerified else: acDisagrees), detail)

proc btcDisclosureCheck*(a: RoomAccount): tuple[status: AccountCheck, detail: string] =
  ## A Bitcoin disclosure is verified WITHOUT a chain read: the address commits to the
  ## policy, so re-deriving it from the disclosed keys and k either reproduces it
  ## (verified) or does not (disagrees) (exo-a50.2.3).
  let (ok, _, detail) = btcAccountOfDisclosure(a.family, a.chain, a.address, a.threshold, a.signers)
  let status = (if ok: acVerified else: acDisagrees)
  (status, detail)

proc lezMultisigAccountOf*(a: RoomAccount): tuple[ok: bool, account: LezMultisigAccount, detail: string] =
  ## A disclosed LEZ multisig account, re-derived from its config (exo-6cbe).
  lezMultisigAccountFromParts(a.chain, a.address, a.config, a.signers, a.threshold)

proc lezChainView*(chain: LezMultisigChain, a: RoomAccount): ChainView =
  ## What the chain says about a disclosed LEZ multisig: its state, read at the PDA the
  ## disclosure's config derives (an external read, invariant 10). Unknown when the
  ## disclosure does not derive, the state is not there, or it does not decode.
  let (ok, acct, detail) = lezMultisigAccountOf(a)
  if not ok and acct.statePda.len == 0: return (false, @[], 0, detail)
  try:
    let r = chain.readAccount(acct.statePda)
    if not r.found: return (false, @[], 0, "no multisig state on " & a.chain & " at that address (height " & $r.height & ")")
    let st = lezms.decodeState(r.data)
    if st.createKey != acct.createKey: return (false, @[], 0, "the state at that address belongs to another create_key")
    var signers: seq[string]
    for m in st.members:
      var h = ""
      for x in m: h.add toLowerAscii(toHex(x, 2))
      signers.add h
    (true, signers, st.threshold, "read at height " & $r.height)
  except CatchableError as e:
    (false, @[], 0, "could not read the multisig state: " & e.msg)
