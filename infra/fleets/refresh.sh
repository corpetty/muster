#!/usr/bin/env bash
# Refresh the pinned Logos delivery-fleet bootstrap sets from the live dashboard.
# The Logos fleets (https://fleets.logos.co) publish their node table as JSON at
# https://fleets.logos.co/data.json — the same source the Status app uses for its
# own fleets. We extract the `logos-node-delivery` service per fleet and write, for
# each, a ready-to-use delivery `createNode` config (`delivery_createNode_config`)
# plus the raw node table (multiaddr/enr/peer_id/cluster). Peer ids rotate when a
# node is re-keyed, so re-run this when discovery starts failing.
#
#   ./infra/fleets/refresh.sh            # rewrites infra/fleets/{logos.test,logos.dev}.json
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="https://fleets.logos.co/data.json"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -sSL "$SRC" -o "$tmp"
python3 - "$tmp" "$HERE" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); here=sys.argv[2]
for fleet in ("logos.test","logos.dev"):
    if fleet not in d: continue
    dv=d[fleet].get("logos-node-delivery",{})
    nodes=[]
    for name,rec in sorted(dv.items()):
        m=rec.get("ServiceMeta",{})
        nodes.append({"node":name,"cluster":m.get("cluster-id"),"multiaddr":m.get("multiaddr"),
                      "enr":m.get("enr"),"peer_id":m.get("peer_id"),"protocols":m.get("protocols")})
    mas=[n["multiaddr"] for n in nodes if n["multiaddr"]]
    cluster=nodes[0]["cluster"] if nodes else None
    out={"fleet":fleet,"clusterId":int(cluster) if cluster else None,
         "source":"https://fleets.logos.co/data.json","service":"logos-node-delivery",
         "delivery_createNode_config":{"mode":"Core","preset":fleet,"entryNodes":mas},
         "nodes":nodes}
    json.dump(out, open(f"{here}/{fleet}.json","w"), indent=2)
    print(f"  {fleet}: cluster {cluster}, {len(mas)} delivery nodes")
PY
echo "refreshed infra/fleets/*.json from $SRC"
