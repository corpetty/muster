## Material — a participant's holdings, as a LOCAL-ONLY catalogue (exo-45e K2,
## docs/design/material-and-disclosure.md §3.1).
##
## A `Material` is one holding a participant could bind to an action's requirement:
## an authority key, a receiving address, an asset balance, a piece of infra, a host
## capability — classified by the SAME closed vocabulary the manifest's requirements
## use (`MaterialClass`, drivers/manifest.nim), so an offer can cross the two (K4).
##
## The catalogue is the boundary this module exists to draw. It is a **local view,
## never a log entry** (rule s1, contracts/specs/derived-exo-45e): a `Material` carries
## an opaque local `handle` and its `source`, and this module deliberately gives it NO
## whole-object serializer — no `toJson`, no dCBOR. The ONLY projection that may leave
## the instance is `disclosable()`, which carries the public face and class and drops
## the handle and source. Choosing to disclose a material yields a `Disclosable`; the
## handle never crosses the boundary, so a holding a participant did not choose cannot
## reach the log, transport, a proof, the flow view, or a plugin (FS-4, invariant 3).

import ../drivers/manifest   # MaterialClass (the shared vocabulary)
import ../crypto/secp256k1   # Address
import ../crypto/keystore    # Keystore (address of the authorization identity)
import ./types               # Account, AssetId
import ./adapter             # ChainAdapter (accounts derive per chain)

export manifest.MaterialClass

type
  MaterialGrade* = enum
    ## How we know the participant holds it — the F-10 axis extended to holdings.
    mgVerifiedLocally = "verified-locally"  ## the client re-derived / holds the key
    mgAttested        = "attested"          ## trusting a named supplier (an adapter read)
    mgDeclared        = "declared"          ## configured, not yet verified against a source

  MaterialSourceKind* = enum
    msKeystore   = "keystore"     ## the module's own keys
    msAdapter    = "adapter"      ## a registered chain adapter's accounts
    msConfigured = "configured"   ## an account you are configured against (a Safe)
    msHost       = "host"         ## a host-provided account (ADR-013 shell — stub today)

  Material* = object
    class*: MaterialClass
    chain*: string          ## "evm:31337", "lez:testnet", "" (room-native)
    form*: string           ## "secp256k1" | "public" | "shielded" | … (source-described)
    handle*: string         ## opaque LOCAL ref — NEVER disclosed (this is the boundary)
    public*: string         ## the disclosable face: an address, a key node, a pubkey
    grade*: MaterialGrade
    source*: MaterialSourceKind

  Disclosable* = object
    ## The ONLY projection of a Material that may leave the instance: the public face
    ## and its class. No handle, no source. See the module doc: nothing else is exported.
    class*: MaterialClass
    chain*: string
    form*: string
    public*: string

proc disclosable*(m: Material): Disclosable =
  ## The single boundary crossing. A Material has no other serializer, by design.
  Disclosable(class: m.class, chain: m.chain, form: m.form, public: m.public)

proc hexAddr(a: Address): string =
  const d = "0123456789abcdef"
  result = "0x"
  for b in a: (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])

# ── The source seam ──────────────────────────────────────────────────────────────
# A source enumerates the material it knows about. Sources never sign and never touch
# the log; catalogue() folds them into the local view.
type
  MaterialSource* = ref object of RootObj

method materials*(s: MaterialSource): seq[Material] {.base, gcsafe.} = @[]

type
  KeystoreSource* = ref object of MaterialSource
    ## The module's own authorization identity as authority material. We hold the key,
    ## so the grade is verified-locally; the public face is the Ethereum address.
    ks: Keystore

  AdapterSource* = ref object of MaterialSource
    ## A registered chain adapter's accounts as ADDRESS material — each public id or
    ## shielded key-set the identity can receive at. Attested (read via the adapter);
    ## no balance is read here (that is a live read the offers surface grades, K4).
    adapter: ChainAdapter
    ks: Keystore

  ConfiguredSafeSource* = ref object of MaterialSource
    ## A Safe the module is configured against, as authority material — DECLARED, not
    ## verified: whether this instance's key is really an owner is a chain read (K3).
    safe: Address
    chain: string

  StaticSource* = ref object of MaterialSource
    ## A fixed list — host-provided material (ADR-013 stub) and tests.
    items: seq[Material]

proc newKeystoreSource*(ks: Keystore): KeystoreSource = KeystoreSource(ks: ks)
proc newAdapterSource*(adapter: ChainAdapter, ks: Keystore): AdapterSource =
  AdapterSource(adapter: adapter, ks: ks)
proc newConfiguredSafeSource*(safe: Address, chain: string): ConfiguredSafeSource =
  ConfiguredSafeSource(safe: safe, chain: chain)
proc newStaticSource*(items: seq[Material]): StaticSource = StaticSource(items: items)

method materials*(s: KeystoreSource): seq[Material] =
  ## Every authorization key the keystore holds becomes verified-local authority material
  ## (K2b: the keystore is a set, not one key). The handle carries the KeyRef so a keyed
  ## contribute / binding can select this exact key; the public face is the address.
  for r in s.ks.keyRefs():
    result.add Material(class: mcAuthority, chain: "", form: "secp256k1",
                        handle: "keystore:secp:" & r, public: r,
                        grade: mgVerifiedLocally, source: msKeystore)

method materials*(s: AdapterSource): seq[Material] =
  for a in s.adapter.accounts(s.ks):
    result.add Material(class: mcAddress, chain: a.chain, form: $a.form,
                        handle: "adapter:" & a.chain & ":" & a.id, public: a.id,
                        grade: mgAttested, source: msAdapter)

method materials*(s: ConfiguredSafeSource): seq[Material] =
  @[Material(class: mcAuthority, chain: s.chain, form: "safe-owner",
             handle: "safe:" & hexAddr(s.safe), public: hexAddr(s.safe),
             grade: mgDeclared, source: msConfigured)]

method materials*(s: StaticSource): seq[Material] = s.items

proc catalogue*(sources: seq[MaterialSource]): seq[Material] =
  ## The local view: every source's material, in source order. A source that cannot
  ## enumerate raises (never a silent empty that hides a holding) — the caller decides
  ## whether one failed source should fail the whole catalogue.
  for s in sources:
    for m in s.materials(): result.add m

proc forClass*(cat: seq[Material], class: MaterialClass): seq[Material] =
  for m in cat:
    if m.class == class: result.add m
