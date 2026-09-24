## Bitcoin transactions: the model, compact sizes, segwit (de)serialization, txid,
## sha256d and BIP-340 tagged hashes (exo-a50.2.1). Pure; pinned to the BIP-143 vectors.

import std/strutils
import ../hashing/sha256

type
  OutPoint* = object
    txid*: array[32, byte]   ## internal (serialized) byte order; txidHex shows it reversed
    vout*: uint32
  TxIn* = object
    prevout*: OutPoint
    scriptSig*: seq[byte]
    sequence*: uint32
    witness*: seq[seq[byte]]
  TxOut* = object
    value*: uint64           ## satoshis
    scriptPubKey*: seq[byte]
  BtcTx* = object
    version*: uint32
    inputs*: seq[TxIn]
    outputs*: seq[TxOut]
    locktime*: uint32

  BtcError* = object of CatchableError

  BtcUtxo* = object
    ## an unspent output as a node reports it — what a spend is built from
    txid*: string            ## display (big-endian) hex, as RPC and explorers show it
    vout*: uint32
    value*: uint64           ## satoshis
    scriptPubKey*: string    ## hex

proc le32*(x: uint32): seq[byte] = @[byte(x and 0xff), byte((x shr 8) and 0xff), byte((x shr 16) and 0xff), byte(x shr 24)]
proc le64*(x: uint64): seq[byte] =
  for i in 0 ..< 8: result.add byte((x shr uint64(8*i)) and 0xff)

proc compactSize*(n: uint64): seq[byte] =
  if n < 0xfd: @[byte(n)]
  elif n <= 0xffff: @[0xfd'u8, byte(n and 0xff), byte(n shr 8)]
  elif n <= 0xffffffff'u64: @[0xfe'u8] & le32(uint32(n))
  else: @[0xff'u8] & le64(n)

proc withSize*(b: openArray[byte]): seq[byte] = compactSize(uint64(b.len)) & @b

proc hexToBytes*(s: string): seq[byte] =
  var h = s.strip()
  if h.len >= 2 and h[0] == '0' and h[1] in {'x', 'X'}: h = h[2 .. ^1]
  if h.len mod 2 != 0: raise newException(BtcError, "odd-length hex")
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except ValueError: raise newException(BtcError, "bad hex")

proc toHex*(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc sha256d*(b: openArray[byte]): array[32, byte] = sha256(sha256(b))

proc taggedHash*(tag: string, data: openArray[byte]): array[32, byte] =
  ## BIP-340: sha256(sha256(tag) || sha256(tag) || data)
  var t: seq[byte]
  for c in tag: t.add byte(c)
  let th = sha256(t)
  sha256(@th & @th & @data)

proc serializeOutpoint*(o: OutPoint): seq[byte] = @(o.txid) & le32(o.vout)
proc serializeOutput*(o: TxOut): seq[byte] = le64(o.value) & withSize(o.scriptPubKey)

proc hasWitness*(tx: BtcTx): bool =
  for i in tx.inputs:
    if i.witness.len > 0: return true
  false

proc serialize*(tx: BtcTx, withWitness = true): seq[byte] =
  ## BIP-144: marker 0x00 + flag 0x01 only when a witness is present and asked for.
  let wit = withWitness and tx.hasWitness()
  result = le32(tx.version)
  if wit: result.add @[0x00'u8, 0x01]
  result.add compactSize(uint64(tx.inputs.len))
  for i in tx.inputs:
    result.add serializeOutpoint(i.prevout)
    result.add withSize(i.scriptSig)
    result.add le32(i.sequence)
  result.add compactSize(uint64(tx.outputs.len))
  for o in tx.outputs: result.add serializeOutput(o)
  if wit:
    for i in tx.inputs:
      result.add compactSize(uint64(i.witness.len))
      for w in i.witness: result.add withSize(w)
  result.add le32(tx.locktime)

proc txid*(tx: BtcTx): array[32, byte] = sha256d(tx.serialize(withWitness = false))

proc txidHex*(tx: BtcTx): string =
  ## the txid as block explorers and RPCs print it (byte-reversed)
  var r = tx.txid()
  for i in 0 ..< 16: swap(r[i], r[31 - i])
  toHex(r)

proc outpointFromHex*(txidHex: string, vout: uint32): OutPoint =
  ## an outpoint from a txid as printed (reversed) — the RPC / explorer form
  let b = hexToBytes(txidHex)
  if b.len != 32: raise newException(BtcError, "a txid is 32 bytes")
  for i in 0 ..< 32: result.txid[i] = b[31 - i]
  result.vout = vout

# ── parsing ──────────────────────────────────────────────────────────────────
type Reader = object
  b: seq[byte]
  p: int

proc need(r: var Reader, n: int) =
  if r.p + n > r.b.len: raise newException(BtcError, "truncated transaction")

proc u8(r: var Reader): byte = (r.need(1); result = r.b[r.p]; inc r.p)
proc u32(r: var Reader): uint32 =
  r.need(4)
  for i in 0 ..< 4: result = result or (uint32(r.b[r.p + i]) shl uint32(8*i))
  r.p += 4
proc u64(r: var Reader): uint64 =
  r.need(8)
  for i in 0 ..< 8: result = result or (uint64(r.b[r.p + i]) shl uint64(8*i))
  r.p += 8
proc cs(r: var Reader): uint64 =
  let f = r.u8()
  case f
  of 0xfd: (r.need(2); result = uint64(r.b[r.p]) or (uint64(r.b[r.p+1]) shl 8); r.p += 2)
  of 0xfe: result = uint64(r.u32())
  of 0xff: result = r.u64()
  else: result = uint64(f)
proc bytesN(r: var Reader, n: int): seq[byte] = (r.need(n); result = r.b[r.p ..< r.p + n]; r.p += n)

proc parseTx*(b: openArray[byte]): BtcTx =
  var r = Reader(b: @b)
  result.version = r.u32()
  var segwit = false
  if r.p + 1 < r.b.len and r.b[r.p] == 0x00 and r.b[r.p + 1] == 0x01:
    segwit = true; r.p += 2
  let nin = r.cs()
  for _ in 0'u64 ..< nin:
    var i: TxIn
    let t = r.bytesN(32)
    for k in 0 ..< 32: i.prevout.txid[k] = t[k]
    i.prevout.vout = r.u32()
    i.scriptSig = r.bytesN(int(r.cs()))
    i.sequence = r.u32()
    result.inputs.add i
  let nout = r.cs()
  for _ in 0'u64 ..< nout:
    var o: TxOut
    o.value = r.u64()
    o.scriptPubKey = r.bytesN(int(r.cs()))
    result.outputs.add o
  if segwit:
    for i in 0 ..< result.inputs.len:
      let n = r.cs()
      for _ in 0'u64 ..< n: result.inputs[i].witness.add r.bytesN(int(r.cs()))
  result.locktime = r.u32()
  if r.p != r.b.len: raise newException(BtcError, "trailing bytes after the transaction")
