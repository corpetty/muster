## The address book — a persisted map from a room-membership id (the 64-byte
## encryption identity, ed25519 ++ x25519 hex, as coordinate_admit/members speak) to
## an alias and an optional secp address. Module-side and persisted beside the
## keystore, so it survives restarts and is the ONE source of truth the roster,
## pending-list, and composer resolve names against — you see "Alice", not ed:9f3c…
##
## Pure Nim (json/os/tables) — headless-testable; the module wires the path in.

import std/[json, os, tables, strutils]

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
    createDir(parentDir(b.path))
    var o = newJObject()
    for id, c in b.byId:
      o[id] = %*{"alias": c.alias, "address": c.address}
    writeFile(b.path, $o)
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

proc add*(b: ContactBook, identity, alias: string, address = "") =
  ## Add or replace a contact. Merges: an empty alias/address does not clobber a
  ## stored one, so `add(id, "")` from an admit can seed a contact that a later
  ## rename fills in.
  let id = normId(identity)
  if id.len == 0: return
  var c = (if id in b.byId: b.byId[id] else: Contact(identity: id))
  if alias.len > 0: c.alias = alias
  if address.len > 0: c.address = address
  b.byId[id] = c
  b.save()

proc setAlias*(b: ContactBook, identity, alias: string) =
  let id = normId(identity)
  if id.len == 0: return
  var c = (if id in b.byId: b.byId[id] else: Contact(identity: id))
  c.alias = alias
  b.byId[id] = c
  b.save()

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
  ## The address-book view: [{identity, alias, address}].
  result = newJArray()
  for id, c in b.byId:
    result.add %*{"identity": c.identity, "alias": c.alias, "address": c.address}
