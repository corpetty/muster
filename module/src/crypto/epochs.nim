## Membership epochs (spec: contracts/specs/derived-exo-525.spec.json,
## invariant 7, catastrophic).
##
## Epochs are real, not cosmetic. Adding a member advances the epoch by a forward
## RATCHET — key(E+1) = H(key(E)) — so existing members derive the new key while a
## joiner, handed only key(E+1), cannot invert the hash to read any earlier epoch.
## Removing a member advances the epoch with a FRESH, independent key (not a
## ratchet of the old one) distributed only to the remaining members, so the
## removed member's last-held key derives nothing forward — rotation is immediate.
##
## A member can decrypt epoch E iff they can DERIVE key(E): from some key they were
## directly handed, ratcheting forward only across add-transitions, never past a
## fresh (removal) break. That derivation model is what makes the probes
## discriminating — a scheme that ratcheted on removal would let a removed member
## compute the next key, and s3 would catch it.
##
## Keys here are a P0/P1 stand-in over the module's own SHA-256; ECIES-secp256k1
## wrap to members arrives with real transport (P3). The epoch STRUCTURE — the
## ratchet/fresh boundary and who holds what — is what this invariant is about and
## survives the primitive swap.

import std/[tables, sets]
import ../hashing/hash_input
import ../dcbor/dcbor

type
  TransitionKind* = enum
    tkRatchet   ## created by an add — key(E) = H(key(E-1))
    tkFresh     ## created by a remove (or genesis) — key(E) independent

  MemberId* = string

  Group* = object
    epoch*: int
    members*: seq[MemberId]
    transitions*: seq[TransitionKind]     ## transitions[E] created epoch E
    keys*: seq[seq[byte]]                 ## keys[E]
    given*: Table[MemberId, HashSet[int]] ## epochs a member was handed a key at
    joinEpoch*: Table[MemberId, int]      ## current members' join epoch

proc h(parts: seq[(string, CborValue)]): seq[byte] =
  @(digest(hashInput("muster.epoch.v1", parts)))

proc newGroup*(founders: seq[MemberId]): Group =
  result.epoch = 0
  result.members = founders
  result.transitions = @[tkFresh]                       # genesis is a fresh key
  result.keys = @[h(@[("genesis", cbUint(0'u64))])]
  result.given = initTable[MemberId, HashSet[int]]()
  result.joinEpoch = initTable[MemberId, int]()
  for m in founders:
    result.given[m] = toHashSet([0])
    result.joinEpoch[m] = 0

proc addMember*(g: var Group, m: MemberId) =
  ## Ratchet forward; existing members derive key(E+1), the new member is handed it.
  let e = g.epoch + 1
  g.epoch = e
  g.transitions.add tkRatchet
  g.keys.add h(@[("ratchet", cbBytes(g.keys[e-1]))])
  if m notin g.members: g.members.add m
  g.given[m] = toHashSet([e])          # joiner gets only this epoch onward
  g.joinEpoch[m] = e

proc removeMember*(g: var Group, m: MemberId) =
  ## Fresh key (breaks the ratchet); handed only to remaining members.
  let e = g.epoch + 1
  g.epoch = e
  g.transitions.add tkFresh
  g.keys.add h(@[("fresh", cbUint(uint64(e))), ("removed", cbText(m))])
  let idx = g.members.find(m)
  if idx >= 0: g.members.delete(idx)
  g.given.del(m)
  g.joinEpoch.del(m)
  for rm in g.members:
    if rm notin g.given: g.given[rm] = initHashSet[int]()
    g.given[rm].incl e

proc canDerive*(g: Group, m: MemberId, target: int): bool =
  ## True iff m can reach key(target): from some handed epoch g0 <= target with an
  ## unbroken ratchet chain (no fresh transition) from g0 to target.
  if m notin g.given: return false
  for g0 in g.given[m]:
    if g0 > target: continue
    var ok = true
    for e in (g0 + 1) .. target:
      if g.transitions[e] != tkRatchet: ok = false; break
    if ok: return true
  false

proc derivedKeyEpochs*(g: Group, m: MemberId): HashSet[int] =
  for e in 0 .. g.epoch:
    if g.canDerive(m, e): result.incl e

proc keyValue*(g: Group, e: int): seq[byte] = g.keys[e]
