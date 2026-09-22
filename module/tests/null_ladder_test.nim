## The null ladder, typed onto the ChainAdapter seam (exo-1ec.5). The pattern is already in
## the code, unnamed: a transparent chain and a shielded chain are the null and the real
## CONFIDENTIALITY level at the SAME seam. This proves the level is a TYPED ATTRIBUTE the
## adapter declares (securityLevel), read by a consumer via the axis rung — never inferred by
## branching on the concrete adapter type. Links stint + libsodium (wallet types + keystore).

import std/strutils
import ../src/wallet/adapter
import ../src/wallet/mock_chain
import ../src/security/levels

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

echo "null_ladder_test: all OK"
