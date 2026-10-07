## The typed (EIP-712) attestation and identity binding (ADR-017, exo-149.6 K6b).
##   1. the documents hash as an independent EIP-712 implementation hashes them: Foundry's
##      `cast wallet sign --data` over the same documents with a fixed key gives these exact
##      signatures (RFC 6979 on both sides), frozen here as vectors;
##   2. a typed attestation verifies against what the verifier recomputed, and is refused
##      when any rendered field, the payload or the domain differs (the probes do this at
##      random; here, one named case each);
##   3. a typed binding recovers its signer, and expires as a hash-input one does;
##   4. the forms never cross: a typed signature is not a hash-input one, nor the reverse.
##
## `--emit <dir>` writes the two vector documents as JSON (to re-derive the vectors with
## cast: docs/labbook/eip712-typed-attestation.md) and exits.

import std/[json, os, strutils]
import ../src/coordination/attest_typed
import ../src/coordination/attest        # verifyAttestation, attestationDigest (hash-input)
import ../src/intents/signing_payload
import ../src/crypto/[secp256k1, curve25519, binding]
import ../src/wallet/keystore_legs

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)])

# the vectors' inputs
let ctx = SigningContext(environment: "eip155:11155111",
                         account: "0x21b6e7328d4b2cbaec21d2504dc41fdfffcb86ef",
                         slot: "7", expiry: 1791400000'u64)
let mat = bytesOfHex("0x3fdf05b9ee41fa3acdd6b4d822d57f3aa36dcf2292d6daec55b54d993746957d")
var p: seq[byte]
for c in "muster-k6b-vector": p.add byte(c)
var enc: EncIdentity
for i in 0 ..< 32: (enc.ed[i] = byte(i); enc.x[i] = byte(255 - i))
let lctx = LinkContext(account: "room:r6", slot: "1", expiry: 1791400000'u64)

if paramCount() >= 2 and paramStr(1) == "--emit":
  writeFile(paramStr(2) / "attestation.json", $attestationTypedData(ctx, mat, 3, p))
  writeFile(paramStr(2) / "binding.json", $bindingTypedData(enc, lctx))
  echo "attest_typed_test: wrote the vector documents to ", paramStr(2)
  quit 0

# anvil's key 0, a public test key
var sk: array[32, byte]
let skb = bytesOfHex("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
for i in 0 ..< 32: sk[i] = skb[i]
let me = hexOf(addressOf(sk))
doAssert me == "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

# ── 1. independent vectors ────────────────────────────────────────────────────────
const
  CastAttestationSig = "0x8e2742b10b72aaf7ab561e301287a494e57a9ced6c42cc3d61982babc54cc1ea18cea5265d0acf2a790a857731cce7b864081f616cc641005ed9a22a157cee7e1c"
  CastBindingSig = "0x2376867d9638b38a5a792f1e3b8e9cee40fd21b40bb96c3b1a1ed5c3ae22c7dd54d2d513873736e60a71b0e92062b0618a140960bae81449f7c4568f2259842a1b"
block:
  let a = signRecoverable(attestationTypedHash(ctx, mat, 3, p), sk)
  let b = signRecoverable(bindingTypedHash(enc, lctx), sk)
  doAssert hexOf(a) == CastAttestationSig, "attestation: ours " & hexOf(a)
  doAssert hexOf(b) == CastBindingSig, "binding: ours " & hexOf(b)
  echo "1. both documents hash as Foundry's EIP-712 does (signatures equal byte for byte) OK"

# ── 2. a typed attestation verifies against what was recomputed, nothing else ─────
block:
  let sig = hexOf(signRecoverable(attestationTypedHash(ctx, mat, 3, p), sk))
  doAssert verifyTypedAttestation(me, ctx, mat, 3, p, sig)
  var c2 = ctx
  c2.environment = "eip155:1"
  doAssert not verifyTypedAttestation(me, c2, mat, 3, p, sig), "another chain (field and domain)"
  c2 = ctx; c2.account = "0x" & repeat("0", 40)
  doAssert not verifyTypedAttestation(me, c2, mat, 3, p, sig), "another account"
  c2 = ctx; c2.slot = "8"
  doAssert not verifyTypedAttestation(me, c2, mat, 3, p, sig), "another slot"
  c2 = ctx; c2.expiry = ctx.expiry + 1
  doAssert not verifyTypedAttestation(me, c2, mat, 3, p, sig), "another expiry"
  var m2 = mat
  m2[0] = m2[0] xor 1
  doAssert not verifyTypedAttestation(me, ctx, m2, 3, p, sig), "another materialization"
  doAssert not verifyTypedAttestation(me, ctx, mat, 2, p, sig), "another count of inputs"
  doAssert not verifyTypedAttestation(me, ctx, mat, 3, p & @[0'u8], sig), "another P"
  doAssert not verifyTypedAttestation("0x" & repeat("1", 40), ctx, mat, 3, p, sig), "another signer"
  doAssert not verifyTypedAttestation(me, ctx, mat, 3, newSeq[byte](), sig), "an empty P never verifies"
  var ph = ctx
  ph.slot = "0"
  doAssert not verifyTypedAttestation(me, ph, mat, 3, p,
                                      hexOf(signRecoverable(attestationTypedHash(ph, mat, 3, p), sk))),
    "a placeholder context never verifies"
  # the domain on its own: the same message under another domain is another hash
  var td = attestationTypedData(ctx, mat, 3, p)
  td["domain"]["chainId"] = %"1"
  doAssert typedDataHash(td) != attestationTypedHash(ctx, mat, 3, p)
  # an environment that is not eip155 carries no chainId
  let roomCtx = SigningContext(environment: "room:r6", account: "room:r6", slot: "1", expiry: 9)
  doAssert not attestationTypedData(roomCtx, mat, 1, p)["domain"].hasKey("chainId")
  doAssert eip155ChainId("eip155:0").ok == false and eip155ChainId("eip155:x").ok == false
  echo "2. a typed attestation verifies only against the context, root, inputs and P recomputed OK"

# ── 3. a typed binding ────────────────────────────────────────────────────────────
block:
  let st = LinkStatement(enc: enc, ctx: lctx, sig: signRecoverable(bindingTypedHash(enc, lctx), sk))
  doAssert hexOf(typedBindingSigner(st, 1000)) == me
  doAssert hexOf(bindingSignerAs(afEip712, st, 1000)) == me
  var st2 = st
  st2.ctx.account = "room:other"
  doAssert hexOf(typedBindingSigner(st2, 1000)) != me, "another room"
  st2 = st; st2.enc.x[0] = st2.enc.x[0] xor 1
  doAssert hexOf(typedBindingSigner(st2, 1000)) != me, "another encryption key"
  doAssert not bindingTypedData(enc, lctx)["domain"].hasKey("chainId")
  var expired = false
  try: discard typedBindingSigner(st, lctx.expiry + 1)
  except BindingError: expired = true
  doAssert expired and hexOf(typedBindingSigner(st, lctx.expiry)) == me,
    "expires after its expiry, as a hash-input binding does"
  echo "3. a typed binding recovers its signer, over its own fields only OK"

# ── 4. the forms never cross ──────────────────────────────────────────────────────
block:
  let typed = hexOf(signRecoverable(attestationTypedHash(ctx, mat, 3, p), sk))
  let raw = hexOf(signRecoverable(attestationDigest(p), sk))
  doAssert verifyAttestation(me, p, raw) and verifyTypedAttestation(me, ctx, mat, 3, p, typed)
  doAssert not verifyAttestation(me, p, typed), "a typed signature is not a hash-input one"
  doAssert not verifyTypedAttestation(me, ctx, mat, 3, p, raw), "a hash-input signature is not a typed one"
  let tst = LinkStatement(enc: enc, ctx: lctx, sig: signRecoverable(bindingTypedHash(enc, lctx), sk))
  let hst = LinkStatement(enc: enc, ctx: lctx, sig: signRecoverable(linkDigest(enc, lctx), sk))
  doAssert hexOf(bindingSignerAs(afHashInput, hst, 1000)) == me
  doAssert hexOf(bindingSignerAs(afHashInput, tst, 1000)) != me
  doAssert hexOf(bindingSignerAs(afEip712, hst, 1000)) != me
  echo "4. a signature in one form never verifies in the other OK"

echo "attest_typed_test: all passed"
