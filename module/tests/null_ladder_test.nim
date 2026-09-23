## The null ladder, typed onto the ChainAdapter seam (exo-1ec.5). The pattern is already in
## the code, unnamed: a transparent chain and a shielded chain are the null and the real
## CONFIDENTIALITY level at the SAME seam. This proves the level is a TYPED ATTRIBUTE the
## adapter declares (securityLevel), read by a consumer via the axis rung — never inferred by
## branching on the concrete adapter type. Links stint + libsodium (wallet types + keystore).

import std/[strutils, json]
import ../src/wallet/adapter
import ../src/wallet/mock_chain
import ../src/security/levels
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/drivers/driver
import ../src/transport/transport

# A consumer decides purely from the level — the SAME code for either adapter. No `of`
# pattern-match on the concrete type: that is the whole point of typing the seam.
proc mayCarryHiddenAmount(a: ChainAdapter): bool =
  a.securityLevel().atLeast(axConfidentiality, rungReal)

# ── 1. two adapters at one seam declare DIFFERENT confidentiality rungs ────────────
block:
  let transparent = ChainAdapter()          # the base seam default = the transparent null
  let shielded = newMockChain()             # the shielded chain = the real level
  doAssert transparent.securityLevel().rungOf(axConfidentiality) == rungNull,
    "a transparent chain fills confidentiality with the null"
  doAssert shielded.securityLevel().rungOf(axConfidentiality) == rungReal,
    "a shielded chain fills the same seam with the real thing"
  # the mechanism is NAMED for display, not a bare null/real.
  doAssert transparent.securityLevel().mechanismOf(axConfidentiality).contains("transparent")
  doAssert shielded.securityLevel().mechanismOf(axConfidentiality).contains("shielded")
  echo "1. two adapters at one seam declare different confidentiality rungs OK"

# ── 2. a consumer reads the LEVEL, never branches on the concrete type ─────────────
block:
  doAssert not mayCarryHiddenAmount(ChainAdapter()), "transparent: no hidden amount"
  doAssert mayCarryHiddenAmount(newMockChain()), "shielded: hidden amount — read from the level"
  echo "2. a consumer reads the typed level, not the concrete adapter type OK"

# ── 3. an adapter does not OVERCLAIM — it declares null on axes it does not govern ──
block:
  # A chain seam does not authenticate the room member and reads from untrusted RPC (inv 8),
  # so both adapters honestly declare those axes null — never a level they do not provide.
  var adapters: seq[ChainAdapter] = @[ChainAdapter(), newMockChain()]
  for a in adapters:
    doAssert a.securityLevel().rungOf(axAuthentication) == rungNull
    doAssert a.securityLevel().rungOf(axProvenance) == rungNull
  echo "3. an adapter declares null on the axes it does not govern (no overclaim) OK"

# ── 4. ConversationCrypto: the epoch layer is the CONFIDENTIALITY real ─────────────
block:
  proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let ks = newInMemoryKeystore(seed(1), seed(2))
  let cc = newEpochCrypto(ks)
  doAssert cc.securityLevel().rungOf(axConfidentiality) == rungReal, "the epoch layer seals room data"
  doAssert cc.securityLevel().mechanismOf(axConfidentiality).contains("ECIES")
  # the base (no crypto configured) is the null at the same seam.
  doAssert ConversationCrypto().securityLevel().rungOf(axConfidentiality) == rungNull
  # it does not claim to authenticate or attest — those are other seams' axes.
  doAssert cc.securityLevel().rungOf(axAuthentication) == rungNull
  doAssert cc.securityLevel().rungOf(axProvenance) == rungNull
  echo "4. ConversationCrypto: the epoch layer is the confidentiality real, null base OK"

# ── 5. driver membership is the AUTHENTICATION axis (named real / anon null terminal) ─
block:
  let named = newStubDriver(rounds = 1, threshold = 1, membership = mmNamed).describe().securityLevel()
  let anon  = newStubDriver(rounds = 1, threshold = 1, membership = mmAnonymous).describe().securityLevel()
  doAssert named.rungOf(axAuthentication) == rungReal, "a named driver binds the speaker"
  doAssert anon.rungOf(axAuthentication) == rungNull, "an anonymous driver is the auth null"
  doAssert anon.mechanismOf(axAuthentication).contains("terminal"), "the anon null is a legitimate terminal (inv 9)"
  echo "5. driver membership maps to the authentication axis (named real / anon terminal null) OK"

# ── 6. Transport declares NO security level (opaque byte carrier — no overclaim) ────
block:
  let t = newLocalTransport(newLocalNetwork())
  for ax in SecurityAxis:
    doAssert t.securityLevel().rungOf(ax) == rungNull, "transport provides no level on " & $ax
  # the mechanisms say where the real level actually lives, so a reader is not misled.
  doAssert t.securityLevel().mechanismOf(axConfidentiality).contains("epoch layer")
  echo "6. Transport declares no security level, naming where the real one lives OK"

# ── 7. combine: the ACTIVE room level is the strongest per axis, one envelope ───────
block:
  # a room running a NAMED driver + the epoch layer + a provenance-real seam (the signed
  # log, stood in here) has all three axes real — each from the seam that governs it.
  let logProv = securityLevel(axisLevel(rungNull, "-"), axisLevel(rungReal, "signed hash-linked log"),
                              axisLevel(rungNull, "-"))
  let seed2 = proc(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let cc = newEpochCrypto(newInMemoryKeystore(seed2(3), seed2(4)))
  let drv = newStubDriver(rounds = 1, threshold = 1, membership = mmNamed).describe().securityLevel()
  let active = combine(drv, cc.securityLevel(), logProv)
  doAssert active.rungOf(axAuthentication) == rungReal, "auth from the named driver"
  doAssert active.rungOf(axConfidentiality) == rungReal, "confidentiality from the epoch layer"
  doAssert active.rungOf(axProvenance) == rungReal, "provenance from the log"
  # an ANONYMOUS room keeps auth at the null — combine does not invent a level.
  let anonActive = combine(
    newStubDriver(rounds = 1, threshold = 1, membership = mmAnonymous).describe().securityLevel(),
    cc.securityLevel(), logProv)
  doAssert anonActive.rungOf(axAuthentication) == rungNull, "an anonymous room stays at the auth null"
  echo "7. combine: the active room level is the strongest per axis, one envelope OK"

# ── 8. toJson: the shape the security_levels surface returns / the UI renders ──────
block:
  let seed3 = proc(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let active = combine(
    newStubDriver(rounds = 1, threshold = 1, membership = mmNamed).describe().securityLevel(),
    securityLevel(axisLevel(rungNull, "-"), axisLevel(rungReal, "signed hash-linked log"), axisLevel(rungNull, "-")),
    newEpochCrypto(newInMemoryKeystore(seed3(5), seed3(6))).securityLevel())
  let j = active.toJson()
  doAssert j.hasKey("axes") and j["axes"].len == 3, "three axes, in order"
  let axisNames = block:
    var s: seq[string]
    for row in j["axes"]: s.add row["axis"].getStr()
    s
  doAssert axisNames == @["authentication", "provenance", "confidentiality"], "fixed honest order: " & $axisNames
  for row in j["axes"]:
    doAssert row.hasKey("rung") and row.hasKey("real") and row.hasKey("mechanism"), "each row is self-describing"
    doAssert (row["rung"].getStr() == "real") == row["real"].getBool(), "rung and the real bool agree"
    doAssert row["mechanism"].getStr().len > 0, "the mechanism is named, never blank"
  # this named room reaches all-real across the three axes.
  for row in j["axes"]: doAssert row["real"].getBool(), "a named room is real on every axis here"
  echo "8. toJson: the security_levels payload — three named axes, rung + real + mechanism OK"

echo "null_ladder_test: all OK"
