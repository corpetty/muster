## The settlement seam (exo-a50.1.5; seam S6 of docs/design/multisig-landscape.md).
##
## Settlement was routed by policy STRING — `policy == "safe"` went to a Safe-only body
## that re-derived the hash, gathered owner signatures, hand-assembled calldata and
## sent it from anvil's unlocked account 0; `"invoke"` went elsewhere; anything else
## "settled nothing". Drivers and chain adapters never met. Now a family's SETTLEMENT is
## chosen from its profile (settlementFor), assembles from the contributions on the log,
## and submits + watches through the ChainAdapter seam with a configured relayer.
## Held here:
##   1. dispatch is by profile: a room family has no settlement; evm.safe has the Safe's;
##      an unsupported / undeclared driver has none (never a guess);
##   2. assemble re-derives the hash and admits only contributions the DRIVER accepts:
##      a non-owner is dropped, one owner twice counts once, signatures go ascending by
##      signer, below the threshold it refuses (naming have / need), and the calldata is
##      the real execTransaction of the full SafeTx;
##   3. submit and watch go THROUGH the adapter seam (a recording adapter here), from the
##      relayer account the settlement was configured with — no hardcoded sender;
##   4. the live precheck asks the profile, not a policy string.
## The same seam against the real Safe v1.4.1 on anvil: coordinate_submit_anvil.
## Needs the secp closure + libsodium (+ stint) — see tests/README.md.

import std/[json, algorithm, strutils]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/safe
import ../src/drivers/safe_rpc
import ../src/drivers/kinds
import ../src/drivers/threshold
import ../src/crypto/secp256k1
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/coordination/intent_events
import ../src/settlement/settlement
import ./probes/live_room

proc hexBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc addrOf(hex: string): Address =
  let b = hexBytes(hex); (for i in 0 ..< 20: result[i] = b[i])
proc keyOf(hex: string): array[32, byte] =
  let b = hexBytes(hex); (for i in 0 ..< 32: result[i] = b[i])

const Owners = ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"]
const Keys = ["0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
              "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
              "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"]
const Stranger = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
const Safe = "0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841"
let drv = newSafeDriver(chainId = 31337, safe = addrOf(Safe), owners = @[addrOf(Owners[0]),
                        addrOf(Owners[1]), addrOf(Owners[2])], threshold = 2)
let effectJson = """{"effect":"safe-tx","to":"0x00000000000000000000000000000000DeaDBeef","value":1000,"data":"0xcafe","nonce":4}"""
let effect = effectFromJson(effectJson)
let hash = canonicalize(drv, effect).bytes
proc sigBy(k: string): seq[byte] =
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = hash[i]
  @(signRecoverable(h, keyOf(k)))

# a recording adapter: the seam is exercised without a node
type Recorder = ref object of ChainAdapter
  sent: seq[PreparedTx]
method submit(a: Recorder, tx: PreparedTx, ks: Keystore): TxRef =
  a.sent.add tx
  TxRef(chain: tx.chain, id: "0xrecorded" & $a.sent.len)
method finality(a: Recorder, txRef: TxRef): Finality =
  Finality(status: fsFinal, detail: "recorded")

let relayer = Account(chain: "evm:31337", form: afPublic, id: Owners[2])

# ── 1. dispatch by profile ──────────────────────────────────────────────────────
block:
  let rec = Recorder()
  doAssert settlementFor(newThresholdDriver(@[], 1), rec, relayer) == nil, "a room family settles nowhere"
  doAssert settlementFor(newUnsupportedDriver("squads"), rec, relayer) == nil, "an unsupported driver never gets a settlement"
  let st = settlementFor(drv, rec, relayer)
  doAssert st != nil and st.family == "evm.safe"
  echo "1. settlement is chosen from the driver's profile (room / unsupported: none; evm.safe: the Safe's) OK"

# ── 2. assemble from the log's contributions ────────────────────────────────────
block:
  let st = settlementFor(drv, Recorder(), relayer)
  # one owner below the threshold → refused, naming have / need
  let low = st.assemble(drv, effect, @[("a", sigBy(Keys[0]))])
  doAssert not low.ok and low.error == "insufficient-signatures" and low.have == 1 and low.need == 2, $low
  # a stranger's signature and a duplicate owner never count
  let dup = st.assemble(drv, effect, @[("a", sigBy(Keys[0])), ("a-again", sigBy(Keys[0])),
                                       ("x", sigBy(Stranger))])
  doAssert not dup.ok and dup.have == 1, "a stranger and a repeated owner do not reach the threshold: " & $dup
  # two owners, given out of order → ascending by signer in the calldata
  let good = st.assemble(drv, effect, @[("c", sigBy(Keys[2])), ("a", sigBy(Keys[0]))])
  doAssert good.ok, $good
  var pair = @[(addrOf(Owners[0]), sigBy(Keys[0])), (addrOf(Owners[2]), sigBy(Keys[2]))]
  pair.sort(proc(x, y: (Address, seq[byte])): int = cmp(@(x[0]), @(y[0])))
  var sigs: seq[byte]
  for (_, s) in pair: sigs.add s
  let expected = assembleExecTransaction(toSafeTx(effect), sigs)
  let payload = parseJson(good.tx.payload)
  doAssert payload["to"].getStr().toLowerAscii() == Safe.toLowerAscii()
  doAssert hexBytes(payload["data"].getStr()) == expected, "the full SafeTx, signatures ascending by signer"
  doAssert good.tx.frm == relayer, "sent from the configured relayer"
  echo "2. assemble admits only the driver's contributions, dedups, sorts, enforces the threshold, builds the full execTransaction OK"

# ── 3. submit + watch through the adapter seam ─────────────────────────────────
block:
  let rec = Recorder()
  let st = settlementFor(drv, rec, relayer)
  let good = st.assemble(drv, effect, @[("a", sigBy(Keys[0])), ("b", sigBy(Keys[1]))])
  let ks = newInMemoryKeystore(keyOf(Keys[2]), keyOf(Keys[2]))
  let r = st.submit(good.tx, ks)
  doAssert rec.sent.len == 1 and r.id == "0xrecorded1", "submission goes through the adapter"
  doAssert st.watch(r).status == fsFinal
  echo "3. submit and watch go through the ChainAdapter seam, from the configured relayer OK"

# ── 4. the live precheck asks the profile ────────────────────────────────────────
block:
  var r = newRoom("/muster/1/settlement-precheck/proto")
  let id = r.propose("threshold", effectFor("threshold", 1))
  doAssert liveSubmitPrecheck(r.alice, liveDriverFor, id, Now) == "not-onchain",
    "a room family has nothing to settle"
  echo "4. the live precheck reads the profile's settlement, not a policy string OK"

echo "settlement_test: all OK"
