## The pure LEZ wire encodings (P-L3): amount → 16-byte LE hex and the key-node JSON.
## No infra — `nim r` alone. (The pinata PoW went with the faucet: LEZ v0.3 has none,
## exo-eb6.4.)

import std/[strutils, json]
import ../src/wallet/lez_encoding

# ── amountLe16Hex: 16-byte little-endian, the zone's amount encoding ───────────
block:
  doAssert amountLe16Hex("0") == "00000000000000000000000000000000"
  doAssert amountLe16Hex("1") == "01000000000000000000000000000000", "LE: 1 is the first byte"
  doAssert amountLe16Hex("256") == "00010000000000000000000000000000", "256 = byte[1]"
  doAssert amountLe16Hex("255") == "ff000000000000000000000000000000"
  # 2^64 sits at byte 8
  doAssert amountLe16Hex("18446744073709551616") == "00000000000000000100000000000000"
  doAssertRaises(ValueError): discard amountLe16Hex("nope")
  echo "1. amountLe16Hex — 16-byte little-endian OK"

# ── key node JSON — the to_keys_json shape lez_core v0.3.0 uses ────────────────
block:
  let j = keyNodeJson("aa", "bb")
  doAssert parseJson(j)["nullifier_public_key"].getStr() == "aa"
  doAssert parseJson(j)["viewing_public_key"].getStr() == "bb"
  let kn = parseKeyNode("""{"nullifier_public_key":"cc","viewing_public_key":"dd"}""")
  doAssert kn.npk == "cc" and kn.vpk == "dd"
  doAssert parseKeyNode("garbage").npk == "", "a malformed key node reads empty, not a crash"
  echo "2. key node JSON round-trips OK"

# ── the wallet's sequencer: this instance's LEZ zone, not lez_core's default ───────
block:
  # lez_core writes its own default config, pointed at the public testnet; an instance on
  # another zone (a local v0.3 chain, exo-eb6.4) points it at that zone, keeping the rest
  const dflt = """{"sequencers":[{"sequencer_addr":"https://testnet.lez.logos.co/"}],"seq_poll_timeout":"30s"}"""
  let (changed, j) = pointWalletConfig(dflt, "http://127.0.0.1:3040")
  doAssert changed
  let c = parseJson(j)
  doAssert c["sequencers"].len == 1 and c["sequencers"][0]["sequencer_addr"].getStr() == "http://127.0.0.1:3040", j
  doAssert c["seq_poll_timeout"].getStr() == "30s", "the rest of the config is kept"
  # the same zone, a trailing slash apart, is no change: nothing rewritten, nothing reopened
  doAssert not pointWalletConfig(dflt, "https://testnet.lez.logos.co").changed
  doAssert not pointWalletConfig(dflt, "").changed, "no zone named: lez_core's own default stands"
  doAssert not pointWalletConfig("not json", "http://x").changed, "an unreadable config is left alone"
  echo "3. the wallet config points at this instance's zone, and only when it differs OK"

echo "wallet_lez_encoding_test: all OK"
