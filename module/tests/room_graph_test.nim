## The room map's projection (G1, exo-da4; docs/design/room-map.md §4): the room as
## nodes and edges folded from the log, adding no truth of its own.
##   1. every held entry is a node; edges name only nodes; seqs stay within the log
##   2. an approval hangs from its key until a VERIFIED binding ties that key to a member
##   3. what left is placed where it left, per observer, with the manifest's fields
##   4. reorder + duplication give the identical graph (invariant 4)
##   5. two members' graphs of one log differ only in viewer and readFrom (invariant 9)
##   6. a later joiner's graph holds nothing from before its admission (invariant 7)
##   7. the content, all of it: message text, the effect, chain references, payment reports
##   8. a report the fold refused stays in the graph, unattributed
##   (9–14 below) … 15. shared facets and guarantees are sent once and expand back exactly
## Stub + parts drivers; the binding is a real secp256k1 statement (libsodium + secp).

import std/[json, strutils, sequtils, sets, algorithm, tables]
import ./fixtures/parts_driver
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/curve25519
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/room_graph

proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc secret(h: string): array[32, byte] = (for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1])))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

# alice holds a real keystore: her member id is her encryption identity, her approval key
# a secp256k1 address, and the binding between them is a real statement
let ks = newInMemoryKeystore(secret("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let alice = hex(ks.encIdentity().toBytes())
let aliceKey = "0x" & hex(ks.address())
let bob = "b0b".repeat(4)
let carol = "ca7".repeat(4)

let stub: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 1, finality = finExternal, verifyResult = true)
let pdrv = PartsDriver()
let both: DriverFor = proc(kind: string): Driver =
  (if kind == "parts": Driver(pdrv) else: stub(kind))

let effectJson = """{"to":"0xdeadbeefcafe","value":424242}"""
let idA = intentIdFor(effectJson)
let link = ks.bindingFor(LinkContext(account: "room", slot: "0", expiry: 2_000_000_000'u64))
let (_, msg) = newMessageEvent(alice, 1, "a secret note", 1)

# epoch 0: alice and bob; alice proposes A and approves it with her key, bound to her
# epoch 1: carol is admitted; A is submitted and final; a split among bob and carol runs
let pEffect = partsEffect([bob, carol], alice)
let idB = intentIdFor(pEffect, "parts")
let story = chain(@[msg,
  proposerEvent(idA, alice), proposeEvent(idA, effectJson),
  contributeEvent(idA, aliceKey, "sa"), keyBindingEvent(idA, aliceKey, hex(encodeLink(link))),
  membershipEvent(1, carol),
  submitEvent(idA, chainRef = "0xfeedface"), finalEvent(idA, chainRef = "0xfeedface"),
  policyDeclEvent(idB, "parts"), proposeEvent(idB, pEffect),
  contributeEvent(idB, bob, hexName(bob)), contributeEvent(idB, carol, hexName(carol)),
  contributeEvent(idB, "mallory", hexName("mallory")),
  partEvent(idB, bob, "settled", "mallory", "0xforged"),
  partEvent(idB, bob, "settled", bob, "0xb0bpaid")])
let founders = @[alice, bob]

proc node(g: RoomGraph, id: string): GraphNode =
  for n in g.nodes: (if n.id == id: return n)
  doAssert false, "no node " & id
proc hasNode(g: RoomGraph, id: string): bool = g.nodes.anyIt(it.id == id)
proc edgesOf(g: RoomGraph, kind: string): seq[GraphEdge] = g.edges.filterIt(it.kind == kind)
proc entryOf(g: RoomGraph, key: string, evs: seq[Event]): GraphNode =
  for e in canonicalOrder(evs): (if e.key == key: return g.node("e:" & eventId(e)))
  doAssert false, "no entry " & key

let g = reduceRoomGraph(story, both, founders, alice)

block:
  doAssert g.seqMax == story.len - 1
  doAssert g.nodes.countIt(it.kind == "entry") == story.len, "every held entry is a node"
  let ids = g.nodes.mapIt(it.id).toHashSet()
  for e in g.edges:
    doAssert e.src in ids and e.dst in ids, "edge names a missing node: " & $e
    doAssert e.seq >= 0 and e.seq <= g.seqMax
  for n in g.nodes: doAssert n.seq >= -1 and n.seq <= g.seqMax
  doAssert g.edgesOf("parent").len == story.len - 1, "the hash links, one per parent held"
  doAssert g.hasNode("m:" & alice) and g.hasNode("m:" & bob) and g.hasNode("m:" & carol)
  doAssert g.node("m:" & carol).seq >= 0 and g.node("m:" & carol).attrs["joined"].getInt() == 1
  doAssert g.epochs.len == 2 and g.epochs[1].admitted == carol
  doAssert g.hasNode("i:" & idA) and g.node("i:" & idA).attrs["state"].getStr() == "final"
  doAssert g.edgesOf("proposed").anyIt(it.src == "m:" & alice and it.dst == "i:" & idA)
  doAssert g.edgesOf("input").anyIt(it.dst == "i:" & idA and it.attrs["kind"].getStr() == "propose")
  echo "1. every held entry is a node; edges name only nodes; members, epochs, intents OK"

block:
  # alice's approval is driver-counted under her KEY; the verified binding ties it to her
  let ap = g.edgesOf("approved").filterIt(it.dst == "i:" & idA)
  doAssert ap.len == 1 and ap[0].src == "k:" & aliceKey, $ap
  doAssert g.edgesOf("bound").anyIt(it.src == "m:" & alice and it.dst == "k:" & aliceKey)
  # a binding naming a key its statement's signer is not ties nothing
  let forged = story & @[keyBindingEvent(idA, "0x" & "11".repeat(20), hex(encodeLink(link)))]
  let gf = reduceRoomGraph(forged, both, founders, alice)
  doAssert not gf.edgesOf("bound").anyIt(it.dst == "k:0x" & "11".repeat(20))
  echo "2. an approval hangs from its key; only a verified binding ties the key to a member OK"

block:
  let lv = g.edgesOf("leaves")
  let submitSeq = g.entryOf("intent/" & idA & "/submit", story).seq
  doAssert lv.anyIt(it.src == "i:" & idA and it.dst == "o:chain-observer@stub:0" and it.seq == submitSeq)
  doAssert lv.allIt(it.seq >= submitSeq or it.src != "i:" & idA), "nothing of A leaves before submit"
  # the split: bob's counted settle leaves with the manifest's fields; the forged one does not
  let bobPaid = canonicalOrder(story).mapIt(it.key).find("intent/" & idB & "/part/" & bob & "/settled")
  let splitOut = lv.filterIt(it.src == "i:" & idB and it.dst == "o:chain-observer")   # an undeclared profile names no chain
  doAssert splitOut.len == 1, $splitOut
  doAssert splitOut[0].attrs["fields"].getElems().mapIt(it.getStr()) == @["amount", "payer"]
  doAssert splitOut[0].seq > bobPaid, "the counted report is the later one, by bob himself"
  doAssert g.hasNode("o:store-node") and g.node("o:store-node").seq == -1
  doAssert g.edgesOf("enters").anyIt(it.src == "o:outside" and it.attrs["kind"].getStr() == "final")
  echo "3. what left is placed where it left, per observer, with the declared fields OK"

block:
  var shuffled = story.reversed()
  shuffled.add story[3]; shuffled.add story[0]
  doAssert $reduceRoomGraph(shuffled, both, founders, alice).toJson() == $g.toJson()
  echo "4. reorder + duplicate → identical graph (inv 4) OK"

block:
  var a = reduceRoomGraph(story, both, founders, alice).toJson()
  var c = reduceRoomGraph(story, both, founders, carol).toJson()
  doAssert a["viewer"].getStr() == alice and c["viewer"].getStr() == carol
  doAssert a["readFrom"].getInt() == 0 and c["readFrom"].getInt() == 1
  for k in ["viewer", "readFrom"]: (a.delete(k); c.delete(k))
  doAssert $a == $c, "the map says the same about the room to every member who holds the log"
  echo "5. two members' graphs of one log differ only in viewer and readFrom OK"

block:
  # carol's client opens nothing sealed before her admission: what she holds starts there
  let o = canonicalOrder(story)
  var at = 0
  while not o[at].key.startsWith("membership/"): inc at
  let held = o[at .. ^1]
  let gc = reduceRoomGraph(held, both, founders, carol)
  doAssert gc.readFrom == 1
  for n in gc.nodes:
    if n.kind == "entry": doAssert n.epoch >= 1, "an entry from before her admission: " & $n
  for e in o[0 ..< at]: doAssert not gc.hasNode("e:" & eventId(e))
  doAssert not gc.hasNode("i:" & idA), "an intent proposed before she joined is not on her map"
  doAssert not gc.hasNode("k:" & aliceKey), "nor the key that approved it"
  doAssert gc.hasNode("i:" & idB)
  # nor any content from before it: the epoch-0 message and intent A's effect are absent
  let sc = $gc.toJson()
  for early in ["a secret note", "deadbeefcafe", "424242"]:
    doAssert early notin sc, "content from before her admission: " & early
  echo "6. a later joiner's graph holds nothing from before its admission, content included (inv 7) OK"

block:
  # the map is local and carries the room's content: every entry's value, parsed
  let s = $g.toJson()
  for c in ["a secret note", "deadbeefcafe", "424242", "feedface", "b0bpaid", "forged"]:
    doAssert c in s, "content missing from the map: " & c
  let msgNode = g.entryOf(canonicalOrder(story).filterIt(it.key.startsWith("message/"))[0].key, story)
  doAssert msgNode.attrs["content"]["body"].getStr() == "a secret note"
  let prop = g.node("i:" & idA)
  doAssert prop.attrs["effect"]["to"].getStr() == "0xdeadbeefcafe" and prop.attrs["effect"]["value"].getInt() == 424242
  doAssert prop.attrs["summary"].getStr().len > 0
  doAssert g.entryOf("intent/" & idA & "/submit", story).attrs["content"]["chainRef"].getStr() == "0xfeedface"
  # what left carries the chain reference that sent it, and the effect's values it names
  let outA = g.toJson()["crossings"].getElems().filterIt(it["dir"].getStr() == "out" and it{"intent"}.getStr() == idA)
  doAssert outA.len > 0 and outA.allIt(it["chainRef"].getStr() == "0xfeedface"), $outA
  echo "7. the content, all of it: message text, the effect, chain references, payment reports OK"

block:
  # mallory is not a party: her approval and bob's part "settled" by her stay, unattributed
  let o = canonicalOrder(story)
  let mal = g.node("e:" & eventId(o[o.mapIt(it.key).find("intent/" & idB & "/sig/mallory/1")]))
  doAssert not mal.attrs["counted"].getBool() and not mal.attrs.hasKey("account"), $mal
  doAssert not g.hasNode("m:mallory") and not g.hasNode("k:mallory")
  doAssert not g.edgesOf("approved").anyIt(it.src.endsWith("mallory"))
  let forgedPart = g.entryOf("intent/" & idB & "/part/" & bob & "/settled", story)   # the first: mallory's
  doAssert not forgedPart.attrs["counted"].getBool() and not forgedPart.attrs.hasKey("account")
  echo "8. a report the fold refused stays in the graph, unattributed OK"

block:
  # a room-key approval ("ed:<the member's Ed25519 key>", the split's) is that member's own:
  # the key is the first half of the member's identity, and the driver verified it signed
  let edAlice = "ed:" & alice[0 ..< 64]
  let idC = intentIdFor("""{"to":"0xc","value":3}""")
  let evs = chain(@[proposeEvent(idC, """{"to":"0xc","value":3}"""), contributeEvent(idC, edAlice, "sc"),
                    contributeEvent(idC, "ed:" & "ab".repeat(32), "sd")])
  let gk = reduceRoomGraph(evs, both, founders, alice)
  doAssert gk.edgesOf("approved").anyIt(it.src == "m:" & alice and it.dst == "i:" & idC), $gk.edgesOf("approved")
  doAssert not gk.nodes.anyIt(it.id == "k:" & edAlice)
  doAssert gk.nodes.anyIt(it.id == "k:ed:" & "ab".repeat(32)), "a room key that is no member's stays a key"
  echo "9. a room-key approval hangs from the member whose identity holds that key OK"

block:
  # parentless events sort by content id, so log position says nothing about epoch: find
  # an epoch-1 message whose id sorts BEFORE the admission that opened epoch 1
  let admit = membershipEvent(1, carol)
  var late: Event
  for n in 0 .. 500:
    late = Event(key: "message/late" & $n, value: "{}")
    if eventId(late) < eventId(admit): break
  doAssert eventId(late) < eventId(admit)
  let evs = @[admit, late]
  var sealedIn = initTable[string, int]()
  sealedIn[eventId(late)] = 1; sealedIn[eventId(admit)] = 1
  proc epochOfLate(g: RoomGraph): int = g.node("e:" & eventId(late)).epoch
  doAssert reduceRoomGraph(evs, both, founders, alice).epochOfLate == 0, "the position fallback is wrong here"
  doAssert reduceRoomGraph(evs, both, founders, alice, sealedIn).epochOfLate == 1
  echo "10. an entry's epoch is the one whose key opened it, wherever it sorts OK"

block:
  # C4 (exo-6b8): positions are causal, and each proposal carries its state per step.
  # Five roots published in this order, each naming the one before in `after`; their ids
  # sort otherwise, so canonical order would scramble them.
  let effectS = """{"to":"0xs","value":5}"""
  let idS = intentIdFor(effectS)
  var evs: seq[Event]
  for e in @[proposerEvent(idS, alice), proposeEvent(idS, effectS), contributeEvent(idS, "0xk1", "s1"),
             submitEvent(idS), finalEvent(idS)]:
    var x = e
    if evs.len > 0: x.after = @[eventId(evs[^1])]
    evs.add x
  let gs = reduceRoomGraph(evs.reversed(), both, founders, alice)
  var bySeq: seq[(int, string)]
  for n in gs.nodes:
    if n.kind == "entry": bySeq.add (n.seq, n.attrs["kind"].getStr())
  bySeq.sort()
  doAssert bySeq.mapIt(it[1]) == @["proposer", "propose", "sig", "submit", "final"], $bySeq
  # the proposal's state after each of its entries is the fold over the causal prefix
  let steps = gs.node("i:" & idS).attrs["steps"].getElems()
  doAssert steps.mapIt(it["state"].getStr()) == @["proposed", "executable", "submitted", "final"], $steps
  for st in steps:
    let k = st["seq"].getInt()
    let prefix = causalOrder(evs)[0 .. k]
    var want = ""
    for v in reduceIntentViews(prefix, both): (if v.id == idS: want = v.state)
    doAssert st["state"].getStr() == want
  echo "11. positions are causal; a proposal's state per step is the fold over the causal prefix OK"

proc facets(n: GraphNode): seq[JsonNode] = n.attrs["facets"].getElems()
proc classes(n: GraphNode): seq[string] = n.facets.mapIt(it["class"].getStr())

block:
  # V1 (exo-f2d): every held entry says what it guarantees, against whom, and how
  for n in g.nodes:
    if n.kind != "entry": continue
    doAssert n.attrs.hasKey("facets") and n.facets.len > 0, $n
    for f in n.facets:
      doAssert f["class"].getStr() in ["imperative", "motivational", "exposed", "not-applicable"]
      doAssert f["mechanism"].getStr().len > 0
      if f["class"].getStr() in ["motivational", "exposed"]: doAssert f["party"].getStr().len > 0, $f
    # who could read it: inside the epoch, imperative; the store node, exposed — on every entry
    doAssert n.facets.anyIt(it["class"].getStr() == "imperative" and it["about"].getStr() == "who could read it")
    doAssert n.facets.anyIt(it["class"].getStr() == "exposed" and it["party"].getStr() == "the store node")
  # a counted payment report: who wrote it is imperative, that it was paid is the payer's word
  let paid = g.edgesOf("part").filterIt(it.dst == "i:" & idB and it.src == "m:" & bob)
  doAssert paid.len == 1
  var settled: GraphNode
  for n in g.nodes:
    if n.kind == "entry" and n.attrs["kind"].getStr() == "part-settled" and n.attrs["counted"].getBool(): settled = n
  doAssert settled.facets.anyIt(it["class"].getStr() == "motivational" and "payer" in it["party"].getStr()), $settled.facets
  doAssert settled.facets.anyIt(it["class"].getStr() == "imperative" and it["about"].getStr() == "who wrote it")
  # the chain's answer is an outside read: motivational, on the reader's endpoint
  let fin = g.entryOf("intent/" & idA & "/final", story)
  doAssert fin.facets.anyIt(it["class"].getStr() == "motivational" and "endpoint" in it["party"].getStr())
  # an admission: who reads what is imperative (F-16); who was let in is a member's decision
  let adm = g.entryOf("membership/1/admit/" & carol, story)
  doAssert adm.facets.anyIt(it["class"].getStr() == "imperative" and "F-16" in it["mechanism"].getStr())
  doAssert adm.facets.anyIt(it["class"].getStr() == "motivational" and "admitting member" in it["party"].getStr())
  # a refused entry promises nothing
  let o = canonicalOrder(story)
  let mal = g.node("e:" & eventId(o[o.mapIt(it.key).find("intent/" & idB & "/sig/mallory/1")]))
  doAssert mal.facets.anyIt(it["class"].getStr() == "not-applicable")
  # connections carry a class too: what left is exposed to its observer
  for e in g.edgesOf("leaves"):
    doAssert e.attrs["credibility"].getStr() == "exposed" and e.attrs["party"].getStr().len > 0
  for e in g.edgesOf("enters"): doAssert e.attrs["credibility"].getStr() == "motivational"
  for e in g.edgesOf("bound") & g.edgesOf("proposed"): doAssert e.attrs["credibility"].getStr() == "imperative"
  echo "12. every entry and connection is graded imperative, motivational or exposed, with its party and mechanism OK"

block:
  # V2 (exo-737): the crossings ledger — every leave, every outside read, every admission
  let cj = g.toJson()["crossings"].getElems()
  let outs = cj.filterIt(it["dir"].getStr() == "out" and it["seq"].getInt() >= 0)
  doAssert outs.len == g.edgesOf("leaves").len, $outs.len
  for c in outs:
    doAssert c["observer"].getStr().startsWith("o:") and c["fields"].len > 0 and c["entry"].getStr().startsWith("e:")
  doAssert cj.anyIt(it["dir"].getStr() == "out" and it["observer"].getStr() == "o:store-node" and it["seq"].getInt() == -1),
    "the store node's summary: every envelope"
  doAssert cj.anyIt(it["dir"].getStr() == "in" and it["kind"].getStr() == "final")
  doAssert cj.anyIt(it["dir"].getStr() == "join" and it["member"].getStr() == "m:" & carol and it["epoch"].getInt() == 1)
  for c in cj: doAssert c.hasKey("credibility") and c.hasKey("mechanism")
  # in causal order
  var last = -2
  for c in cj: (doAssert c["seq"].getInt() >= last; last = c["seq"].getInt())
  echo "13. the crossings ledger names every leave, read and admission, in order OK"

block:
  # V3 (exo-26a): a fingerprint per epoch two members can compare. Carol holds the room
  # from her admission on; her fingerprint from epoch 1 equals alice's from epoch 1.
  let o = canonicalOrder(story)
  var at = 0
  while not o[at].key.startsWith("membership/"): inc at
  let gc = reduceRoomGraph(o[at .. ^1], both, founders, carol)
  proc fp(gr: RoomGraph, ep: int): string =
    for f in gr.toJson()["fingerprints"].getElems(): (if f["fromEpoch"].getInt() == ep: return f["digest"].getStr())
    ""
  doAssert fp(g, 1).len == 64 and fp(g, 1) == fp(gc, 1), "the same room from epoch 1 reads the same on both"
  doAssert fp(g, 0).len == 64 and fp(gc, 0) == "", "carol has no epoch-0 fingerprint to give"
  var tampered = story
  tampered.add Event(key: "message/extra", value: "{}")
  doAssert fp(reduceRoomGraph(tampered, both, founders, alice), 1) != fp(g, 1), "one more entry, another fingerprint"
  echo "14. a fingerprint per epoch, equal for members holding the same entries OK"

block:
  # exo-dde.19: the facets and guarantees every entry of a kind shares are sent once.
  # Expanded back (as Room.qml does), every node and edge is exactly its attrs; the
  # interned form is smaller, and the same graph gives the same bytes.
  let j = g.toJson()
  doAssert j.hasKey("facetSets") and j.hasKey("texts"), "the map names its shared facet sets and texts"
  var expanded = j.copy()
  for part in ["nodes", "edges"]:
    for x in expanded[part].getElems():
      let a = x["attrs"]
      if a.hasKey("facets") and a["facets"].kind == JInt: a["facets"] = j["facetSets"][a["facets"].getInt()]
      if a.hasKey("guarantee") and a["guarantee"].kind == JInt: a["guarantee"] = j["texts"][a["guarantee"].getInt()]
  for i, n in g.nodes: doAssert expanded["nodes"][i]["attrs"] == n.attrs, "node " & n.id & " expands to its attrs"
  for i, e in g.edges: doAssert expanded["edges"][i]["attrs"] == e.attrs, "edge " & e.src & "→" & e.dst & " expands to its attrs"
  var plain = 0
  for n in g.nodes: plain += len($n.attrs)
  var sent = len($j["facetSets"]) + len($j["texts"])
  for x in j["nodes"]: sent += len($x["attrs"])
  doAssert sent < plain, "interning makes the nodes smaller: " & $sent & " vs " & $plain
  doAssert $g.toJson() == $j, "the same graph gives the same bytes"
  echo "15. shared facets and guarantees are sent once and expand back exactly OK"

# 16. One chain's public is not another's (exo-dde): each chain an intent settles on is its
# own observer, and the crossing says what that chain shows — from the driver's profile.
type ChainStub = ref object of StubDriver
  chain: string
  effect: EffectVisibility
  signers: Reveal
method profile(d: ChainStub): FamilyProfile =
  FamilyProfile(declared: true, chain: d.chain, revealsEffect: d.effect, revealsSigners: d.signers)
proc chainStub(chain: string, effect: EffectVisibility, signers: Reveal): ChainStub =
  let s = newStubDriver(rounds = 1, threshold = 1, finality = finExternal, verifyResult = true)
  ChainStub(descriptor: s.descriptor, verifyResult: true, chain: chain, effect: effect, signers: signers)

block:
  let sepolia = chainStub("eip155:11155111", evPublic, rvAtSettle)
  let monero = chainStub("monero:76ee3cc9", evShielded, rvNever)
  let chains: DriverFor = proc(kind: string): Driver =
    (if kind == "pub": Driver(sepolia) elif kind == "xmr": Driver(monero) else: stub(kind))
  let pubFx = """{"to":"0x5e9011a","value":1}"""
  let xmrFx = """{"to":"57VTxmr","value":2}"""
  let (idP, idX) = (intentIdFor(pubFx, "pub"), intentIdFor(xmrFx, "xmr"))
  var evs: seq[Event] = @[msg]
  for (id, fx, pol) in [(idP, pubFx, "pub"), (idX, xmrFx, "xmr")]:
    evs.add @[policyDeclEvent(id, pol), proposerEvent(id, alice), proposeEvent(id, fx),
              contributeEvent(id, aliceKey, "sa"), submitEvent(id, chainRef = "0x" & pol),
              finalEvent(id, chainRef = "0x" & pol)]
  let gc = reduceRoomGraph(chain(evs), chains, founders, alice)
  let pubObs = "o:chain-observer@eip155:11155111"
  let xmrObs = "o:chain-observer@" & monero.chain
  doAssert gc.hasNode(pubObs) and gc.hasNode(xmrObs), "one observer per chain"
  doAssert not gc.hasNode("o:chain-observer@stub:0"), "only the chains these intents settle on"
  doAssert gc.edgesOf("leaves").anyIt(it.src == "i:" & idP and it.dst == pubObs)
  doAssert gc.edgesOf("leaves").anyIt(it.src == "i:" & idX and it.dst == xmrObs)
  doAssert not gc.edgesOf("leaves").anyIt(it.src == "i:" & idX and it.dst == pubObs), "Monero's leaves never reach Sepolia's readers"
  doAssert gc.node(pubObs).attrs["surface"].getStr() == "public" and gc.node(pubObs).attrs["chainLabel"].getStr() == "Sepolia"
  doAssert gc.node(xmrObs).attrs["surface"].getStr() == "shielded"
  doAssert "never its payer, payee or amount" in gc.node(xmrObs).attrs["sees"].getStr()
  doAssert "from whom and to whom" in gc.node(pubObs).attrs["sees"].getStr()
  let outs = gc.crossings.filterIt(it["dir"].getStr() == "out" and it["kind"].getStr() == "leaves")
  let xc = outs.filterIt(it["intent"].getStr() == idX)
  doAssert xc.len > 0 and xc.allIt(it["surface"].getStr() == "shielded" and it["chain"].getStr() == monero.chain)
  doAssert xc.allIt("never its payer" in it["mechanism"].getStr()), $xc
  doAssert outs.filterIt(it["intent"].getStr() == idP).allIt(it["party"].getStr() == "anyone reading Sepolia")
  echo "16. each chain is its own observer, and says what it shows (public · shielded) OK"

echo "room_graph_test: all OK"
