## Taproot (BIP-341) for a script-path multisig (exo-a50.2.1): tapleaf / tapbranch /
## taptweak hashes, a script tree's merkle root and each leaf's control block, and the
## tweaked output key — computed with libsecp256k1's x-only tweak. The internal key of
## a multi_a-only output is the BIP-341 NUMS point H, so the key path is unspendable.
## Pinned to the BIP-341 wallet test vectors.

import pkg/secp256k1/abi
import ./tx

const NumsH* = "50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0"
  ## lift_x(sha256(G)) — a point with no known discrete log (BIP-341)
const TapscriptLeafVersion* = 0xc0'u8

type
  TapNode* = ref object
    case isLeaf*: bool
    of true:
      script*: seq[byte]
      leafVersion*: uint8
    of false:
      left*, right*: TapNode

  TapLeafInfo* = object
    script*: seq[byte]
    leafVersion*: uint8
    leafHash*: array[32, byte]
    path*: seq[array[32, byte]]   ## sibling hashes, deepest first (the control block's order)

proc tapLeaf*(script: seq[byte], leafVersion = TapscriptLeafVersion): TapNode =
  TapNode(isLeaf: true, script: script, leafVersion: leafVersion)
proc tapBranch*(l, r: TapNode): TapNode = TapNode(isLeaf: false, left: l, right: r)

proc tapLeafHash*(script: openArray[byte], leafVersion = TapscriptLeafVersion): array[32, byte] =
  taggedHash("TapLeaf", @[leafVersion] & withSize(script))

proc lessEq(a, b: array[32, byte]): bool =
  for i in 0 ..< 32:
    if a[i] != b[i]: return a[i] < b[i]
  true

proc tapBranchHash*(a, b: array[32, byte]): array[32, byte] =
  if lessEq(a, b): taggedHash("TapBranch", @a & @b) else: taggedHash("TapBranch", @b & @a)

proc walk(n: TapNode, leaves: var seq[TapLeafInfo]): array[32, byte] =
  if n.isLeaf:
    let h = tapLeafHash(n.script, n.leafVersion)
    leaves.add TapLeafInfo(script: n.script, leafVersion: n.leafVersion, leafHash: h)
    return h
  var l, r: seq[TapLeafInfo]
  let hl = walk(n.left, l)
  let hr = walk(n.right, r)
  for x in l.mitems: x.path.add hr
  for x in r.mitems: x.path.add hl
  leaves.add l; leaves.add r
  tapBranchHash(hl, hr)

proc merkle*(tree: TapNode): tuple[root: array[32, byte], leaves: seq[TapLeafInfo]] =
  ## The tree's merkle root and every leaf with its path (DFS order, left first).
  var leaves: seq[TapLeafInfo]
  let r = walk(tree, leaves)
  (r, leaves)

proc tapTweak*(internalKey: openArray[byte], merkleRoot: seq[byte]): array[32, byte] =
  taggedHash("TapTweak", @internalKey & merkleRoot)

proc outputKey*(internalKey: openArray[byte], merkleRoot: seq[byte]): tuple[key: array[32, byte], parity: int] =
  ## Q = P + t·G, t = TapTweak(P || root): libsecp256k1's x-only tweak.
  if internalKey.len != 32: raise newException(BtcError, "an internal key is 32 bytes")
  let ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE)
  defer: secp256k1_context_destroy(ctx)
  var p: secp256k1_xonly_pubkey
  if secp256k1_xonly_pubkey_parse(ctx, addr p, unsafeAddr internalKey[0]) != 1:
    raise newException(BtcError, "the internal key is not on the curve")
  var t = tapTweak(internalKey, merkleRoot)
  var full: secp256k1_pubkey
  if secp256k1_xonly_pubkey_tweak_add(ctx, addr full, addr p, addr t[0]) != 1:
    raise newException(BtcError, "the taproot tweak failed")
  var q: secp256k1_xonly_pubkey
  var parity: cint
  discard secp256k1_xonly_pubkey_from_pubkey(ctx, addr q, addr parity, addr full)
  var out32: array[32, byte]
  discard secp256k1_xonly_pubkey_serialize(ctx, addr out32[0], addr q)
  (out32, int(parity))

proc controlBlock*(leaf: TapLeafInfo, internalKey: openArray[byte], parity: int): seq[byte] =
  result = @[byte(leaf.leafVersion or byte(parity and 1))] & @internalKey
  for h in leaf.path: result.add @h
