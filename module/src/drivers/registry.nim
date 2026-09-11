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

proc parseFinality(s: string): FinalityType =
  ## Map an invoke driver's declared completion signal to the core's FinalityType.
  case s
  of "immediate": finImmediate
  of "receipt", "probabilistic": finProbabilistic
  else: finExternal        # "event" and anything else — completion via a named event

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
  of "stub":
    newStubDriver(rounds = config{"rounds"}.getInt(1),
                  threshold = config{"threshold"}.getInt(2),
                  verifyResult = config{"verifyResult"}.getBool(true))
  of "threshold":
    newThresholdDriver(parseRoster(config), config{"k"}.getInt(2))
  of "frost":
    # 2-round Schnorr-threshold structure over an Ed25519 roster. Same roster/k
    # config shape as "threshold"; the difference is describe().rounds = 2, so the
    # core runs two collection passes. See frost.nim for the scaffold boundary.
    newFrostDriver(parseRoster(config), config{"k"}.getInt(2))
  of "invoke":
    # The generic module-action driver (P-D1): coordinate "the room agrees to call
    # module.method(args)" as a k-of-n Ed25519 endorsement over the room roster. The
    # module/method/finality are config the EXECUTION path (P-D2) reads; the domain
    # is per-(module, method) so the same args to different methods sign differently.
    newInvokeDriver(targetModule = config{"module"}.getStr(),
                    targetMethod = config{"method"}.getStr(),
                    roster = parseRoster(config),
                    k = config{"k"}.getInt(1),
                    finality = parseFinality(config{"finality"}.getStr("immediate")),
                    finalityEvent = config{"finalityEvent"}.getStr(""))
  else:
    raise newException(RegistryError, "unknown driver kind: " & kind)
