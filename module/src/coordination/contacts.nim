## The address book — a persisted map from a room-membership id (the 64-byte
## encryption identity, ed25519 ++ x25519 hex, as coordinate_admit/members speak) to
## an alias and an optional secp address. Module-side and persisted beside the
## keystore, so it survives restarts and is the ONE source of truth the roster,
## pending-list, and composer resolve names against — you see "Alice", not ed:9f3c…
##
## Pure Nim (json/os/tables) — headless-testable; the module wires the path in.

import std/[json, os, tables, strutils, unicode]
import ../security/private_files
import ../security/text_controls
export text_controls.mixesScripts

type
  Contact* = object
    identity*: string   ## normalized: lowercase hex, no 0x — the coordinate_admit key
    alias*: string
    address*: string    ## optional secp address (for the payment side)
  ContactBook* = ref object
    path: string
    byId: OrderedTable[string, Contact]

proc normId*(hex: string): string =
  ## The canonical key: lowercase hex without a 0x prefix, whitespace stripped — so a
  ## contact added from a shared chat id matches a member's toHex() identity.
  var h = hex.strip()
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  h.toLowerAscii()

proc save(b: ContactBook) =
  try:
    var o = newJObject()
    for id, c in b.byId:
      o[id] = %*{"alias": c.alias, "address": c.address}
    writePrivateFile(b.path, $o)
  except CatchableError: discard

proc newContactBook*(path: string): ContactBook =
  ## Load the book from `path` (a JSON object id → {alias, address}); a missing or
  ## malformed file yields an empty book, never a raise.
  result = ContactBook(path: path, byId: initOrderedTable[string, Contact]())
  try:
    if fileExists(path):
      let j = parseJson(readFile(path))
      if j.kind == JObject:
        for id, v in j:
          if v.kind == JObject:
            result.byId[id] = Contact(identity: id, alias: v{"alias"}.getStr(),
                                      address: v{"address"}.getStr())
  except CatchableError: discard

proc cleanAlias(alias: string): string =
  ## An alias as stored: no format controls (they hide or reorder what it shows, exo-3b3.18),
  ## no surrounding space.
  stripFormatControls(alias).strip()

proc aliasRefusal*(b: ContactBook, identity, alias: string): string =
  ## Why `alias` may not name `identity`, or "": another contact already has it, in any case
  ## (a second "Alice" would be indistinguishable on every surface; exo-3b3.18, audit P4-09).
  ## An empty alias is never a duplicate.
  let id = normId(identity)
  let a = cleanAlias(alias)
  if a.len == 0: return ""
  let key = unicode.toLower(a)
  for other, c in b.byId:
    if other != id and c.alias.len > 0 and unicode.toLower(c.alias) == key:
      return "another contact is already named " & c.alias
  ""

proc add*(b: ContactBook, identity, alias: string, address = ""): string {.discardable.} =
  ## Add or replace a contact. Merges: an empty alias/address does not clobber a
  ## stored one, so `add(id, "")` from an admit can seed a contact that a later
  ## rename fills in. Returns "" or why the alias is refused (aliasRefusal); a refused
  ## add stores nothing.
  let id = normId(identity)
  if id.len == 0: return "no identity"
  let a = cleanAlias(alias)
  let why = b.aliasRefusal(id, a)
  if why.len > 0: return why
  var c = (if id in b.byId: b.byId[id] else: Contact(identity: id))
  if a.len > 0: c.alias = a
  if address.len > 0: c.address = address
  b.byId[id] = c
  b.save()
  ""

proc setAlias*(b: ContactBook, identity, alias: string): string {.discardable.} =
  ## Rename a contact (or create it with just an alias). Returns "" or why it is refused.
  let id = normId(identity)
  if id.len == 0: return "no identity"
  let a = cleanAlias(alias)
  let why = b.aliasRefusal(id, a)
  if why.len > 0: return why
  var c = (if id in b.byId: b.byId[id] else: Contact(identity: id))
  c.alias = a
  b.byId[id] = c
  b.save()
  ""

proc remove*(b: ContactBook, identity: string) =
  let id = normId(identity)
  if id in b.byId:
    b.byId.del(id)
    b.save()

proc aliasOf*(b: ContactBook, identity: string): string =
  ## The alias for an id, or "" if unknown — the roster/pending resolver.
  let id = normId(identity)
  if id in b.byId: b.byId[id].alias else: ""

proc asJson*(b: ContactBook): JsonNode =
  ## The address-book view: [{identity, alias, address, mixedScript}]. `mixedScript` flags an
  ## alias mixing Latin letters with Cyrillic or Greek ones (a look-alike "Аlice"), for the
  ## UI to show; the alias itself is the person's and is kept as they typed it.
  result = newJArray()
  for id, c in b.byId:
    result.add %*{"identity": c.identity, "alias": c.alias, "address": c.address,
                  "mixedScript": mixesScripts(c.alias)}

proc nameFor*(b: ContactBook, who: string): string =
  ## A contributor's alias, however its driver names it (exo-59c): the 64-byte identity,
  ## "ed:" / "frost:" + an Ed25519 key (the identity's first half), or a secp address
  ## (matched against each contact's address). "" when no contact matches.
  var w = who.strip()
  for p in ["ed:", "frost:"]:
    if w.startsWith(p): w = w[p.len .. ^1]
  let id = normId(w)
  if id.len == 0: return ""
  if id in b.byId: return b.byId[id].alias
  if id.len == 64:
    for k, c in b.byId:
      if k.len == 128 and k[0 ..< 64] == id: return c.alias
  if id.len == 40:
    for _, c in b.byId:
      if c.address.len > 0 and normId(c.address) == id: return c.alias
  ""

proc bareId(who: string): string =
  ## An id as a member is known across drivers: no "ed:" / "frost:" prefix, no 0x, lowercase.
  var w = who.strip()
  for p in ["ed:", "frost:"]:
    if w.startsWith(p): w = w[p.len .. ^1]
  normId(w)

proc sameMember(a, b: string): bool =
  ## Two bare ids name the same member: equal, or one is the Ed25519 half (the first 64
  ## hex) of the other's 64-byte identity.
  if a.len == 0 or b.len == 0: return false
  if a == b: return true
  (a.len == 64 and b.len == 128 and b[0 ..< 64] == a) or
    (b.len == 64 and a.len == 128 and a[0 ..< 64] == b)

proc shortMember*(who: string): string =
  ## One short form for a member no one has named, the same whichever form a driver used:
  ## an identity (or its Ed25519 half) by its first 8 hex; an address by both ends.
  let id = bareId(who)
  if id.len == 40: "0x" & id[0 ..< 4] & "…" & id[^4 .. ^1]
  elif id.len > 8: id[0 ..< 8] & "…"
  else: id

proc memberLabel*(b: ContactBook, who: string, mine: seq[string]): string =
  ## The one name for a member on every surface — the card, the approval slots, the room
  ## history (exo-221): "you" when `who` is any of `mine` (my identity, my address), the
  ## contact alias when there is one, else shortMember. Whichever form the driver named
  ## the member by — the 64-byte identity, "ed:" + its Ed25519 half, an address — the
  ## answer is the same.
  let id = bareId(who)
  for m in mine:
    if sameMember(id, bareId(m)): return "you"
  let alias = b.nameFor(who)
  if alias.len > 0: alias else: shortMember(who)
