## Driver registry — select a driver by kind + config, so the host is not
## hardcoded to one driver. Adding a driver is: implement the contract (a new
## module), pass conformance, and add one `case` arm here. Nothing else in the
## module changes (invariant 6's promise, made turnkey).
##
## Config is plain JSON so a host can carry it in persistence/metadata rather than
## in code — `newDriver("safe", %*{"chainId": 31337, "safe": "0x…", "owners":
## ["0x…"], "threshold": 2})`.

import std/[json, strutils]
import ./driver
import ./safe
import ./threshold
import ./frost
import ./invoke
import ./eip191
import ./btc_multisig
import ./lez_multisig      # the LEZ multisig program (exo-6cbe)
import ./btc_frost         # FROST: the aggregate locus (Phase D)
import ../bitcoin/tx       # hexToBytes
import ../crypto/secp256k1    # Address
import ../crypto/curve25519   # Ed25519Pub (the roster)

type RegistryError* = object of CatchableError

proc hexToAddr(s: string): Address =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< min(20, h.len div 2):
    try: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard

proc parseRoster(config: JsonNode): seq[Ed25519Pub] =
  ## The Ed25519 roster the threshold / frost / invoke drivers share — each entry a
  ## 32-byte hex key. Malformed entries are skipped rather than raising, so a bad key
  ## drops out of the roster instead of breaking construction.
  if config.hasKey("roster") and config["roster"].kind == JArray:
    for pkHex in config["roster"]:
      var h = pkHex.getStr()
      if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
      var pk: Ed25519Pub
      for i in 0 ..< min(32, h.len div 2):
        try: pk[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
        except CatchableError: discard
      result.add pk

proc newDriver*(kind: string, config: JsonNode): Driver =
  ## The one place driver selection lives. Returns the generic `Driver` — the
  ## coordination fold and the core take it as-is; a driver-specific host path can
  ## downcast to the concrete type it asked for.
  case kind
  of "safe":
    var owners: seq[Address]
    if config.hasKey("owners") and config["owners"].kind == JArray:
      for o in config["owners"]: owners.add hexToAddr(o.getStr())
    newSafeDriver(chainId = uint64(config{"chainId"}.getInt(31337)),
                  safe = hexToAddr(config{"safe"}.getStr()),
                  owners = owners,
                  threshold = config{"threshold"}.getInt(2))
  of "btc-p2wsh", "btc-tapscript":
    # A Bitcoin multisig account (exo-a50.2.3): {network, k, keys: [33-byte hex]}.
    var keys: seq[seq[byte]]
    if config.hasKey("keys") and config["keys"].kind == JArray:
      for k in config["keys"]: keys.add hexToBytes(k.getStr())
    let family = (if kind == "btc-p2wsh": P2wshFamily else: TapscriptFamily)
    newBtcMultisigDriver(btcAccount(family, config{"network"}.getStr("regtest"), config{"k"}.getInt(2), keys))
  of "lez-multisig":
    # A LEZ multisig account (exo-6cbe): {chain, pda, program, createKey, members, threshold}.
    let cfg = $(%*{"program": config{"program"}.getStr(), "createKey": config{"createKey"}.getStr(),
                   "pda": config{"pda"}.getStr("lee-v0.2")})
    var members: seq[string]
    for m in config{"members"}.getElems(): members.add m.getStr()
    let (ok, acct, detail) = lezMultisigAccountFromParts(config{"chain"}.getStr("lez:testnet"), "", cfg,
                                                          members, config{"threshold"}.getInt(1))
    # the registry builds from the config alone: the address is the one it derives
    if not ok and not detail.startsWith("the address"): raise newException(RegistryError, detail)
    newLezMultisigDriver(acct)
  of "btc-frost":
    # A FROST account (Phase D): {network, recovery: the ceremony's recovery data, hex}.
    newBtcFrostDriver(frostAccount(config{"network"}.getStr("regtest"), hexToBytes(config{"recovery"}.getStr())))
  of "stub":
    newStubDriver(rounds = config{"rounds"}.getInt(1),
                  threshold = config{"threshold"}.getInt(2),
                  verifyResult = config{"verifyResult"}.getBool(true))
  of "threshold":
    newThresholdDriver(parseRoster(config), config{"k"}.getInt(2))
  of "unanimous":
    # The k = n threshold over the same roster (driver-as-proposal: admitted into a room
    # only by an approved add-driver, see kinds.nim).
    let roster = parseRoster(config)
    newThresholdDriver(roster, max(1, roster.len))
  of "frost":
    # 2-round Schnorr-threshold structure over an Ed25519 roster. Same roster/k
    # config shape as "threshold"; the difference is describe().rounds = 2, so the
    # core runs two collection passes. See frost.nim for the scaffold boundary.
    newFrostDriver(parseRoster(config), config{"k"}.getInt(2))
  of "invoke":
    # The generic module-action driver (P-D1): coordinate "the room agrees to call
    # module.method(args)" as a k-of-n Ed25519 endorsement over the room roster. The
    # action (module/method/args) lives in the EFFECT, not the driver, so this is a
    # generic roster driver; the EXECUTION path (P-D2) reads the module/method from
    # the effect and gates on the allowlist + the target's capability policy.
    newInvokeDriver(parseRoster(config), config{"k"}.getInt(1))
  of "eip191":
    # A Tier-1 (module-native) driver beyond Safe (P-D6): the room's signers each
    # EIP-191 personal-sign the effect; a contribution counts only if its secp256k1
    # signature recovers to a configured signer. Settles nothing on-chain — a signed
    # group attestation. `signers` are 20-byte hex addresses, like a Safe's owners.
    var signers: seq[Address]
    if config.hasKey("signers") and config["signers"].kind == JArray:
      for s in config["signers"]: signers.add hexToAddr(s.getStr())
    newPersonalSignDriver(signers = signers, threshold = config{"threshold"}.getInt(2))
  else:
    # Never a fallback to another family (kinds.nim): a kind this client does not have
    # is refused here, and resolveKind turns it into an UnsupportedDriver for the fold.
    raise newException(RegistryError, "unknown driver kind: " & kind)
