## s1 — the holdings catalogue never crosses an outward boundary
## (contracts/specs/derived-exo-45e, oracle s1; metamorphic/conservation).
##
## The conservation law: catalogue-origin PRIVATE bytes (a Material's opaque handle)
## in, ZERO of them out. We build a catalogue whose every handle is a unique sentinel,
## then take the only projection that may leave the instance — disclosable() — and
## measure how many sentinels survive into what would be serialized onto the wire / log.
## A Material has no whole-object serializer by construction (material.nim), so the one
## boundary is disclosable(); if a future change let a handle through it, the leaked
## count rises above zero and this refuses. Emits a JSON measurement for the metamorphic
## executor and self-asserts now.
##
## Build: nim r -d:release --threads:on $SECP $STINT --passL:libsodium tests/probes/probe_catalogue_no_leak.nim

import std/[strutils, json]
import ../../src/wallet/material
import ../../src/wallet/mock_chain
import ../../src/crypto/keystore

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

let ks = newInMemoryKeystore(seed(3), seed(4))

# A catalogue with UNIQUE sentinel handles across every source class, so any handle
# that leaks is attributable and countable.
const S = "SENTINEL-HANDLE-"
var staticMats: seq[Material]
for i in 0 ..< 8:
  staticMats.add Material(class: mcAsset, chain: "evm:1", form: "erc20",
    handle: S & $i, public: "TOKEN" & $i, grade: mgAttested, source: msHost)
let sources = @[MaterialSource(newKeystoreSource(ks)),
                MaterialSource(newAdapterSource(newMockChain(), ks)),
                MaterialSource(newStaticSource(staticMats))]
let cat = catalogue(sources)

# Every handle is a private, catalogue-origin secret. Re-tag them all with sentinels so
# the count is exact (the keystore/adapter handles are not S-prefixed; tag by index).
var handles: seq[string]
var tagged: seq[Material]
for i, m in cat:
  var mm = m
  mm.handle = S & "idx" & $i        # a unique sentinel per material
  handles.add mm.handle
  tagged.add mm

# The boundary: disclosable() is the ONLY thing that leaves. Serialize what would go on
# the wire and count sentinel-handle occurrences. Conservation ⇒ zero.
var outward = ""
var discloseCount = 0
for m in tagged:
  let d = m.disclosable()
  outward.add $d                    # the projection that crosses the boundary (no handle)
  outward.add (%*{"class": $d.class, "chain": d.chain, "form": d.form, "public": d.public}).pretty()
  inc discloseCount

var leaked = 0
for h in handles:
  if outward.contains(h): inc leaked

let measurement = %*{
  "catalogueHandles": handles.len,
  "disclosed": discloseCount,
  "outwardBytes": outward.len,
  "leaked": leaked}
echo measurement

doAssert cat.len == 11, "keystore(1) + mock chain(2) + static(8) = 11 holdings"
doAssert leaked == 0, "a catalogue handle crossed the disclosure boundary: " & $measurement
echo "probe_catalogue_no_leak: OK (0 of ", handles.len, " handles crossed the boundary)"
