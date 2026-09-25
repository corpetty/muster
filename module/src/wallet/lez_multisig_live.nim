## The LEZ multisig, live (exo-3c9): the chain seam of lez/multisig_chain.nim over a REAL
## LEZ v0.2.4 sequencer. The sequencer is the user's own, reached over JSON-RPC and
## untrusted (invariant 8). The member's own key, held in the keystore, signs the
## member's own transactions.
##
## Why muster signs here rather than the LEZ wallet module: at muster's pin, lez_core
## 0.4.0 (LEZ v0.2.2) cannot carry a generic program call. Its
## send_generic_public_transaction takes the instruction as std::vector<uint32_t>, which
## the module's generated IPC glue drops (fixed upstream in 51eadfb). The fix ships only
## in lez_core 0.4.1+, which targets LEZ v0.2.5 release candidates, not the v0.2.4
## testnet. So the member's key lives where the in-app EVM and Bitcoin keys do: in the
## keystore, per-membership (Keystore.lezMemberKey), never exported. When lez_core can
## send to the program on the chain the testnet runs, a wallet-backed chain slots in behind
## the same LezMultisigChain seam. See docs/labbook/lez-multisig-versions.md.
##
## What the chain says is final. A transaction the program refuses is dropped at block
## production and never included, so submit waits for inclusion and reports a refusal
## when the transaction does not land. The sequencer's log holds the program's reason;
## the JSON-RPC does not expose it. LEZ v0.2.4 charges no fees, so `payer` is unused.
##
## Transport: nim-json-rpc over chronos (TLS by bearssl), like wallet/evm_rpc.nim; a
## call runs to completion with waitFor.

import std/[json, tables, strutils, base64, times, os]
import chronos
import stint
import json_rpc/clients/httpclient
import ../crypto/keystore
import ../lez/multisig
import ../lez/multisig_chain
import ../lez/tx as leztx
import ./types

# ── the sequencer ─────────────────────────────────────────────────────────────
type LezRpc* = ref object
  url*: string
  client: RpcHttpClient

proc newLezRpc*(url: string): LezRpc = LezRpc(url: url)

proc call(r: LezRpc, meth: string, params: JsonNode): JsonNode =
  ## One JSON-RPC call → its `result`. Any failure raises WalletError, and the client is
  ## dropped so the next call reconnects.
  try:
    if r.client == nil:
      let c = newRpcHttpClient()
      waitFor c.connect(r.url)
      r.client = c
    parseJson(string(waitFor r.client.call(meth, params)))
  except CatchableError as e:
    if r.client != nil:
      try: waitFor r.client.close()
      except CatchableError: discard
      r.client = nil
    raise newException(WalletError, "LEZ " & meth & " at " & r.url & ": " & e.msg)

proc u128Of(n: JsonNode): UInt128 =
  case n.kind
  of JInt: u128(n.getBiggestInt())
  of JString: parse(n.getStr(), UInt128)
  else: raise newException(WalletError, "not a u128: " & $n)

proc wordsToBytes(n: JsonNode): seq[byte] =
  ## A ProgramId as the chain sends it ([u32; 8]) → its little-endian bytes.
  for w in n.getElems():
    let x = uint32(w.getBiggestInt())
    for i in 0 ..< 4: result.add byte((x shr (8*i)) and 0xff)

proc lastBlockId*(r: LezRpc): uint64 = uint64(r.call("getLastBlockId", newJArray()).getBiggestInt())

type LezAccountState* = object
  owner*: seq[byte]               ## the owning program ([] = none)
  balance*: UInt128
  data*: seq[byte]
  nonce*: UInt128

proc getAccount*(r: LezRpc, id: seq[byte]): LezAccountState =
  let j = r.call("getAccount", %*[accountIdToBase58(id)])
  let owner = wordsToBytes(j["program_owner"])
  var any = false
  for b in owner: any = any or b != 0
  if any: result.owner = owner
  result.balance = u128Of(j["balance"])
  for b in j["data"].getElems(): result.data.add byte(b.getInt())
  result.nonce = u128Of(j["nonce"])

proc sendTransaction*(r: LezRpc, leeTx: seq[byte]): string =
  ## → the transaction hash (hex) the sequencer accepted into its mempool; not yet landed.
  r.call("sendTransaction", %*[encode(leeTx)]).getStr()

proc getTransaction*(r: LezRpc, hash: string): tuple[known: bool, height: uint64] =
  let j = r.call("getTransaction", %*[hash])
  if j.kind != JArray or j.len < 2: return (false, 0'u64)
  (true, uint64(j[1].getBiggestInt()))

# ── the chain seam, live ──────────────────────────────────────────────────────
type LezMultisigLive* = ref object of LezMultisigChain
  rpc*: LezRpc
  ks*: Keystore
  labels: Table[string, string]   ## member account id (hex) → the keystore label that signs it
  blockMs*: int                   ## the chain's block time; submit waits up to 4 blocks
  pollMs*: int

proc hx(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

proc newLezMultisigLive*(rpc: LezRpc, ks: Keystore, chain: string, scheme: PdaScheme, program: seq[byte],
                         layout: ProposalLayout, blockMs = 15_000, pollMs = 2_000): LezMultisigLive =
  LezMultisigLive(rpc: rpc, ks: ks, chain: chain, scheme: scheme, program: program, layout: layout,
                  blockMs: blockMs, pollMs: pollMs)

proc addMember*(c: LezMultisigLive, label: string): seq[byte] =
  ## The LEZ account this keystore signs for under `label` (fresh until first used): its
  ## id, which is what a member discloses and what the program claims at create.
  result = publicAccountId(c.ks.lezMemberKey(label))
  c.labels[hx(result)] = label

proc signs*(c: LezMultisigLive, account: seq[byte]): bool = hx(account) in c.labels

method height*(c: LezMultisigLive): uint64 = c.rpc.lastBlockId()

method readAccount*(c: LezMultisigLive, id: seq[byte]): LezRead =
  let h = c.rpc.lastBlockId()
  let a = c.rpc.getAccount(id)
  LezRead(found: a.owner.len > 0 or a.data.len > 0, data: a.data, owner: a.owner, height: h)

method txIncluded*(c: LezMultisigLive, hash: string): tuple[known: bool, height: uint64] =
  c.rpc.getTransaction(hash)

proc awaitInclusion(c: LezMultisigLive, hash: string): LezTx =
  let deadline = epochTime() + float(4 * c.blockMs) / 1000.0
  while true:
    let (known, h) = c.rpc.getTransaction(hash)
    if known: return LezTx(ok: true, hash: hash, height: h)
    if epochTime() > deadline:
      return LezTx(ok: false, hash: hash,
                   error: "not included within 4 blocks: the sequencer dropped it, which is how the chain " &
                          "refuses a transaction (the program's reason is in the sequencer's log)")
    sleep(c.pollMs)

proc sendSigned*(c: LezMultisigLive, program: seq[byte], accounts: seq[seq[byte]], signers: seq[seq[byte]],
                 words: seq[uint32]): LezTx =
  ## A public transaction to any program, signed by the keystore's member keys for
  ## `signers` (each one this chain `signs`), sent and awaited. A signer this keystore
  ## does not hold refuses before anything is sent.
  var nonces: seq[UInt128]
  for s in signers:
    if not c.signs(s): return LezTx(ok: false, error: "this keystore holds no key for account " & hx(s))
    nonces.add c.rpc.getAccount(s).nonce
  let m = LezMessage(program: program, accounts: accounts, nonces: nonces, words: words)
  let h = messageHash(m)
  var ws: seq[LezWitness]
  for s in signers:
    let label = c.labels[hx(s)]
    ws.add LezWitness(signature: c.ks.lezMemberSign(label, h), xonly: c.ks.lezMemberKey(label))
  let sent = c.rpc.sendTransaction(leeTxPublic(m, ws))
  let want = publicTxHash(m, ws)
  if sent.toLowerAscii() != want:
    return LezTx(ok: false, error: "the sequencer answered hash " & sent & " for transaction " & want)
  c.awaitInclusion(want)

method submit*(c: LezMultisigLive, signer: seq[byte], op: MultisigOp, payer: seq[byte] = @[]): LezTx =
  ## The member's own multisig transaction. A create is signed by nobody (it claims fresh
  ## member accounts); every other op by `signer`, whose key this keystore must hold.
  let accounts = opAccounts(c.scheme, c.program, op, signer)
  let words = instructionWords(op, c.layout)
  c.sendSigned(c.program, accounts, (if opSigned(op): @[signer] else: @[]), words)

proc deploy*(c: LezMultisigLive, bytecode: seq[byte]): LezTx =
  ## Deploy a program (unsigned; the ELF's image id becomes its program id). A second
  ## deployment of the same bytes is refused by the chain (ProgramAlreadyExists).
  let sent = c.rpc.sendTransaction(leeTxDeploy(bytecode))
  let want = deployTxHash(bytecode)
  if sent.toLowerAscii() != want:
    return LezTx(ok: false, error: "the sequencer answered hash " & sent & " for deployment " & want)
  c.awaitInclusion(want)

method balance*(c: LezMultisigLive, account: Account, asset: AssetId): Amount =
  Amount(asset: c.describe().nativeAsset, raw: $c.rpc.getAccount(relayerParts(account.id).signer).balance)
