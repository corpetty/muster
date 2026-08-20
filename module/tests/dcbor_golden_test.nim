## dCBOR golden vectors (invariant 5 / spec derived-exo-d7c) — known-answer tests
## that pin the encoder to EXACT bytes, not just to shape properties.
##
## The `probe_cde_*` oracles check properties (shortest-length, re-derived
## ordering, re-encode stability). Those catch a class of bugs but not all: an
## endianness flip in `encodeHead`, a wrong major-type nibble, or a map ordering
## that happens to preserve length can all pass a property check while producing
## different bytes — and on a signing path *different bytes are a different
## signature*. These vectors are computed by hand from RFC 8949 §3 (and its CDE
## profile §4.2.3), so they are an EXTERNAL truth the encoder must reproduce.
##
## Run:  nim r -d:release tests/dcbor_golden_test.nim   (pure Nim, no deps)

import ../src/dcbor/dcbor
import ../src/hashing/hash_input

var failures = 0

proc g(name: string, v: CborValue, want: string) =
  let got = toHex(encode(v))
  if got == want:
    echo "ok    ", name, "  ", got
  else:
    echo "FAIL  ", name, "  want ", want, "  got ", got
    inc failures

# ── Unsigned integers — every additional-info width boundary (major 0) ──────────
g("uint 0",        cbUint(0),                     "00")
g("uint 23",       cbUint(23),                    "17")          # last 1-byte
g("uint 24",       cbUint(24),                    "1818")        # first 0x18
g("uint 255",      cbUint(255),                   "18ff")
g("uint 256",      cbUint(256),                   "190100")      # first 0x19
g("uint 1000000",  cbUint(1_000_000),             "1a000f4240")  # first 0x1a class
g("uint 2^32-1",   cbUint(4294967295'u64),        "1affffffff")
g("uint 2^32",     cbUint(4294967296'u64),        "1b0000000100000000")  # first 0x1b
g("uint max",      cbUint(high(uint64)),          "1bffffffffffffffff")

# ── Negative integers (major 1, argument = -1 - n), same width boundaries ───────
g("nint -1",       cbInt(-1),                     "20")
g("nint -24",      cbInt(-24),                    "37")
g("nint -25",      cbInt(-25),                    "3818")
g("nint -256",     cbInt(-256),                   "38ff")
g("nint -257",     cbInt(-257),                   "390100")
g("nint int64.low",cbInt(low(int64)),             "3b7fffffffffffffff")

# ── Byte / text strings (major 2 / 3) ───────────────────────────────────────────
g("bytes empty",   cbBytes(@[]),                  "40")
g("bytes 4",       cbBytes(@[1'u8, 2, 3, 4]),     "4401020304")
g("text empty",    cbText(""),                    "60")
g("text a",        cbText("a"),                   "6161")
g("text IETF",     cbText("IETF"),                "6449455446")
g("text muster",   cbText("muster"),              "666d7573746572")
g("text multibyte",cbText("\xC3\xBC"),            "62c3bc")      # U+00FC 'ü', 2 UTF-8 bytes

# ── Arrays (major 4) ────────────────────────────────────────────────────────────
g("array []",      cbArray(@[]),                              "80")
g("array [1,2,3]", cbArray(@[cbUint(1), cbUint(2), cbUint(3)]), "83010203")
g("array nested",  cbArray(@[cbUint(1), cbArray(@[cbUint(2), cbUint(3)])]), "8201820203")

# ── Simple values ───────────────────────────────────────────────────────────────
g("false",         cbBool(false),                 "f4")
g("true",          cbBool(true),                  "f5")
g("null",          cbNull(),                      "f6")

# ── Maps (major 5) — the discriminating cases for CDE key ordering ──────────────
g("map {}",        cbMap(@[]),                    "a0")
g("map {1:2}",     cbMap(@[(cbUint(1), cbUint(2))]), "a10102")
# Keys already in order: "a"(6161) < "b"(6162).
g("map {a:1,b:2}", cbMap(@[(cbText("a"), cbUint(1)), (cbText("b"), cbUint(2))]),
  "a2616101616202")

# The length-first DISCRIMINATOR. Encoded keys: 5->0x05 (len1), 1000000->0x1a…
# (len5), "a"->0x6161 (len2), "zz"->0x627a7a (len3). Bytewise-lex orders by first
# byte: 05 < 1a < 61 < 62. A length-first (RFC 8949 §4.2.1) encoder would instead
# order 05, 6161, 627a7a, 1a000f4240 — a DIFFERENT byte string. This vector fails
# loudly if the encoder ever regresses to length-first.
const cdeOrder = "a4050a1a000f4240146161181e627a7a1828"
g("map CDE order (in order)",
  cbMap(@[
    (cbUint(5), cbUint(10)),
    (cbUint(1_000_000), cbUint(20)),
    (cbText("a"), cbUint(30)),
    (cbText("zz"), cbUint(40)),
  ]), cdeOrder)
# Same map, scrambled insertion order — MUST encode to the identical bytes
# (order-independence, invariant 5 s1).
g("map CDE order (scrambled)",
  cbMap(@[
    (cbText("zz"), cbUint(40)),
    (cbUint(5), cbUint(10)),
    (cbText("a"), cbUint(30)),
    (cbUint(1_000_000), cbUint(20)),
  ]), cdeOrder)

# ── Signing-path framing — the domain-separated hash-input structure ────────────
# encodeHashInput("d", {"k":1}) = encode([ "d", {"k":1} ]) — pins the framing the
# whole signing path commits to (array of [domain, map]).
block:
  let got = toHex(encodeHashInput(hashInput("d", @[("k", cbUint(1))])))
  const want = "826164a1616b01"
  if got == want: echo "ok    hash-input framing  ", got
  else:
    echo "FAIL  hash-input framing  want ", want, "  got ", got
    inc failures

# ── Rejections (s4 / duplicate keys) — golden BEHAVIOUR, not bytes ──────────────
proc rejects(name: string, body: proc()) =
  var raised = false
  try: body()
  except CborError: raised = true
  if raised: echo "ok    reject ", name
  else:
    echo "FAIL  reject ", name, "  (encoded instead of raising)"
    inc failures

rejects("float",       proc() = discard encode(cbFloat(1.0)))
rejects("indefinite",  proc() = discard encode(cbIndefinite()))
rejects("dup map key", proc() =
  discard encode(cbMap(@[(cbText("a"), cbUint(1)), (cbText("a"), cbUint(2))])))

echo "---"
if failures == 0: echo "dcbor golden: ALL VECTORS OK"
doAssert failures == 0, $failures & " golden vector(s) mismatched"
