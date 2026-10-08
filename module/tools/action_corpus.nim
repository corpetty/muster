## The action corpus's machine half (docs/design/action-atlas.md §3a/§4, epic exo-661 A2):
## for every built (driver kind, effect variant) it builds the driver from the registry,
## a real representative effect with the same helpers the hosted module uses, and emits
## what the running code says about that pair — describe(), environment(), profile(),
## manifest(effect) and signRefusal(effect) — as contracts/actions/generated.json.
##
## Nothing here is hand-typed that the code can say: the atlas's agreement, profile,
## requirements, touches and disclosure for a built action are read off the drivers, so
## a change to a driver cannot leave the atlas behind (tests/action_corpus_test.nim
## compares this to the committed file).
##
## Deterministic by construction — fixed keys and seeds, no clock, no network, no
## randomness: the same bytes every run. Chain reads the hosted composers make (a Bitcoin
## node's UTXOs, the LEZ token program id, an account nonce) are fixtures here, named
## below. The FROST accounts come from a real 2-of-3 ChillDKG run with fixed host keys and
## fixed randomness (tests/probes/live_room's frostTestRecoveryHex draws fresh randomness
## per process, so its address would change every run).
##
##   nim r <the run-suite flags> module/tools/action_corpus.nim            # print
##   TEST_ARGS=--write module/tests/run-suite.sh action_corpus             # rewrite the file

import std/[json, os, strutils, sequtils, algorithm]
import stint
import ../src/dcbor/dcbor
import ../src/hashing/sha256
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/drivers/profile
import ../src/drivers/kinds
import ../src/drivers/registry
import ../src/drivers/safe
import ../src/drivers/btc_multisig
import ../src/drivers/btc_frost
import ../src/drivers/lez_multisig
import ../src/drivers/lez_frost
import ../src/drivers/split                  # evenShares / splitEffectJson (exo-a90.3)
import ../src/coordination/readiness        # toJson(ActionManifest), toJson(DriverDescriptor)
import ../src/coordination/intent_events    # effectFromJson — the hosted propose path's parser
import ../src/lez/multisig                  # vaultPda / vaultSeed / LezAction
import ../src/frost/chilldkg
import ../src/bitcoin/[tx, bech32, script]
import ../src/crypto/secp256k1             # Address
import ../src/wallet/evm_adapter            # erc20TransferData
import ../src/wallet/lez_encoding           # amountLe16Hex

const GeneratedPath* = currentSourcePath().parentDir() / ".." / ".." / "contracts" / "actions" / "generated.json"
const RegenerateCommand* = "TEST_ARGS=--write module/tests/run-suite.sh action_corpus"

# ── the instances: profile_test's kinds fixtures ──────────────────────────────
proc edHex(n: byte): string = "0x" & repeat(toHex(n, 2).toLowerAscii(), 32)
let roster = %*[edHex(1), edHex(2), edHex(3)]
let owners = %*["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"]
const SafeAddr = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
const BtcKeys = ["0307b8ae49ac90a048e9b53357a2354b3334e9c8bee813ecb98e99a7e07e8c3ba3",
                 "03b28f0c28bfab54554ae8c658ac5c3e0ce6e79ad336331f78c428dd43eea8449b",
                 "034b8113d703413d57761b8b9781957b8c0ac1dfe69f492580ca4195f50376ba4a"]
let lezMultisigCfg = %*{"chain": "lez:local", "pda": "lee-v0.2", "program": repeat("aa", 32),
                        "createKey": repeat("0b", 32), "threshold": 2,
                        "members": [repeat("01", 32), repeat("02", 32), repeat("03", 32)]}

# ── the fixtures for what the hosted composers read from a chain ──────────────
const Payee = "0x1111111111111111111111111111111111111111"        ## a Safe transfer's payee
const BtcRegtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"   ## the btc-split fixture's chain (exo-d17)
const SplitCreditor = repeat("c1", 64)   ## a split's room identities (64 bytes, hex): who fronted…
const SplitDebtors = [repeat("d1", 64), repeat("d2", 64)]   ## …and who owes
const Erc20Token = "0x2222222222222222222222222222222222222222"   ## a contract-call target
const MultiSendCallOnly = "0x40A2aCCbd92BCA938b02010E17A5b8929b49130D"  ## Safe's MultiSendCallOnly (safe_fidelity_test's)
## the LEZ token program's id: the v0.2.4 build's image id, as the public testnet serves it
## (tests/vectors/lez-multisig-testnet/chain.json → token_image_id)
const LezTokenProgram = "ccc4713e2b5ecdff37b0c67c295369effc04b7e8994eb11c3f410bb226b82e9b"
const LezRecipient = "0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c"
const LezTokenDefinition = "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d"
const LezModeBFrom = "0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e"
const XmrStagenet = "monero:76ee3cc98646292206cd3e86f74d88b4"   ## the monero-split fixture's chain (exo-dcc.5)
## a stagenet subaddress (monero-project tests/functional_tests, as monero_address_test holds it)
const XmrPayTo = "73LhUiix4DVFMcKhsPRG51QmCsv8dYYbL6GcQoLwEEFvPvkVvc7BhebfA4pnEFF9Lq66hwvLqBvpHjTcqvpJMHmmNjPPBqa"
## a Bitcoin payee (bcrt1q… of the BIP-173 example program), as btc_settlement_test pays
let BtcPayee = encodeSegwitAddress("bcrt", 0, hexToBytes("751e76e8199196d454941c45d1b3a323f1433bd6"))

proc tagged(tag: string): seq[byte] = @(sha256(cast[seq[byte]]("muster/action-corpus/" & tag)))

proc frostFixtureRecoveryHex(): string =
  ## A real 2-of-3 ChillDKG run, every host key and every random input fixed: the
  ## recovery data (and so the account) is the same bytes every run.
  let secs = @[tagged("frost-host/1"), tagged("frost-host/2"), tagged("frost-host/3")]
  let params = SessionParams(hostpubkeys: secs.mapIt(hostpubkeyGen(it)), t: 2)
  var st1: seq[ParticipantState1]
  var pm1: seq[seq[byte]]
  for i, s in secs:
    let (st, m) = participantStep1(s, params, tagged("frost-random/" & $(i + 1)))
    st1.add st
    pm1.add m
  let (cst, cmsg1) = coordinatorStep1(pm1, params)
  var pm2: seq[seq[byte]]
  for i, s in secs:
    let (_, m) = participantStep2(s, st1[i], cmsg1, tagged("frost-aux/" & $(i + 1)))
    pm2.add m
  let (_, _, rec) = coordinatorFinalize(cst, pm2)
  toHex(rec)

let frostRecovery = frostFixtureRecoveryHex()

proc configOf(kind: string): JsonNode =
  case kind
  of "safe": %*{"chainId": 31337, "safe": SafeAddr, "owners": owners, "threshold": 2}
  of "threshold", "frost", "invoke": %*{"roster": roster, "k": 2}
  of "unanimous": %*{"roster": roster}
  of "eip191": %*{"signers": owners, "threshold": 1}
  of "btc-p2wsh", "btc-tapscript": %*{"network": "regtest", "k": 2, "keys": BtcKeys}
  of "lez-multisig": lezMultisigCfg
  of "btc-frost": %*{"network": "regtest", "recovery": frostRecovery}
  of "lez-frost": %*{"chain": "lez:local", "recovery": frostRecovery}
  of "evm-split": %*{"chain": "eip155:31337", "members": [SplitCreditor, SplitDebtors[0], SplitDebtors[1]]}
  of "lez-split": %*{"chain": "lez:testnet", "members": [SplitCreditor, SplitDebtors[0], SplitDebtors[1]]}
  of "btc-split": %*{"chain": BtcRegtest, "members": [SplitCreditor, SplitDebtors[0], SplitDebtors[1]]}
  of "monero-split": %*{"chain": XmrStagenet, "members": [SplitCreditor, SplitDebtors[0], SplitDebtors[1]]}
  else: raise newException(ValueError, "no corpus fixture for kind " & kind)

# ── the effects, built as the hosted composers build them ─────────────────────
proc hx(b: seq[byte]): string = toHex(b)

proc tokenTransferWords(amount: uint64): seq[uint32] =
  ## token Transfer (variant 0), the amount a u128 as four u32 words — exactly
  ## coordinate_propose_lez_transfer's (and lezFrostTransfer's) instruction.
  @[0'u32, uint32(amount and 0xffff_ffff'u64), uint32(amount shr 32), 0'u32, 0'u32]

proc erc20Transfer(): string =
  ## transfer(Payee, 250000000) — the wallet's ERC-20 calldata encoder
  var to: Address
  let h = hexToBytes(Payee)
  for i in 0 ..< 20: to[i] = h[i]
  erc20TransferData(to, "250000000")

proc multiSendOf(target, calldata: string): string =
  ## multiSend(bytes transactions) with one packed CALL: operation (1 byte) ‖ to (20) ‖
  ## value (32) ‖ data length (32) ‖ data — the MultiSend contract's packed encoding,
  ## ABI-wrapped as one dynamic bytes argument.
  proc word(n: int): seq[byte] =
    result = newSeq[byte](32)
    for i in 0 ..< 8: result[31 - i] = byte((n shr (8 * i)) and 0xff)
  let data = hexToBytes(calldata)
  var packed = @[0'u8] & hexToBytes(target) & newSeq[byte](32) & word(data.len) & data
  var abi = word(32) & word(packed.len) & packed
  while abi.len mod 32 != 0: abi.add 0'u8
  "0x8d80ff0a" & toHex(abi)

proc effectJsonFor(kind, variant: string, d: Driver): string =
  case kind & "/" & variant
  of "safe/transfer":
    # the Safe payment the room composes: to / value / nonce (the Safe's live nonce)
    $(%*{"effect": "transfer", "to": Payee, "value": 1_000_000_000_000_000, "nonce": 0})
  of "safe/contract-call":
    # a CALL with calldata: an ERC-20 transfer(address,uint256), the wallet's own encoder
    $(%*{"effect": "safe-tx", "to": Erc20Token, "value": 0, "nonce": 0,
         "data": erc20Transfer(), "operation": 0})
  of "safe/delegatecall":
    # a DELEGATECALL (operation 1) into MultiSendCallOnly.multiSend(bytes), batching that
    # same ERC-20 transfer — refused unless this client allowlists the target
    # (MUSTER_SAFE_DELEGATECALL_ALLOW)
    $(%*{"effect": "safe-tx", "to": MultiSendCallOnly, "value": 0, "nonce": 0,
         "data": multiSendOf(Erc20Token, erc20Transfer()), "operation": 1})
  of "threshold/statement", "unanimous/statement", "frost/statement", "eip191/statement":
    $(%*{"effect": "statement", "text": "The room approves the Q4 budget."})
  of "threshold/add-driver":
    # governance: admit the unanimous kind into the room (governance_test)
    $(%*{"effect": "add-driver", "kind": "unanimous"})
  of "invoke/module-call":
    # the composer's module action: module.method(args), args a JSON array
    $(%*{"effect": "invoke", "module": "delivery_module", "method": "send", "args": ["/room", "hello"]})
  of "invoke/lez-transfer":
    # LEZ Mode B (exo-45e): a coordinated private transfer whose recipient the room asks
    # for — the composer names the counterparty arg and the chain (Room.qml proposeAction)
    $(%*{"effect": "invoke", "module": "lez_core", "method": "transfer_private",
         "args": [LezModeBFrom, "", amountLe16Hex("200")], "counterparty": "to", "chain": "lez:testnet"})
  of "btc-p2wsh/spend", "btc-tapscript/spend":
    let acct = BtcMultisigDriver(d).account
    let coins = @[BtcUtxo(txid: repeat("01", 32), vout: 1, value: 30_000, scriptPubKey: toHex(acct.scriptPubKey)),
                  BtcUtxo(txid: repeat("02", 32), vout: 2, value: 250_000, scriptPubKey: toHex(acct.scriptPubKey)),
                  BtcUtxo(txid: repeat("03", 32), vout: 3, value: 120_000, scriptPubKey: toHex(acct.scriptPubKey))]
    buildBtcSpend(acct, coins, BtcPayee, 300_000'u64, feeRate = 3)
  of "btc-frost/spend":
    let acct = BtcFrostDriver(d).account
    let coins = @[BtcUtxo(txid: repeat("11", 32), vout: 0, value: 60_000, scriptPubKey: toHex(acct.scriptPubKey)),
                  BtcUtxo(txid: repeat("22", 32), vout: 1, value: 50_000, scriptPubKey: toHex(acct.scriptPubKey))]
    buildFrostSpend(acct, coins, BtcPayee, 100_000'u64, feeRate = 2)
  of "lez-multisig/transfer":
    # coordinate_propose_lez_transfer: token Transfer from the vault PDA, on-chain proposal #1
    let a = LezMultisigDriver(d).account
    let action = LezAction(target: hexToBytes(LezTokenProgram), instruction: tokenTransferWords(200),
                           accounts: @[vaultPda(a.scheme, a.program, a.createKey), hexToBytes(LezRecipient)],
                           pdaSeeds: @[vaultSeed(a.createKey)], authorized: @[0'u8])
    lezProposalEffect(1, action)
  of "lez-multisig/vault-init":
    # coordinate_propose_lez_vault_init: token InitializeAccount (variant 3), the vault authorized
    let a = LezMultisigDriver(d).account
    let action = LezAction(target: hexToBytes(LezTokenProgram), instruction: @[3'u32],
                           accounts: @[hexToBytes(LezTokenDefinition), vaultPda(a.scheme, a.program, a.createKey)],
                           pdaSeeds: @[vaultSeed(a.createKey)], authorized: @[1'u8])
    lezProposalEffect(1, action)
  of "lez-frost/transfer":
    # lezFrostTransfer: the group's own account sends, at its nonce (a chain read; 0 = fresh)
    let a = LezFrostDriver(d).account
    lezFrostCallEffect(hexToBytes(LezTokenProgram), @[a.accountId, hexToBytes(LezRecipient)],
                       tokenTransferWords(200), a.accountId, default(UInt128))
  of "evm-split/split":
    # the split composer: 0.9 ETH among the creditor and two debtors, even shares, paid to
    # the creditor's own address (proposer material)
    splitEffectJson("eip155:31337", "ETH", "900000000000000000", SplitCreditor, Payee,
                    evenShares("900000000000000000", SplitCreditor, @SplitDebtors), "Dinner")
  of "lez-split/split":
    # the private split: 0.9 LEZ (9 decimals) paid to the creditor's shielded key node,
    # every share a distinct amount so the creditor's scan can attribute each note
    splitEffectJson("lez:testnet", "LEZ", "900000000", SplitCreditor,
                    "priv:" & repeat("ab", 32) & ":02" & repeat("cd", 32),
                    evenShares("900000000", SplitCreditor, @SplitDebtors, distinctAmounts = true), "Dinner")
  of "evm-split/settle-up":
    # settle up (exo-3c6): two agreed splits between the creditor and one debtor netted —
    # the debtor owes 300 on the first, the creditor owes 200 on the second: one payment of 100
    let s1 = "0x" & repeat("11", 8)
    let s2 = "0x" & repeat("22", 8)
    let covers = @[Cover(intent: s1, debtor: SplitDebtors[0], creditor: SplitCreditor, amount: "300", payTo: Payee),
                   Cover(intent: s2, debtor: SplitCreditor, creditor: SplitDebtors[0], amount: "200",
                         payTo: "0x70997970c51812dc3a010c7d01b50e0d17dc79c8")]
    settleUpEffectJson("eip155:31337", "ETH", covers, netTransfers(covers), "Lisbon")
  of "btc-split/split":
    # a split paid in Bitcoin: 0.009 BTC (in satoshis) among the creditor and two debtors,
    # paid to the creditor's own wpkh address — here BIP-173's generator-key address on regtest
    splitEffectJson(BtcRegtest, "BTC", "900000", SplitCreditor,
                    p2wpkhAddress("bcrt", hexToBytes("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")),
                    evenShares("900000", SplitCreditor, @SplitDebtors), "Cabin")
  of "monero-split/request":
    # an XMR payment request: two debtors, the creditor not in it (chip in), every share
    # distinct (one subaddress takes both), in atomic units, paid to the creditor's
    # subaddress on stagenet
    splitEffectJson(XmrStagenet, "XMR", "1500000000000", SplitCreditor, XmrPayTo,
                    evenShares("1500000000000", SplitCreditor, @SplitDebtors, creditorShares = false,
                               distinctAmounts = true), "Cabin deposit")
  of "btc-split/settle-up":
    # settle up in Bitcoin: two agreed splits between the creditor and one debtor netted,
    # in satoshis — 300000 owed one way, 200000 the other: one payment of 100000, to the
    # wpkh address the split owing its recipient agreed
    let s1 = "0x" & repeat("11", 8)
    let s2 = "0x" & repeat("22", 8)
    let credTo = p2wpkhAddress("bcrt", hexToBytes("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"))
    let debtTo = p2wpkhAddress("bcrt", hexToBytes("02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"))
    let covers = @[Cover(intent: s1, debtor: SplitDebtors[0], creditor: SplitCreditor, amount: "300000", payTo: credTo),
                   Cover(intent: s2, debtor: SplitCreditor, creditor: SplitDebtors[0], amount: "200000", payTo: debtTo)]
    settleUpEffectJson(BtcRegtest, "BTC", covers, netTransfers(covers), "Cabin")
  else: raise newException(ValueError, "no corpus effect for " & kind & "/" & variant)

const Variants* = [
  ("safe", "transfer"), ("safe", "contract-call"), ("safe", "delegatecall"),
  ("threshold", "statement"), ("threshold", "add-driver"), ("unanimous", "statement"),
  ("frost", "statement"), ("eip191", "statement"),
  ("invoke", "module-call"), ("invoke", "lez-transfer"),
  ("btc-p2wsh", "spend"), ("btc-tapscript", "spend"), ("btc-frost", "spend"),
  ("lez-multisig", "transfer"), ("lez-multisig", "vault-init"), ("lez-frost", "transfer"),
  ("evm-split", "split"), ("evm-split", "settle-up"), ("lez-split", "split"), ("btc-split", "split"), ("btc-split", "settle-up"),
  ("monero-split", "request")]

# ── JSON ──────────────────────────────────────────────────────────────────────
proc cborJson(v: CborValue): JsonNode =
  ## An effect field as JSON: text and uints as themselves, bytes as lowercase hex (the
  ## form the effect's JSON carries them in), arrays and text-keyed maps structurally.
  case v.kind
  of ckUint:
    if v.u <= uint64(high(int64)): %int64(v.u) else: %($v.u)
  of ckNint: %(-1'i64 - int64(v.n))
  of ckBytes: %hx(v.b)
  of ckText: %v.t
  of ckBool: %v.bo
  of ckNull: newJNull()
  of ckArray:
    var a = newJArray()
    for x in v.arr: a.add cborJson(x)
    a
  of ckMap:
    var o = newJObject()
    for (k, x) in v.pairs:
      o[(if k.kind == ckText: k.t else: $cborJson(k))] = cborJson(x)
    o
  of ckFloat, ckIndefinite: raise newException(ValueError, "not a deterministic effect value")

proc effectJson(e: Effect): JsonNode =
  var fields = newJObject()
  for (k, v) in e.fields: fields[k] = cborJson(v)
  %*{"schema": e.schemaId, "fields": fields}

proc entry(kind, variant: string): JsonNode =
  let d = newDriver(kind, configOf(kind))
  let e = effectFromJson(effectJsonFor(kind, variant, d))
  let p = d.profile()
  let family = kindInfo(kind).family
  doAssert family == p.family, kind & ": kinds.nim names " & family & ", the profile " & p.family
  %*{"kind": kind, "variant": variant, "family": family,
     "effectExample": effectJson(e),
     "describe": describeFor(d, e).toJson(),   # THIS proposal's policy: describe() but for a split (exo-a90.3)
     "environment": d.environment(),
     "profile": p.toJson(),
     "manifest": d.manifest(e).toJson(),
     "signRefusal": d.signRefusal(e)}

proc fixtureDriver*(kind: string): Driver =
  ## The driver the corpus is generated from, for a kind — tests read the same fixtures.
  newDriver(kind, configOf(kind))

proc proposedEffectJson*(key: string): string =
  ## The effect JSON a room carries for the generated `<kind>/<variant>` — exactly what the
  ## hosted composer would propose, so a test can hold the card's rendering gate
  ## (effectSchema) to every effect a built driver canonicalizes.
  let i = key.find('/')
  let kind = key[0 ..< i]
  effectJsonFor(kind, key[i + 1 .. ^1], newDriver(kind, configOf(kind)))

proc corpus*(): JsonNode =
  ## The generated half of the action corpus: every built (kind, variant), keyed
  ## "<kind>/<variant>", in key order.
  var keys = Variants.mapIt(it[0] & "/" & it[1])
  keys.sort()
  var entries = newJObject()
  for key in keys:
    let i = key.find('/')
    entries[key] = entry(key[0 ..< i], key[i + 1 .. ^1])
  %*{"about": {
       "generatedBy": "module/tools/action_corpus.nim",
       "edit": "never by hand — regenerate with: " & RegenerateCommand,
       "checkedBy": "module/tests/action_corpus_test.nim",
       "design": "docs/design/action-atlas.md §3a"},
     "entries": entries}

proc corpusText*(): string = corpus().pretty(2) & "\n"

proc writeCorpus*() =
  createDir(GeneratedPath.parentDir())
  writeFile(GeneratedPath, corpusText())

when isMainModule:
  if "--write" in commandLineParams():
    writeCorpus()
    echo "wrote ", GeneratedPath.normalizedPath()
  else:
    stdout.write corpusText()
