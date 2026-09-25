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
## A hosted call must not wait on a block (a UI call times out at 20s; a testnet block is
## ~40s), so `waitForInclusion = false` sends and returns at once: `finality` then reads
## a transaction it sent as pending until it lands, and as failed once 4 blocks pass
## without it. The callers complete on later ticks (coordination/vote.nim).
##
## Transport: nim-json-rpc over chronos (TLS by bearssl), like wallet/evm_rpc.nim; a
## call runs to completion with waitFor.

import std/[json, tables, strutils, base64, times, os, sequtils]
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

proc programId*(r: LezRpc, name: string): seq[byte] =
  ## A built-in program's id by name (getProgramIds, e.g. "token"), as its LE bytes.
  let j = r.call("getProgramIds", newJArray())
  if not j.hasKey(name): raise newException(WalletError, "the sequencer names no program " & name)
  wordsToBytes(j[name])

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
  waitForInclusion*: bool         ## false: send and return; completion is the caller's
  sent: Table[string, float]      ## hash → when this chain sent it (for finality)

proc hx(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

proc newLezMultisigLive*(rpc: LezRpc, ks: Keystore, chain: string, scheme: PdaScheme, program: seq[byte],
                         layout: ProposalLayout, blockMs = 15_000, pollMs = 2_000): LezMultisigLive =
  LezMultisigLive(rpc: rpc, ks: ks, chain: chain, scheme: scheme, program: program, layout: layout,
                  blockMs: blockMs, pollMs: pollMs, waitForInclusion: true)

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
  LezRead(found: a.owner.len > 0 or a.data.len > 0, data: a.data, owner: a.owner, height: h, nonce: a.nonce)

method txIncluded*(c: LezMultisigLive, hash: string): tuple[known: bool, height: uint64] =
  c.rpc.getTransaction(hash)

method finality*(c: LezMultisigLive, txRef: TxRef): Finality =
  ## Final once included. A transaction this chain sent and the chain does not know yet
  ## is pending for 4 blocks, then failed: dropped, which is how the chain refuses.
  let (known, h) = c.txIncluded(txRef.id)
  if known: return Finality(status: fsFinal, detail: "included at height " & $h)
  let at = c.sent.getOrDefault(txRef.id, 0.0)
  if at > 0 and epochTime() < at + float(4 * c.blockMs) / 1000.0:
    return Finality(status: fsPending, detail: "sent; waiting for the chain to include it")
  Finality(status: fsFailed, detail: "the chain does not know this transaction (dropped: refused)")

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

proc sendWith*(c: LezMultisigLive, program: seq[byte], accounts: seq[seq[byte]], signers: seq[seq[byte]],
               words: seq[uint32], witness: proc(h: array[32, byte]): seq[LezWitness]): LezTx =
  ## A public transaction to any program whose witnesses `witness` produces over the
  ## message hash: one per signer, in `signers` order, each the account's own key. A
  ## keystore label signs for a member account (sendSigned); a FROST signing round signs
  ## for an account an aggregate key owns (Phase D, exo-a50.4.6). The nonces are read
  ## from the chain; the transaction is sent and, unless waitForInclusion is off, awaited.
  var nonces: seq[UInt128]
  for s in signers: nonces.add c.rpc.getAccount(s).nonce
  let m = LezMessage(program: program, accounts: accounts, nonces: nonces, words: words)
  let ws = witness(messageHash(m))
  if ws.len != signers.len: return LezTx(ok: false, error: "one witness per signer")
  for i, w in ws:
    if publicAccountId(w.xonly) != signers[i]:
      return LezTx(ok: false, error: "witness " & $i & " is not by account " & hx(signers[i]))
  var sent: string
  try: sent = c.rpc.sendTransaction(leeTxPublic(m, ws))
  except WalletError as e:
    # the sequencer answered with a JSON-RPC error (a bad signature, a malformed
    # transaction): it refused the transaction outright; anything else is unreachability
    if "\"code\"" in e.msg: return LezTx(ok: false, error: "the sequencer refused it: " & e.msg)
    raise e
  let want = publicTxHash(m, ws)
  if sent.toLowerAscii() != want:
    return LezTx(ok: false, error: "the sequencer answered hash " & sent & " for transaction " & want)
  c.sent[want] = epochTime()
  if not c.waitForInclusion: return LezTx(ok: true, hash: want)     # sent, not yet landed
  c.awaitInclusion(want)

method sendWitnessed*(c: LezMultisigLive, program: seq[byte], accounts, signers: seq[seq[byte]],
                      words: seq[uint32], witnesses: seq[(seq[byte], seq[byte])]): LezTx =
  ## The given witnesses, as they are: a nonce the chain moved past makes them invalid,
  ## and the sequencer refuses the transaction.
  let ws = witnesses.mapIt(LezWitness(signature: it[0], xonly: it[1]))
  c.sendWith(program, accounts, signers, words, proc(h: array[32, byte]): seq[LezWitness] = ws)

proc sendSigned*(c: LezMultisigLive, program: seq[byte], accounts: seq[seq[byte]], signers: seq[seq[byte]],
                 words: seq[uint32]): LezTx =
  ## A public transaction to any program, signed by the keystore's member keys for
  ## `signers` (each one this chain `signs`). A signer this keystore does not hold
  ## refuses before anything is sent.
  for s in signers:
    if not c.signs(s): return LezTx(ok: false, error: "this keystore holds no key for account " & hx(s))
  let (ks, labels) = (c.ks, c.labels)
  c.sendWith(program, accounts, signers, words, proc(h: array[32, byte]): seq[LezWitness] =
    for s in signers:
      let label = labels[hx(s)]
      result.add LezWitness(signature: ks.lezMemberSign(label, h), xonly: ks.lezMemberKey(label)))

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
  c.sent[want] = epochTime()
  if not c.waitForInclusion: return LezTx(ok: true, hash: want)
  c.awaitInclusion(want)

method balance*(c: LezMultisigLive, account: Account, asset: AssetId): Amount =
  Amount(asset: c.describe().nativeAsset, raw: $c.rpc.getAccount(relayerParts(account.id).signer).balance)
