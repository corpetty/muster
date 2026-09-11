## P-D3 — discovering coordinatable actions from a module's descriptors + the
## allowlist. Pure/headless: no host, a canned lp_get_methods descriptor.

import std/json
import ../src/coordination/invoker
import ../src/coordination/discovery

# A stand-in for delivery_module's lp_get_methods: a mix of an action (send), another
# action (subscribe), and two reads (version, getNodeInfo).
let delivery = %*[
  {"name": "send", "signature": "send(QString,QByteArray)",
   "parameters": [{"name": "contentTopic", "type": "QString"},
                  {"name": "payload", "type": "QByteArray"}]},
  {"name": "subscribe", "signature": "subscribe(QString)",
   "parameters": [{"name": "contentTopic", "type": "QString"}]},
  {"name": "version", "signature": "version()", "parameters": []},
  {"name": "getNodeInfo", "signature": "getNodeInfo(QString)",
   "parameters": [{"name": "nodeInfoId", "type": "QString"}]}]

# ── 1. the read-pruning heuristic ──────────────────────────────────────────────
block:
  doAssert isReadName("version") and isReadName("getNodeInfo") and isReadName("listPeers")
  doAssert not isReadName("send") and not isReadName("subscribe") and not isReadName("cast")
  echo "1. read-name heuristic prunes get*/version/list*, keeps send/cast OK"

# ── 2. discoverActions: allowlist curates in, reads prune, candidates surface ───
block:
  let allow = @[AllowEntry(module: "delivery_module", meth: "send")]
  let actions = discoverActions("delivery_module", delivery, allow)
  var names: seq[string]
  var allowedOf: seq[(string, bool)]
  for a in actions: (names.add a.meth; allowedOf.add (a.meth, a.allowed))
  doAssert "send" in names, "the allowlisted action is discovered"
  doAssert "subscribe" in names, "a non-read, non-allowlisted method surfaces as a candidate"
  doAssert "version" notin names and "getNodeInfo" notin names, "reads are pruned"
  for (m, al) in allowedOf:
    if m == "send": doAssert al, "send is allowed (executable now)"
    if m == "subscribe": doAssert not al, "subscribe is a candidate (not yet allowlisted)"
  # a read that IS allowlisted is NOT pruned (curation overrides the heuristic)
  let allow2 = @[AllowEntry(module: "delivery_module", meth: "getNodeInfo")]
  let a2 = discoverActions("delivery_module", delivery, allow2)
  var n2: seq[string]
  for a in a2: n2.add a.meth
  doAssert "getNodeInfo" in n2, "an allowlisted read is curated in despite the heuristic"
  echo "2. discoverActions: allowlist curates in, reads prune, candidates surface OK"

# ── 3. discoverAcross via the Invoker seam (LocalInvoker) ──────────────────────
block:
  let inv = newLocalInvoker()
  inv.registerMethods("delivery_module", delivery)
  let allow = @[AllowEntry(module: "delivery_module", meth: "send")]
  let j = discoverAcross(inv, @["delivery_module"], allow)
  doAssert j.kind == JArray and j.len == 2, "two coordinatable actions across the module"
  var sawSend = false
  for a in j:
    if a["method"].getStr() == "send":
      sawSend = true
      doAssert a["allowed"].getBool(), "send marked executable"
      doAssert a["params"].kind == JArray and a["params"].len == 2, "params carried for the card"
  doAssert sawSend
  echo "3. discoverAcross via the Invoker seam OK"

echo "discovery_test: all OK"
