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
import ../crypto/secp256k1   # Address

type RegistryError* = object of CatchableError

proc hexToAddr(s: string): Address =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< min(20, h.len div 2):
    try: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard

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
  else:
    raise newException(RegistryError, "unknown driver kind: " & kind)
