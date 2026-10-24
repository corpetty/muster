import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes

import Logos.Theme
import Logos.Controls
import Logos.Icons

// The room map (epic exo-dde, docs/design/room-map.md; mock ui/prototype/room-map.html):
// the room drawn as a graph from coordinate_graph — members inside the room's boundary,
// the outside observers around it, what left drawn crossing it, and every log entry this
// device holds. It computes no state: each node and edge carries the log position it
// appears at, and the timeline replays the room by showing those at or before it.
//
// Self-contained on purpose, so it can move to its own UI module later: it reads only
// `graph` (coordinate_graph), `intents` (coordinate_intents, for words) and `members`
// (coordinate_members, for names), and says what it wants through two signals.
//
// Positions come from roles, never from a random simulation, so the same log draws the
// same picture on every device and nothing jumps while the timeline moves. Colours keep
// the room's language: blue is what left the room (U-2), a member's colour comes from
// their id (MusterStyle.colorFor), and the store node is always drawn (FS-9).
Rectangle {
    id: map
    objectName: "roomMap"

    property var graph: ({})
    property var intents: []
    property var members: []
    property string lens: "room"          // room · me · leaks · prov · log
    property string focusIntent: ""       // the Provenance lens's intent ("" = the latest)
    property string selected: ""
    property int k: seqMax                // the replay position
    property bool following: true         // k follows the end of the log as it grows
    property string crossingsFilter: ""   // Crossings shows one proposal's rows when set
    property int lastSeen: -1             // entries held when this device last closed the map here (-1: never)
    signal openCard(string intentId)
    signal closeRequested()
    signal seen(int count)                // how many entries are held now, for the host to remember
    readonly property int newCount: lastSeen >= 0 ? Math.max(0, replayOrder.length - lastSeen) : 0
    function isNew(n) { return lastSeen >= 0 && n.kind === "entry" && rank(n.seq) >= lastSeen; }

    // The replay runs in causal order: each node's seq is its place in log.causalOrder,
    // the order members published in (the `after` each stamped, exo-655), concurrent
    // entries tied by content id. Entries from clients before causal order carry no
    // `after` and fall back to content-id order among themselves. `rankOf[seq]` is an
    // entry's place among the entries; k is that rank.
    readonly property var replayOrder: {
        var es = [];
        var ns = graph && graph.nodes ? graph.nodes : [];
        for (var i = 0; i < ns.length; i++) if (ns[i].kind === "entry") es.push(ns[i]);
        es.sort(function (a, b) { return a.seq - b.seq; });
        return es;
    }
    readonly property var rankOf: {
        var m = {};
        for (var i = 0; i < replayOrder.length; i++) m[replayOrder[i].seq] = i;
        return m;
    }
    function rank(seq) { return seq < 0 ? -1 : (rankOf[seq] !== undefined ? rankOf[seq] : seq); }
    readonly property int seqMax: replayOrder.length - 1
    readonly property string viewer: graph && graph.viewer ? String(graph.viewer) : ""
    readonly property int readFrom: graph && graph.readFrom !== undefined ? Number(graph.readFrom) : 0
    onSeqMaxChanged: if (following || k > seqMax) k = seqMax

    color: Theme.palette.background

    // ── words ───────────────────────────────────────────────────────────────
    function shortId(s) { s = String(s || ""); return s.length > 12 ? s.slice(0, 6) + "…" + s.slice(-4) : s; }
    function memberName(id) {
        var hex = String(id || "").replace(/^m:/, "");
        for (var i = 0; i < map.members.length; i++) {
            var m = map.members[i];
            if (String(m.identity || "").toLowerCase() === hex) {
                if (m.self) return qsTr("You");
                if (String(m.alias || "").length > 0) return String(m.alias);
            }
        }
        if (hex === map.viewer) return qsTr("You");
        return shortId(hex);
    }
    function intentOf(id) {
        for (var i = 0; i < map.intents.length; i++)
            if (String(map.intents[i].id) === id) return map.intents[i];
        return null;
    }
    function intentWord(id) {
        var it = intentOf(id);
        var k = it && it.summary ? String(it.summary.kind || "") : "";
        var words = { "split": qsTr("Split"), "settle-up": qsTr("Settle up"), "payment": qsTr("Payment"),
                      "transfer": qsTr("Payment"), "statement": qsTr("Statement"), "action": qsTr("Action"),
                      "btc-spend": qsTr("Bitcoin payment"), "lez-call": qsTr("LEZ call") };
        if (words[k]) return words[k];
        return k.length > 0 ? k.charAt(0).toUpperCase() + k.slice(1) : qsTr("Proposal");
    }
    // A proposal's state and approvals as of the replay point: the graph carries each
    // intent's state after each of its entries (the fold over the causal prefix).
    function stepAt(n) {
        var a = n.attrs || {}, st = a.steps || [], cur = null;
        for (var i = 0; i < st.length; i++) if (rank(Number(st[i].seq)) <= map.k) cur = st[i];
        return cur ? cur : { state: String(a.state || ""), approvals: Number(a.approvals || 0) };
    }
    function stateWords(n) {
        var a = n.attrs || {};
        var now = stepAt(n);
        var s = String(now.state || "");
        if (s === "final") return qsTr("Final");
        if (s === "submitted") return qsTr("Submitted");
        if (s === "settling") return qsTr("Settling");
        if (s === "executable") return qsTr("Agreed");
        return qsTr("%1 of %2 agreed").arg(Number(now.approvals || 0)).arg(Number(a.threshold || 0));
    }
    function stateTone(n) {
        var s = String(stepAt(n).state || "");
        return s === "final" || s === "executable" ? "settled" : s === "submitted" || s === "settling" ? "warning" : "waiting";
    }
    readonly property var observerWords: ({
        "o:store-node": [qsTr("Store node"), qsTr("keeps every envelope"),
            qsTr("Every entry reaches the room as a sealed envelope on one topic. The store node keeps them, so it sees when each arrived and which topic it belongs to. It holds no room key and cannot open one.")],
        "o:rpc-provider": [qsTr("RPC provider"), qsTr("each sender's own endpoint"),
            qsTr("The endpoint a member sends through sees that member's signed transaction before the mempool does, and the address it came from. Each member chooses their own.")],
        "o:chain-observer": [qsTr("Chain observer"), qsTr("anyone reading the chain"),
            qsTr("Anyone reading the public ledger. It learns what the driver's manifest declares when the room settles, never before: nothing leaves at propose or approve.")],
        "o:target-module": [qsTr("Target module"), qsTr("the module a call reaches"),
            qsTr("The Logos module an action calls. It sees the call's arguments when the room executes it.")],
        "o:storage-peer": [qsTr("Storage peers"), qsTr("nodes that serve or fetch a file"),
            qsTr("A shared file travels as a sealed blob between members' storage nodes. A node that serves or fetches it sees the other node's address and the sealed bytes, never the file, its name or its key.")],
        "o:storage-dht": [qsTr("Storage network"), qsTr("the DHT that lists providers"),
            qsTr("A node that serves a blob announces it to the storage network, so anyone can see the blob's address and which nodes provide it. Not what it is, nor which room it belongs to.")],
        "o:outside": [qsTr("Outside sources"), qsTr("what the room took in"),
            qsTr("Reads the room took in: a chain's answer, a nonce, a rate, a creditor's own check of a payment. Each is recorded as an external read, so its origin is accountable. It is not proof the world agrees.")]
    })
    function obsWord(id, i) { var w = map.observerWords[id]; return w ? w[i] : id.replace(/^o:/, ""); }
    readonly property var kindWords: ({
        "message": qsTr("message"), "propose": qsTr("proposal"), "policy": qsTr("policy"), "context": qsTr("context"),
        "read": qsTr("outside read"), "sig": qsTr("approval"), "attest": qsTr("commitment"), "binding": qsTr("key binding"),
        "decline": qsTr("decline"), "submit": qsTr("submitted"), "final": qsTr("final"), "admit": qsTr("admission"),
        "material": qsTr("shared material"), "proposer": qsTr("proposer"), "account": qsTr("account"),
        "part-settled": qsTr("paid a part"), "part-confirmed": qsTr("confirmed a part"), "join": qsTr("ceremony join"),
        "open": qsTr("ceremony"), "pmsg1": qsTr("ceremony step"), "pmsg2": qsTr("ceremony step"),
        "file": qsTr("shared file"), "voice": qsTr("voice note")
    })
    // a voice note's two envelopes are each one fixed size, which the store node sees: it
    // marks a voice note, never its length (docs/design/voice-notes.md §10). Up to the replay
    // position, as what the store node learned is: before the first voice entry it has seen none
    readonly property bool holdsVoice: {
        for (var i = 0; i < map.allNodes.length; i++) {
            var n = map.allNodes[i];
            if (n.kind === "entry" && String((n.attrs || {}).kind || "") === "voice" && map.rank(n.seq) <= map.k) return true;
        }
        return false;
    }
    function kindWord(k) { return map.kindWords[k] || String(k || ""); }
    function basisWords(b) {
        return b === "author-signed" ? qsTr("Signed by its author, bound to this room")
             : b === "driver-verified" ? qsTr("Checked by the driver: the signature recovers to a configured signer")
             : b === "key-signed" ? qsTr("Signed by the approving key")
             : qsTr("Sealed to the room; it names no author");
    }
    // the claims registry's credibility classes (docs/design/action-manifest.md §2):
    // imperative — enforced structurally; motivational — someone's conduct, named;
    // exposed — reaches an unbound observer. Classified, never scored.
    function credColor(c) {
        return c === "imperative" ? MusterStyle.settled : c === "motivational" ? MusterStyle.warning
             : c === "exposed" ? MusterStyle.info : Theme.palette.textTertiary;
    }
    function credTone(c) {
        return c === "imperative" ? "settled" : c === "motivational" ? "warning" : c === "exposed" ? "info" : "waiting";
    }
    function credWord(c) {
        return c === "imperative" ? qsTr("Imperative") : c === "motivational" ? qsTr("Motivational")
             : c === "exposed" ? qsTr("Exposed") : qsTr("Nothing promised");
    }
    function clsColor(c) {
        return c === "driver-contribution" ? MusterStyle.settled
             : c === "external-read" ? Theme.palette.textSecondary
             : c === "plugin-block" ? Theme.colors.peach100
             : Theme.palette.textTertiary;
    }

    // ── the graph, as far as the timeline has replayed it ────────────────────
    readonly property var allNodes: graph && graph.nodes ? graph.nodes : []
    // the timeline's ticks: one per entry, or past 400 entries one per bucket of entries
    // (blue if anything in the bucket left the room)
    readonly property var ticks: {
        var n = replayOrder.length, out = [];
        var b = n > 400 ? Math.ceil(n / 400) : 1;
        for (var i = 0; i < n; i += b) {
            var left = false;
            for (var j = i; j < Math.min(n, i + b); j++) if (leftAt[replayOrder[j].seq]) left = true;
            out.push({ at: i, out: left, cls: String((replayOrder[i].attrs || {}).cls || "") });
        }
        return out;
    }
    readonly property var epochBands: {
        var out = [], eps = graph && graph.epochs ? graph.epochs : [];
        for (var i = 0; i < replayOrder.length; i++) {
            var ep = replayOrder[i].epoch;
            if (i < logLo || i > logHi) continue;
            if (out.length > 0 && out[out.length - 1].epoch === ep) continue;
            var who = "";
            for (var j = 0; j < eps.length; j++) if (Number(eps[j].epoch) === ep) who = String(eps[j].admitted || "");
            out.push({ epoch: ep, fromRank: i, admitted: who });
        }
        return out;
    }
    readonly property var allEdges: graph && graph.edges ? graph.edges : []
    readonly property var nodeById: {
        var m = {};
        for (var i = 0; i < allNodes.length; i++) m[allNodes[i].id] = allNodes[i];
        return m;
    }
    // stable orders, over the WHOLE graph, so a position never depends on k
    function idsOfKind(kind) {
        var out = [];
        for (var i = 0; i < allNodes.length; i++) if (allNodes[i].kind === kind) out.push(allNodes[i].id);
        return out;
    }
    readonly property var memberIds: {
        var ids = idsOfKind("member");
        var v = "m:" + viewer;
        var i = ids.indexOf(v);
        if (i > 0) { ids.splice(i, 1); ids.unshift(v); }
        return ids;
    }
    readonly property var intentIds: idsOfKind("intent")
    readonly property var provIntent: {
        if (focusIntent.length > 0 && nodeById["i:" + focusIntent]) return focusIntent;
        for (var i = intentIds.length - 1; i >= 0; i--)
            if (shownAt(nodeById[intentIds[i]])) return intentIds[i].slice(2);
        return "";
    }
    function shownAt(n) { return rank(n.seq) <= map.k; }
    // G7: past logWindow entries the Log lens shows the window around the replay point:
    // as many as stay readable across the stage (about 11 px apart), so a long room never
    // draws thousands of delegates at once and every entry can still be pointed at
    readonly property int logWindow: 80
    readonly property int logLo: replayOrder.length > logWindow ? Math.max(0, Math.min(k - logWindow / 2, replayOrder.length - logWindow)) : 0
    readonly property int logHi: replayOrder.length > logWindow ? logLo + logWindow - 1 : Math.max(0, replayOrder.length - 1)
    // px between neighbouring entries in the Log lens; below ~46 their labels would
    // overlap, so they show only on hover or selection
    readonly property real logPitch: 890 / Math.max(1, logHi - logLo)
    // the log positions where something left the room, for the entry rings and ticks
    readonly property var leftAt: {
        var m = {};
        for (var i = 0; i < allEdges.length; i++) if (allEdges[i].kind === "leaves") m[allEdges[i].seq] = true;
        return m;
    }
    readonly property var visibleNodes: {
        var out = [];
        for (var i = 0; i < allNodes.length; i++) {
            var n = allNodes[i];
            if (!shownAt(n)) continue;
            if (lens === "log") {
                if (n.kind === "entry" && rank(n.seq) >= logLo && rank(n.seq) <= logHi) out.push(n);
                continue;
            }
            if (lens === "prov") {
                if (n.id === "i:" + provIntent) out.push(n);
                else if (n.kind === "entry" && String((n.attrs || {}).intent || "") === provIntent
                         && provRole(n) !== "") out.push(n);
                continue;
            }
            if (n.kind === "entry") continue;
            out.push(n);
        }
        if (readFrom > 0 && (lens === "room" || lens === "me" || lens === "trust" || lens === "leaks"))
            out.push({ id: "sealed", kind: "sealed", seq: -1, epoch: readFrom - 1, attrs: {} });
        if (lens === "prov" && provIntent.length > 0)
            out.push({ id: "bytes", kind: "bytes", seq: -1, epoch: 0, attrs: {} });
        return out;
    }
    readonly property var visibleIds: {
        var m = {};
        for (var i = 0; i < visibleNodes.length; i++) m[visibleNodes[i].id] = true;
        return m;
    }
    function provRole(n) {
        var kd = String((n.attrs || {}).kind || "");
        if (kd === "propose" || kd === "policy" || kd === "context" || kd === "read") return "input";
        if (kd === "sig" || kd === "attest") return "approval";
        if (kd === "submit" || kd === "final" || kd === "part-settled" || kd === "part-confirmed") return "outcome";
        return "";
    }
    readonly property var roomEdgeKinds: ["proposed", "approved", "declined", "part", "disclosed", "joined", "bound", "leaves", "enters"]
    readonly property var visibleEdges: {
        var out = [];
        if (lens === "prov") {
            // the provenance lens draws the same facts through the signed bytes: each input
            // reaches them, each approval is over them, each outcome follows the intent
            for (var j = 0; j < visibleNodes.length; j++) {
                var n = visibleNodes[j];
                if (n.kind !== "entry") continue;
                var role = provRole(n);
                if (role === "input") out.push({ src: n.id, dst: "bytes", kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls } });
                else if (role === "approval") {
                    out.push({ src: "bytes", dst: n.id, kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls } });
                    out.push({ src: n.id, dst: "i:" + provIntent, kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls } });
                } else if (role === "outcome")
                    out.push({ src: "i:" + provIntent, dst: n.id, kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls, out: true } });
            }
            return out;
        }
        for (var i = 0; i < allEdges.length; i++) {
            var e = allEdges[i];
            if (rank(e.seq) > k || !visibleIds[e.src] || !visibleIds[e.dst]) continue;
            if (lens === "log") { if (e.kind === "parent") out.push(e); continue; }
            if (roomEdgeKinds.indexOf(e.kind) >= 0) out.push(e);
        }
        return out;
    }
    // what each outside observer learned, up to k
    function learned(obsId) {
        var fs = [];
        for (var i = 0; i < allEdges.length; i++) {
            var e = allEdges[i];
            if (e.kind !== "leaves" || e.dst !== obsId || rank(e.seq) > k) continue;
            var f = (e.attrs && e.attrs.fields) || [];
            for (var j = 0; j < f.length; j++) if (fs.indexOf(f[j]) < 0) fs.push(f[j]);
        }
        return fs;
    }
    readonly property int heldCount: {
        var c = 0;
        return Math.max(0, Math.min(k + 1, replayOrder.length));
    }

    // ── the Me lens: this device's member, its keys, what it did, what of it left ─
    readonly property var mine: {
        var me = "m:" + viewer, keep = {}, keepE = {};
        keep[me] = true;
        for (var i = 0; i < allEdges.length; i++) {
            var e = allEdges[i];
            if (e.src === me) { keep[e.dst] = true; keepE[i] = true; }
        }
        for (var j = 0; j < allEdges.length; j++) {     // my keys' approvals; what left of mine
            var f = allEdges[j];
            if (keep[f.src] && String(f.src).indexOf("k:") === 0) { keep[f.dst] = true; keepE[j] = true; }
        }
        for (var h = 0; h < allEdges.length; h++) {
            var g = allEdges[h];
            if (g.kind === "leaves" && keep[g.src]) { keep[g.dst] = true; keepE[h] = true; }
        }
        return { nodes: keep };
    }
    function dimmed(id) {
        if (hovered.length > 0) return !(id === hovered || neighbours[id]);
        if (lens === "me") return !mine.nodes[id];
        return false;
    }
    property string hovered: ""
    readonly property var neighbours: {
        var m = {};
        if (hovered.length === 0) return m;
        for (var i = 0; i < visibleEdges.length; i++) {
            var e = visibleEdges[i];
            if (e.src === hovered) m[e.dst] = true;
            if (e.dst === hovered) m[e.src] = true;
        }
        return m;
    }

    // ── layout: deterministic, from roles, in a 1000 × 680 stage ─────────────
    readonly property real cx: lens === "leaks" ? 300 : 470
    readonly property real cy: lens === "leaks" ? 345 : 340
    readonly property real ringR: lens === "leaks" ? 205 : 232
    function polar(deg, r, ox, oy) {
        var a = deg * Math.PI / 180;
        return { x: ox + r * Math.sin(a), y: oy - r * Math.cos(a) };
    }
    function computeLayout() {
        var pos = {}, i, n;
        if (lens === "log") {
            var lanes = { "": 150 }, li = intentIds.length;
            var dy = li > 0 ? Math.min(110, 400 / li) : 0;
            for (i = 0; i < li; i++) lanes[intentIds[i].slice(2)] = 270 + i * dy;
            var span = Math.max(1, logHi - logLo);
            for (i = 0; i < visibleNodes.length; i++) {
                n = visibleNodes[i];
                var kd = String((n.attrs || {}).kind || "");
                var lane = lanes[String((n.attrs || {}).intent || "")];
                if (lane === undefined) lane = 150;
                var drop = (kd === "attest" || kd === "part-confirmed" || kd === "binding") ? 26 : 0;
                pos[n.id] = { x: 60 + (rank(n.seq) - logLo) * 890 / span, y: lane + drop };
            }
            return pos;
        }
        if (lens === "prov") {
            var cols = { input: [], approval: [], outcome: [] };
            for (i = 0; i < visibleNodes.length; i++) {
                n = visibleNodes[i];
                if (n.kind === "entry") cols[provRole(n)].push(n.id);
            }
            function column(ids, x, y0, y1) {
                for (var j = 0; j < ids.length; j++)
                    pos[ids[j]] = { x: x, y: ids.length === 1 ? (y0 + y1) / 2 : y0 + j * (y1 - y0) / (ids.length - 1) };
            }
            column(cols.input, 130, 150, 540);
            pos["bytes"] = { x: 360, y: 340 };
            column(cols.approval, 580, 100, 590);
            pos["i:" + provIntent] = { x: 810, y: cols.outcome.length > 0 ? 250 : 340 };
            column(cols.outcome, 810, 450, 610);
            return pos;
        }
        // room · me · leaks: members on a ring inside the boundary, this device first
        var nm = memberIds.length, scale = lens === "leaks" ? 0.86 : 1;
        for (i = 0; i < nm; i++) pos[memberIds[i]] = polar(230 + i * 360 / Math.max(1, nm), 185 * scale, cx, cy);
        // intents in the middle, on a sunflower spiral: adding one never moves another
        for (i = 0; i < intentIds.length; i++) {
            var r = Math.min(120, 46 * Math.sqrt(i + (intentIds.length > 1 ? 0.6 : 0))) * scale;
            pos[intentIds[i]] = polar(i * 137.5 + 300, r, cx, cy);
        }
        var accIdx = 0, keyIdx = {}, cerIdx = 0;
        for (i = 0; i < allNodes.length; i++) {
            n = allNodes[i];
            if (n.kind === "account" || n.kind === "signer" || n.kind === "ceremony") {
                var anchor = null, onIntent = false;
                for (var e = 0; e < allEdges.length; e++) {
                    var ed = allEdges[e];
                    if (n.kind === "account" && ed.kind === "disclosed" && ed.dst === n.id) { anchor = pos[ed.src]; break; }
                    if (n.kind === "signer" && ed.kind === "bound" && ed.dst === n.id) { anchor = pos[ed.src]; break; }
                    if (n.kind === "signer" && ed.kind === "approved" && ed.src === n.id && !anchor) { anchor = pos[ed.dst]; onIntent = true; }
                }
                if (n.kind === "ceremony") {
                    pos[n.id] = polar(180 + (cerIdx++) * 34, 130 * scale, cx, cy);
                } else if (anchor && onIntent) {
                    var kk = "ring" + String(anchor.x) + String(anchor.y);
                    var nn = keyIdx[kk] = (keyIdx[kk] || 0) + 1;
                    pos[n.id] = map.polar(200 + nn * 40, 66 * scale, anchor.x, anchor.y);
                } else if (anchor) {
                    var dx = anchor.x - cx, dyy = anchor.y - cy;
                    var key = n.kind + String(anchor.x) + String(anchor.y);
                    var nth = keyIdx[key] = (keyIdx[key] || 0) + 1;
                    var f = n.kind === "account" ? 0.55 : 1.18;
                    var ang = Math.atan2(dyy, dx) + (nth - 1) * 0.32 * (nth % 2 ? 1 : -1);
                    var rr = Math.sqrt(dx * dx + dyy * dyy) * f;
                    pos[n.id] = { x: cx + rr * Math.cos(ang), y: cy + rr * Math.sin(ang) };
                } else {
                    pos[n.id] = polar(20 + (accIdx++) * 30, 150 * scale, cx, cy);
                }
            }
        }
        pos["sealed"] = polar(165, 150 * scale, cx, cy);
        if (lens === "leaks") {
            var obs = ["o:store-node", "o:rpc-provider", "o:chain-observer", "o:target-module",
                       "o:storage-peer", "o:storage-dht", "o:outside"], present = [], row = 0;
            for (i = 0; i < obs.length; i++) if (nodeById[obs[i]]) present.push(obs[i]);
            var step = present.length > 1 ? Math.min(135, 560 / (present.length - 1)) : 0;
            for (i = 0; i < present.length; i++) pos[present[i]] = { x: 790, y: 90 + (row++) * step };
        } else {
            pos["o:store-node"] = { x: 470, y: 42 };
            pos["o:rpc-provider"] = { x: 875, y: 230 };
            pos["o:chain-observer"] = { x: 875, y: 450 };
            pos["o:target-module"] = { x: 80, y: 230 };
            pos["o:storage-peer"] = { x: 80, y: 450 };
            pos["o:storage-dht"] = { x: 80, y: 625 };
            pos["o:outside"] = { x: 860, y: 625 };
        }
        // entries out of view sit on their intent, so they open out of it in the Log lens
        for (i = 0; i < allNodes.length; i++) {
            n = allNodes[i];
            if (n.kind === "entry" && !pos[n.id]) {
                var at = pos["i:" + String((n.attrs || {}).intent || "")];
                pos[n.id] = at ? at : { x: cx, y: cy };
            }
        }
        return pos;
    }
    property var fromPos: ({})
    property var toPos: ({})
    property real t: 1
    function posOf(id) {
        var tt = map.t, b = map.toPos[id], a = map.fromPos[id] || b;
        if (!b) return { x: map.cx, y: map.cy };
        return { x: a.x + (b.x - a.x) * tt, y: a.y + (b.y - a.y) * tt };
    }
    function relayout() {
        var cur = {}, ids = Object.keys(map.toPos);
        for (var i = 0; i < ids.length; i++) cur[ids[i]] = posOf(ids[i]);
        map.fromPos = cur;
        map.toPos = computeLayout();
        tween.restart();
    }
    NumberAnimation { id: tween; target: map; property: "t"; from: 0; to: 1; duration: 520; easing.type: Easing.OutCubic }
    onVisibleNodesChanged: relayoutLater.restart()
    Timer { id: relayoutLater; interval: 0; onTriggered: map.relayout() }
    Component.onCompleted: { map.toPos = computeLayout(); map.fromPos = map.toPos; }

    property real flowPhase
    NumberAnimation on flowPhase { from: 0; to: -20; duration: 1100; loops: Animation.Infinite; running: map.visible }

    // ── header ──────────────────────────────────────────────────────────────
    RowLayout {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.spacing.medium }
        spacing: Theme.spacing.medium
        ColumnLayout {
            spacing: 2
            LogosText {
                text: qsTr("Room map")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.subtitle
                font.weight: Theme.typography.weightBold
            }
            LogosText {
                objectName: "roomMapNewSince"
                visible: map.newCount > 0
                text: qsTr("%n new since you last looked", "", map.newCount)
                color: MusterStyle.needsText
                font.pixelSize: MusterStyle.caption
                font.weight: Theme.typography.weightBold
                TapHandler {
                    onTapped: { map.following = false; map.k = Math.max(0, map.lastSeen - 1); player.start(); }
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
            LogosText {
                text: qsTr("%n entries you can open", "", map.replayOrder.length)
                      + (map.readFrom > 0 ? qsTr(" · from epoch %1, when you joined").arg(map.readFrom) : "")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
        }
        Item { Layout.fillWidth: true }
        Repeater {
            model: [["room", qsTr("Room")], ["me", qsTr("Me")], ["trust", qsTr("Trust")], ["leaks", qsTr("Where it left")],
                    ["crossings", qsTr("Crossings")], ["prov", qsTr("Provenance")], ["log", qsTr("Log")]]
            delegate: ActionButton {
                required property var modelData
                objectName: "roomMapLens_" + modelData[0]
                compact: true
                quiet: map.lens !== modelData[0]
                text: modelData[1]
                onClicked: map.lens = modelData[0]
            }
        }
        IconAction {
            objectName: "roomMapClose"
            label: qsTr("Close the room map")
            icon: LogosIcons.close
            onClicked: map.closeRequested()
        }
    }

    // ── the stage ───────────────────────────────────────────────────────────
    Item {
        id: viewport
        anchors { left: parent.left; right: inspector.left; top: header.bottom; bottom: timeline.top; margins: Theme.spacing.small }
        clip: true
        MouseArea { anchors.fill: parent; onClicked: map.selected = "" }

        Item {
            id: stage
            visible: map.lens !== "crossings"
            width: 1000; height: 680
            anchors.centerIn: parent
            scale: Math.min(viewport.width / 1000, viewport.height / 680)

            // the room's boundary: the conversation is the security boundary
            Shape {
                id: membrane
                anchors.fill: parent
                opacity: (map.lens === "room" || map.lens === "me" || map.lens === "trust" || map.lens === "leaks") ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 300 } }
                ShapePath {
                    strokeColor: MusterStyle.tint(Theme.palette.primary, 0.45)
                    strokeWidth: 1.5
                    fillGradient: RadialGradient {
                        centerX: map.cx; centerY: map.cy; centerRadius: map.ringR
                        focalX: map.cx; focalY: map.cy
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.8; color: MusterStyle.tint(Theme.palette.primary, 0.05) }
                        GradientStop { position: 1.0; color: MusterStyle.tint(Theme.palette.primary, 0.13) }
                    }
                    PathAngleArc { centerX: map.cx; centerY: map.cy; radiusX: map.ringR; radiusY: map.ringR; startAngle: 0; sweepAngle: 360 }
                }
            }
            LogosText {
                visible: membrane.opacity > 0.5
                x: map.cx - width / 2
                y: map.cy - map.ringR - height - 4
                text: qsTr("the room · end-to-end · %n can read", "", map.memberIds.length)
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.badge
                font.family: MusterStyle.mono
            }
            // every envelope reaches the store node (FS-9): strands from the boundary
            Repeater {
                model: (membrane.opacity > 0.5 && map.visibleIds["o:store-node"]) ? [-2, -1, 0, 1, 2] : []
                delegate: Shape {
                    required property int modelData
                    anchors.fill: parent
                    readonly property var a: map.polar(modelData * 14, map.ringR, map.cx, map.cy)
                    readonly property var b: map.posOf("o:store-node")
                    ShapePath {
                        strokeColor: MusterStyle.tint(Theme.palette.warning, 0.4)
                        strokeWidth: Math.max(0.6, Math.log(map.heldCount + 1) * 0.5)
                        fillColor: "transparent"
                        startX: a.x; startY: a.y
                        PathCubic { x: b.x + modelData * 6; y: b.y + 22; control1X: a.x; control1Y: a.y - 40; control2X: b.x + modelData * 6; control2Y: b.y + 60 }
                    }
                }
            }
            // which part of a long log the Log lens shows
            LogosText {
                objectName: "roomMapLogWindow"
                visible: map.lens === "log" && map.replayOrder.length > map.logWindow
                x: 48; y: 46
                text: qsTr("Entries %1–%2 of %3, around the replay point · drag the timeline to move")
                      .arg(map.logLo + 1).arg(map.logHi + 1).arg(map.replayOrder.length)
                color: Theme.palette.textSecondary; font.pixelSize: MusterStyle.badge
            }
            // epoch bands behind the Log lens
            Repeater {
                model: map.lens === "log" ? map.epochBands : []
                delegate: Item {
                    required property var modelData
                    required property int index
                    readonly property real x0: 60 + Math.max(0, Number(modelData.fromRank) - map.logLo) * 890 / Math.max(1, map.logHi - map.logLo) - 12
                    x: x0; y: 70; width: 1000 - x0; height: 560
                    Rectangle { anchors.fill: parent; color: index % 2 ? MusterStyle.neutralSoft : "transparent"; opacity: 0.5 }
                    Rectangle { width: 1; height: parent.height; color: Theme.palette.borderSubtle }
                    LogosText {
                        x: 8; y: 6 + (index % 2) * 14
                        text: String(modelData.admitted || "").length === 0 ? qsTr("epoch %1").arg(modelData.epoch)
                                          : qsTr("epoch %1 · %2 admitted").arg(modelData.epoch).arg(map.memberName(modelData.admitted))
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.badge
                        font.family: MusterStyle.mono
                    }
                }
            }

            // edges
            Repeater {
                model: map.visibleEdges
                delegate: Shape {
                    id: edge
                    required property var modelData
                    anchors.fill: parent
                    readonly property string kind: modelData.kind
                    readonly property var a: map.posOf(modelData.src)
                    readonly property var b: map.posOf(modelData.dst)
                    readonly property real len: Math.max(1, Math.hypot(b.x - a.x, b.y - a.y))
                    readonly property real ra: map.radiusOf(modelData.src) + 3
                    readonly property real rb: map.radiusOf(modelData.dst) + 3
                    readonly property real sx: a.x + (b.x - a.x) * ra / len
                    readonly property real sy: a.y + (b.y - a.y) * ra / len
                    readonly property real tx: b.x - (b.x - a.x) * rb / len
                    readonly property real ty: b.y - (b.y - a.y) * rb / len
                    // connections between the same two nodes bend apart by kind, so each stays visible
                    readonly property real bend: kind === "prov" ? 0 : kind === "parent" ? 0.12
                        : kind === "part" ? -0.2 : kind === "proposed" ? 0.3 : kind === "declined" ? -0.34 : 0.13
                    readonly property bool hot: map.hovered.length > 0 && (modelData.src === map.hovered || modelData.dst === map.hovered)
                    opacity: map.hovered.length > 0 ? (hot ? 1 : 0.08)
                           : (map.lens === "me" && (map.dimmed(modelData.src) || map.dimmed(modelData.dst))) ? 0.08 : 1
                    readonly property string cred: modelData.attrs && modelData.attrs.credibility ? String(modelData.attrs.credibility) : ""
                    readonly property color ink: map.lens === "trust" ? map.credColor(cred)
                        : kind === "leaves" ? MusterStyle.info
                        : kind === "enters" ? Theme.palette.textSecondary
                        : kind === "parent" ? Theme.palette.textTertiary
                        : kind === "prov" ? (modelData.attrs && modelData.attrs.out ? MusterStyle.info : map.clsColor(modelData.attrs ? modelData.attrs.cls : ""))
                        : kind === "bound" ? Theme.palette.text
                        : (String(modelData.src).indexOf("m:") === 0 ? MusterStyle.colorFor(String(modelData.src).slice(2)) : Theme.palette.textSecondary)
                    ShapePath {
                        strokeColor: edge.ink
                        strokeWidth: edge.kind === "leaves" ? 1.6 + Math.min(4, ((edge.modelData.attrs && edge.modelData.attrs.fields) || []).length * 0.35)
                                   : edge.kind === "parent" ? 1 : edge.kind === "approved" || edge.kind === "part" ? 1.2 : 1.6
                        strokeStyle: map.lens === "trust" ? (edge.cred === "imperative" ? ShapePath.SolidLine : ShapePath.DashLine)
                                   : (edge.kind === "leaves" || edge.kind === "enters" || edge.kind === "disclosed" || edge.kind === "bound")
                                     ? ShapePath.DashLine : ShapePath.SolidLine
                        dashPattern: map.lens === "trust" ? (edge.cred === "exposed" ? [1.5, 3.5] : [4, 3])
                                   : edge.kind === "leaves" ? [1.5, 3.5] : edge.kind === "enters" ? [3, 2.5] : [0.8, 2.5]
                        dashOffset: edge.kind === "leaves" ? map.flowPhase / 2 : edge.kind === "enters" ? map.flowPhase / 3 : 0
                        capStyle: ShapePath.RoundCap
                        fillColor: "transparent"
                        startX: edge.sx; startY: edge.sy
                        PathCubic {
                            x: edge.tx; y: edge.ty
                            control1X: edge.kind === "prov" ? (edge.sx + edge.tx) / 2 : (edge.sx + edge.tx) / 2 - (edge.ty - edge.sy) * edge.bend
                            control1Y: edge.kind === "prov" ? edge.sy : (edge.sy + edge.ty) / 2 + (edge.tx - edge.sx) * edge.bend
                            control2X: edge.kind === "prov" ? (edge.sx + edge.tx) / 2 : control1X
                            control2Y: edge.kind === "prov" ? edge.ty : control1Y
                        }
                    }
                }
            }

            // nodes
            Repeater {
                model: map.visibleNodes
                delegate: Item {
                    id: node
                    required property var modelData
                    readonly property string kind: modelData.kind
                    readonly property var p: map.posOf(modelData.id)
                    readonly property real r: map.radiusOf(modelData.id)
                    objectName: "roomMapNode_" + modelData.id
                    x: p.x; y: p.y
                    width: 1; height: 1
                    opacity: map.dimmed(modelData.id) ? 0.18 : 1
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    MouseArea {
                        x: -node.r - 6; y: -node.r - 6; width: 2 * node.r + 12; height: 2 * node.r + 12
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: map.hovered = node.modelData.id
                        onExited: if (map.hovered === node.modelData.id) map.hovered = ""
                        onClicked: {
                            map.selected = map.selected === node.modelData.id ? "" : node.modelData.id;
                            if (node.kind === "intent") map.focusIntent = node.modelData.id.slice(2);
                        }
                    }
                    Rectangle {     // selection ring
                        visible: map.selected === node.modelData.id
                        x: -node.r - 6; y: -node.r - 6; width: 2 * node.r + 12; height: width
                        radius: node.kind === "observer" || node.kind === "outside" || node.kind === "bytes" ? 12 : width / 2
                        color: "transparent"; border.color: Theme.palette.focus; border.width: 2
                    }

                    // a member
                    Loader {
                        active: node.kind === "member"
                        sourceComponent: Item {
                            readonly property string hex: node.modelData.id.slice(2)
                            readonly property bool self: hex === map.viewer
                            Rectangle {
                                visible: parent.self
                                x: -27; y: -27; width: 54; height: 54; radius: 27
                                color: "transparent"; border.color: MusterStyle.colorFor(parent.hex); border.width: 1.5
                            }
                            Avatar { x: -22; y: -22; size: 44; identity: parent.hex; name: map.memberName(node.modelData.id) }
                            LogosText {
                                x: -width / 2; y: 28
                                text: map.memberName(node.modelData.id) + (parent.self ? qsTr(" (this device)") : "")
                                color: Theme.palette.text; font.pixelSize: MusterStyle.caption
                            }
                            LogosText {
                                x: -width / 2; y: 44
                                readonly property int joined: Number((node.modelData.attrs || {}).joined)
                                text: joined >= 0 ? qsTr("joined epoch %1").arg(joined) : ""
                                color: Theme.palette.textTertiary; font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                            }
                        }
                    }
                    // a proposal
                    Loader {
                        active: node.kind === "intent"
                        sourceComponent: Item {
                            readonly property var a: node.modelData.attrs || {}
                            readonly property string st: String(map.stepAt(node.modelData).state || "")
                            readonly property color ring: st === "final" || st === "executable" ? MusterStyle.settled
                                                        : st === "submitted" || st === "settling" ? MusterStyle.warning : MusterStyle.info
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width; radius: node.r
                                color: Theme.palette.surfaceRaised
                                border.color: parent.ring; border.width: parent.st === "final" ? 3 : 1.6
                            }
                            Repeater {      // the threshold, one slot per needed approval, filled as they land
                                model: Math.max(1, Number(parent.a.threshold || 1))
                                delegate: Rectangle {
                                    required property int index
                                    readonly property int n: Math.max(1, Number(node.modelData.attrs.threshold || 1))
                                    readonly property var at: map.polar(n === 1 ? 0 : -60 + index * 120 / (n - 1), node.r + 9, 0, 0)
                                    x: at.x - 4.5; y: at.y - 4.5; width: 9; height: 9; radius: 4.5
                                    color: index < Number(map.stepAt(node.modelData).approvals || 0) ? MusterStyle.settled : Theme.palette.background
                                    border.color: MusterStyle.settled; border.width: 1
                                }
                            }
                            LogosText {
                                x: -width / 2; y: -height / 2 - 2
                                width: Math.min(implicitWidth, 2 * node.r - 10)
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                text: map.intentWord(node.modelData.id.slice(2))
                                color: Theme.palette.text; font.pixelSize: MusterStyle.caption
                                font.weight: Theme.typography.weightBold
                            }
                            StatusPill {
                                x: -width / 2; y: node.r + 16
                                text: map.stateWords(node.modelData)
                                tone: map.stateTone(node.modelData)
                            }
                        }
                    }
                    // an account, a signer key, a ceremony
                    Loader {
                        active: node.kind === "account" || node.kind === "signer" || node.kind === "ceremony"
                        sourceComponent: Item {
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width
                                rotation: node.kind === "account" ? 45 : 0
                                radius: node.kind === "ceremony" ? node.r : 3
                                color: Theme.palette.surfaceRaised
                                border.color: node.kind === "signer" ? Theme.palette.text : Theme.palette.textSecondary
                                border.width: 1.2
                            }
                            LogosText {
                                x: -width / 2; y: node.r + 6
                                text: node.kind === "account" ? String((node.modelData.attrs || {}).family || qsTr("account"))
                                    : node.kind === "signer" ? qsTr("key %1").arg(map.shortId(node.modelData.id.slice(2)))
                                    : qsTr("key ceremony")
                                color: Theme.palette.textSecondary; font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                            }
                        }
                    }
                    // an outside observer
                    Loader {
                        active: node.kind === "observer" || node.kind === "outside"
                        sourceComponent: Item {
                            readonly property bool big: map.lens === "leaks"
                            readonly property var fields: node.kind === "observer" && node.modelData.id !== "o:store-node"
                                                         ? map.learned(node.modelData.id)
                                                         : node.modelData.id === "o:store-node"
                                                           ? (map.holdsVoice ? [qsTr("timing"), qsTr("topic"), qsTr("one fixed size")]
                                                                             : [qsTr("timing"), qsTr("topic")]) : []
                            readonly property real w: big ? 210 : 150
                            readonly property real h: big ? 64 + fieldText.implicitHeight : 46
                            Rectangle {
                                x: -parent.w / 2; y: -parent.h / 2; width: parent.w; height: parent.h; radius: 9
                                color: Theme.palette.background
                                border.width: 1.3
                                border.color: node.modelData.id === "o:store-node" ? Theme.palette.warning
                                            : node.kind === "outside" ? Theme.palette.textSecondary
                                            : parent.fields.length > 0 ? MusterStyle.info : Theme.palette.border
                            }
                            LogosText {
                                x: -width / 2; y: -parent.h / 2 + 6
                                text: map.obsWord(node.modelData.id, 0)
                                color: Theme.palette.text; font.pixelSize: MusterStyle.caption
                            }
                            LogosText {
                                x: -width / 2; y: -parent.h / 2 + 22
                                text: map.obsWord(node.modelData.id, 1)
                                color: Theme.palette.textTertiary; font.pixelSize: MusterStyle.badge
                            }
                            LogosText {
                                id: fieldText
                                objectName: "roomMapFields_" + node.modelData.id
                                visible: parent.big
                                x: -parent.w / 2 + 10; y: -parent.h / 2 + 42
                                width: parent.w - 20
                                wrapMode: Text.Wrap
                                horizontalAlignment: Text.AlignHCenter
                                text: node.kind === "outside" ? qsTr("took in; learned nothing from the room")
                                    : parent.fields.length > 0 ? parent.fields.join(", ") : qsTr("nothing yet")
                                color: parent.fields.length > 0 ? Theme.palette.text : Theme.palette.textTertiary
                                font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                            }
                        }
                    }
                    // a log entry
                    Loader {
                        active: node.kind === "entry"
                        sourceComponent: Item {
                            readonly property var a: node.modelData.attrs || {}
                            readonly property bool wentOut: map.entryLeft(node.modelData)
                            Rectangle {      // new since this device last looked
                                visible: map.isNew(node.modelData)
                                x: node.r - 2; y: -node.r - 4; width: 6; height: 6; radius: 3
                                color: MusterStyle.needs
                            }
                            Rectangle {
                                visible: parent.wentOut
                                x: -node.r - 4; y: -node.r - 4; width: 2 * node.r + 8; height: width; radius: width / 2
                                color: "transparent"; border.color: MusterStyle.info; border.width: 1.2
                            }
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width; radius: node.r
                                color: map.clsColor(String(parent.a.cls || ""))
                                opacity: parent.a.counted ? 1 : 0.35
                                border.width: parent.a.account ? 2 : 0
                                border.color: parent.a.account && String(parent.a.account).indexOf("m:") === 0
                                              ? MusterStyle.colorFor(String(parent.a.account).slice(2)) : Theme.palette.text
                            }
                            LogosText {
                                readonly property bool below: map.lens === "prov" || node.modelData.seq % 2 === 0
                                visible: map.lens !== "log" || map.logPitch >= 46
                                         || map.hovered === node.modelData.id || map.selected === node.modelData.id
                                x: -width / 2; y: below ? node.r + 3 : -node.r - height - 3
                                text: (String(parent.a.kind) === "message" && parent.a.content && parent.a.content.body !== undefined
                                       ? "“" + map.snippet(map.messageText(parent.a.content.body), 18) + "”" : map.kindWord(String(parent.a.kind || "")))
                                      + (map.lens === "prov" && parent.a.account ? " · " + map.actorName(parent.a.account) : "")
                                color: Theme.palette.textSecondary; font.pixelSize: map.lens === "prov" ? MusterStyle.caption : 9
                            }
                        }
                    }
                    // before you joined
                    Loader {
                        active: node.kind === "sealed"
                        sourceComponent: Item {
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width; radius: node.r
                                color: Theme.palette.surfaceRecessed
                                border.color: Theme.palette.border; border.width: 1
                                LogosIcon { anchors.centerIn: parent; width: 18; height: 18; source: MusterStyle.icon("lock"); color: Theme.palette.textTertiary }
                            }
                            LogosText {
                                x: -width / 2; y: node.r + 6
                                text: qsTr("Before you joined: sealed to you")
                                color: Theme.palette.textSecondary; font.pixelSize: MusterStyle.badge
                            }
                        }
                    }
                    // the signed bytes (Provenance)
                    Loader {
                        active: node.kind === "bytes"
                        sourceComponent: Item {
                            Rectangle {
                                x: -70; y: -42; width: 140; height: 84; radius: 9
                                color: Theme.palette.background; border.color: MusterStyle.settled; border.width: 1.4
                            }
                            Column {
                                anchors.centerIn: parent
                                spacing: 2
                                LogosText { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("Signed bytes"); color: Theme.palette.text; font.pixelSize: MusterStyle.caption }
                                LogosText { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("materialization + P"); color: Theme.palette.textTertiary; font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono }
                                LogosText { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("re-derived on each device"); color: MusterStyle.settled; font.pixelSize: MusterStyle.badge }
                            }
                        }
                    }
                }
            }
        }

        // ── Crossings: every time information crossed the room's boundary, in order ──
        ListView {
            id: crossingsList
            objectName: "roomMapCrossings"
            visible: map.lens === "crossings"
            anchors.fill: parent
            anchors.margins: Theme.spacing.small
            clip: true
            spacing: 2
            model: map.crossings
            header: ColumnLayout {
                width: crossingsList.width
                spacing: 4
                Rectangle {
                    objectName: "roomMapCrossingsChip"
                    visible: map.crossingsFilter.length > 0
                    Layout.fillWidth: true
                    implicitHeight: chipRow.implicitHeight + 2 * Theme.spacing.small
                    radius: Theme.spacing.radiusLarge
                    color: MusterStyle.needsSoft
                    RowLayout {
                        id: chipRow
                        anchors { fill: parent; leftMargin: Theme.spacing.medium; rightMargin: Theme.spacing.tiny }
                        LogosText {
                            Layout.fillWidth: true
                            text: qsTr("Showing one proposal: %1").arg(map.intentWord(map.crossingsFilter))
                            color: MusterStyle.needsText
                            font.pixelSize: MusterStyle.caption; font.weight: Theme.typography.weightBold
                        }
                        IconAction {
                            size: 24
                            label: qsTr("Show the whole room")
                            icon: LogosIcons.close
                            onClicked: map.crossingsFilter = ""
                        }
                    }
                }
                LogosText {
                    text: qsTr("What crossed the room's boundary")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.subtitle
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    objectName: "roomMapCrossingsSummary"
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    text: qsTr("Out: %1 · In: %2 · Joined: %3 — up to the replay point, in the order members saw them. Select a row to see the entry that caused it.")
                          .arg(map.crossingCount("out")).arg(map.crossingCount("in")).arg(map.crossingCount("join"))
                }
                Item { implicitHeight: Theme.spacing.small }
            }
            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property bool reached: modelData.seq < 0 || map.rank(modelData.seq) <= map.k
                readonly property string dir: String(modelData.dir || "")
                width: crossingsList.width
                implicitHeight: rowCol.implicitHeight + 2 * Theme.spacing.small
                radius: 8
                opacity: reached ? 1 : 0.35
                color: map.selected.length > 0 && map.selected === String(modelData.entry || "") ? MusterStyle.needsSoft
                     : dir === "out" ? MusterStyle.infoSoft : MusterStyle.neutralSoft
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (String(row.modelData.entry || "").length > 0) map.selected = String(row.modelData.entry)
                }
                RowLayout {
                    anchors { fill: parent; margins: Theme.spacing.small }
                    spacing: Theme.spacing.medium
                    LogosText {
                        Layout.preferredWidth: 44
                        Layout.alignment: Qt.AlignTop
                        text: row.modelData.seq < 0 ? qsTr("all") : "#" + (map.rank(row.modelData.seq) + 1)
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption; font.family: MusterStyle.mono
                    }
                    LogosText {
                        Layout.preferredWidth: 46
                        Layout.alignment: Qt.AlignTop
                        text: row.dir === "out" ? qsTr("OUT →") : row.dir === "join" ? qsTr("JOIN +") : qsTr("IN ←")
                        color: row.dir === "out" ? MusterStyle.infoText : row.dir === "join" ? MusterStyle.settled : Theme.palette.text
                        font.pixelSize: MusterStyle.caption; font.weight: Theme.typography.weightBold
                    }
                    ColumnLayout {
                        id: rowCol
                        Layout.fillWidth: true
                        spacing: 2
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: map.crossingTitle(row.modelData)
                            color: Theme.palette.text
                            font.pixelSize: MusterStyle.body
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: String(row.modelData.mechanism || "")
                            color: Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                        }
                    }
                    StatusPill {
                        Layout.alignment: Qt.AlignTop
                        text: map.credWord(String(row.modelData.credibility || ""))
                              + (String(row.modelData.party || "").length > 0 ? " · " + String(row.modelData.party) : "")
                        tone: map.credTone(String(row.modelData.credibility || ""))
                    }
                }
            }
        }

        LogosText {
            anchors { left: parent.left; bottom: parent.bottom; margins: Theme.spacing.small }
            width: Math.min(parent.width - 2 * Theme.spacing.small, 520)
            wrapMode: Text.Wrap
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
            visible: map.lens !== "crossings"
            text: map.lens === "me" ? qsTr("You, the keys bound to you, the proposals you took part in, and what of them left the room. Everything else is dimmed.")
                : map.lens === "trust" ? qsTr("Green is imperative: enforced by the code. Amber dashes are motivational: someone's word or conduct, named in the panel. Blue dots are exposed: seen by someone outside.")
                : map.lens === "leaks" ? qsTr("Each outside observer, and exactly the fields it learned, placed at the entry where they left.")
                : map.lens === "prov" ? (map.provIntent.length > 0 ? qsTr("Every input that reached the signed bytes, then the approvals over them. Select a proposal to trace another.")
                                                                   : qsTr("No proposal yet. Provenance traces one proposal's inputs."))
                : map.lens === "log" ? qsTr("Every entry you can open, in the order members saw them; lines are the hash links to what each depends on.")
                : qsTr("Members and what they decided sit inside the boundary. Blue carries information out; grey dashes bring outside reads in.")
        }
    }
    // An entry's or effect's content as inspector rows: short values as rows, long ones
    // (signatures, hashes, links) selectable in full
    function valueText(v) {
        if (v === null || v === undefined) return "";
        if (typeof v === "object") return JSON.stringify(v);
        return String(v);
    }
    function addContent(d, obj, skip) {
        if (!obj || typeof obj !== "object") return;
        for (var k in obj) {
            if (skip && skip.indexOf(k) >= 0) continue;
            var t = valueText(obj[k]);
            if (t.length === 0) continue;
            if (t.length > 64) d.copyable.push([k, t]);
            else d.rows.push([k, t, /^0x[0-9a-fA-F]+$|^[0-9a-f]{16,}$/.test(t) ? "mono" : ""]);
        }
    }
    // a message's words: a card (a JSON body) reads as its text, or as the card it is
    function messageText(body) {
        var b = String(body || "");
        if (b.charAt(0) === "{") {
            try {
                var c = JSON.parse(b);
                if (c.text) return String(c.text);
                if (c.kind) return qsTr("a %1 card").arg(String(c.kind));
            } catch (e) {}
        }
        return b;
    }
    function snippet(t, n) { t = String(t || ""); return t.length > n ? t.slice(0, n - 1) + "…" : t; }
    function linkText(e) {
        var who = actorName(e.src), what = String(e.dst).indexOf("i:") === 0 ? intentWord(String(e.dst).slice(2)) : actorName(e.dst);
        switch (e.kind) {
        case "proposed": return qsTr("%1 proposed %2").arg(who).arg(what);
        case "approved": return qsTr("%1 approved %2").arg(who).arg(what);
        case "declined": return qsTr("%1 declined %2").arg(who).arg(what);
        case "part": return (String((e.attrs || {}).step) === "settled" ? qsTr("%1 reported paying a part of %2") : qsTr("%1 confirmed a part of %2")).arg(who).arg(what);
        case "disclosed": return qsTr("%1 disclosed %2").arg(who).arg(String(e.dst).slice(2));
        case "joined": return qsTr("%1 joined a key ceremony").arg(who);
        case "bound": return qsTr("%1's approval key %2").arg(who).arg(shortId(String(e.dst).slice(2)));
        case "leaves": return qsTr("%1 learned %2").arg(obsWord(e.dst, 0)).arg(((e.attrs || {}).fields || []).join(", "));
        case "enters": return qsTr("an outside read into %1").arg(what);
        }
        return e.kind;
    }
    readonly property var allCrossings: graph && graph.crossings ? graph.crossings : []
    readonly property var crossings: {
        if (crossingsFilter.length === 0) return allCrossings;
        var out = [];
        for (var i = 0; i < allCrossings.length; i++)
            if (String(allCrossings[i].intent || "") === crossingsFilter) out.push(allCrossings[i]);
        return out;
    }
    // compare another member's fingerprint with the ones this device holds
    function compareFingerprint(text) {
        var t = String(text || "").toLowerCase().replace(/[^0-9a-f]/g, "");
        if (t.length < 16) return { state: "short", epoch: -1 };
        var fps = (graph || {}).fingerprints || [];
        for (var i = 0; i < fps.length; i++)
            if (String(fps[i].digest).indexOf(t) === 0) return { state: "match", epoch: Number(fps[i].fromEpoch) };
        return { state: "differs", epoch: -1 };
    }
    function crossingCount(dir) {
        var c = 0;
        for (var i = 0; i < crossings.length; i++) {
            var x = crossings[i];
            if (String(x.dir) === dir && x.seq >= 0 && rank(x.seq) <= k) c++;
        }
        return c;
    }
    function crossingTitle(x) {
        var dir = String(x.dir || ""), kd = String(x.kind || "");
        var fields = (x.fields || []).join(", ");
        var intent = String(x.intent || "").length > 0 ? intentWord(String(x.intent)) : "";
        if (dir === "out" && kd === "envelopes")
            return qsTr("%1 of every entry → %2 (%n envelopes so far)", "", heldCount).arg(fields).arg(obsWord(String(x.observer), 0));
        if (dir === "out") {
            var vals = [], vs = x.values || {};
            for (var vk in vs) vals.push(vk + " " + snippet(valueText(vs[vk]), 26));
            if (String(x.chainRef || "").length > 0 && String(x.chainRef) !== "1") vals.push(qsTr("tx %1").arg(shortId(String(x.chainRef))));
            return qsTr("%1 → %2, when %3 settled").arg(fields).arg(obsWord(String(x.observer), 0)).arg(intent)
                   + (vals.length > 0 ? " · " + vals.join(", ") : "");
        }
        if (dir === "join")
            return qsTr("%1 joined at epoch %2").arg(memberName(String(x.member || ""))).arg(x.epoch);
        if (kd === "read") return qsTr("%1 → %2: an outside read").arg(String(x.source || qsTr("a source"))).arg(intent);
        if (kd === "final") return qsTr("the chain's answer → %1: it settled").arg(intent);
        if (kd === "part-confirmed") return qsTr("the counterparty's read → %1: a part arrived").arg(intent);
        if (kd === "account") return qsTr("%1 brought an account into the room").arg(actorName(String(x.member || "")));
        if (kd === "material") return qsTr("%1 shared material for %2").arg(actorName(String(x.member || ""))).arg(intent);
        return kd;
    }
    function radiusOf(id) {
        var n = id === "sealed" ? { kind: "sealed" } : id === "bytes" ? { kind: "bytes" } : nodeById[id];
        if (!n) return 10;
        switch (n.kind) {
        case "member": return 24;
        case "intent": return 40;
        case "observer": case "outside": return map.lens === "leaks" ? 64 : 30;
        case "account": return 13;
        case "signer": return 9;
        case "ceremony": return 12;
        case "sealed": return 34;
        case "bytes": return 58;
        case "entry": return map.lens === "prov" ? 12 : map.lens === "log" ? Math.max(3, Math.min(7, map.logPitch * 0.38)) : 7;
        }
        return 10;
    }
    function entryLeft(n) { return map.leftAt[n.seq] === true; }
    function actorName(id) {
        id = String(id || "");
        if (id.indexOf("m:") === 0) return memberName(id);
        if (id.indexOf("k:") === 0) return qsTr("key %1").arg(shortId(id.slice(2)));
        return shortId(id);
    }

    // ── the inspector ──────────────────────────────────────────────────────
    Rectangle {
        id: inspector
        objectName: "roomMapInspector"
        anchors { right: parent.right; top: header.bottom; bottom: timeline.top; margins: Theme.spacing.small }
        width: Math.min(320, map.width * 0.34)
        radius: 10
        color: Theme.palette.surfaceRaised
        border.color: Theme.palette.borderSubtle

        readonly property var n: map.selected === "sealed" ? { id: "sealed", kind: "sealed", attrs: {} }
                               : map.selected === "bytes" ? { id: "bytes", kind: "bytes", attrs: {} }
                               : map.selected.length > 0 ? map.nodeById[map.selected] || null
                               : map.lens === "me" ? map.nodeById["m:" + map.viewer] || null : null
        readonly property var info: map.describe(n)

        Flickable {
            anchors.fill: parent
            anchors.margins: Theme.spacing.medium
            contentHeight: col.implicitHeight
            clip: true
            ColumnLayout {
                id: col
                width: parent.width
                spacing: Theme.spacing.small
                LogosText {
                    text: inspector.info.kicker
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                }
                LogosText {
                    objectName: "roomMapInspectorTitle"
                    Layout.fillWidth: true
                    text: inspector.info.title
                    wrapMode: Text.Wrap
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.subtitle
                    font.weight: Theme.typography.weightBold
                }
                StatusPill { visible: inspector.info.pill.length > 0; text: inspector.info.pill; tone: inspector.info.tone }
                LogosText {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: inspector.info.lead
                    wrapMode: Text.Wrap
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.body
                }
                Repeater {
                    model: inspector.info.rows
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            Layout.preferredWidth: 120
                            Layout.maximumWidth: 120
                            Layout.alignment: Qt.AlignTop
                            wrapMode: Text.Wrap
                            text: modelData[0]
                            color: Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                        }
                        LogosText {
                            objectName: "roomMapRow_" + modelData[0]
                            Layout.fillWidth: true
                            text: modelData[1]
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            color: modelData.length > 2 && modelData[2] === "out" ? MusterStyle.infoText : Theme.palette.text
                            font.pixelSize: MusterStyle.caption
                            font.family: modelData.length > 2 && modelData[2] === "mono" ? MusterStyle.mono : Theme.typography.publicSans
                        }
                    }
                }
                Rectangle {
                    visible: inspector.info.guarantee.length > 0
                    Layout.fillWidth: true
                    implicitHeight: guarantee.implicitHeight + 2 * Theme.spacing.small
                    radius: 6
                    color: MusterStyle.settledSoft
                    LogosText {
                        id: guarantee
                        anchors { fill: parent; margins: Theme.spacing.small }
                        text: inspector.info.guarantee
                        wrapMode: Text.Wrap
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.caption
                    }
                }
                // what each guarantee is, against whom, and how (imperative / motivational / exposed)
                LogosText {
                    visible: inspector.info.facets.length > 0
                    text: qsTr("WHAT IT GUARANTEES")
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                }
                Repeater {
                    model: inspector.info.facets
                    delegate: ColumnLayout {
                        required property var modelData
                        objectName: "roomMapFacet"
                        Layout.fillWidth: true
                        spacing: 2
                        RowLayout {
                            spacing: Theme.spacing.small
                            StatusPill { text: map.credWord(String(modelData["class"])); tone: map.credTone(String(modelData["class"])) }
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: String(modelData.about) + (String(modelData.party || "").length > 0 ? qsTr(" · relies on %1").arg(modelData.party) : "")
                                color: Theme.palette.text
                                font.pixelSize: MusterStyle.caption; font.weight: Theme.typography.weightBold
                            }
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: String(modelData.mechanism)
                            color: Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                        }
                    }
                }
                LogosText {
                    visible: inspector.info.reliance.length > 0
                    text: qsTr("WHAT IT RELIES ON")
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                }
                Repeater {
                    model: inspector.info.reliance
                    delegate: RowLayout {
                        required property var modelData
                        objectName: "roomMapReliance"
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        StatusPill { text: map.credWord(modelData.cred); tone: map.credTone(modelData.cred) }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: modelData.text
                            color: Theme.palette.text
                            font.pixelSize: MusterStyle.caption
                        }
                    }
                }
                LogosText {
                    visible: inspector.info.links.length > 0
                    text: qsTr("CONNECTIONS")
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                }
                Repeater {
                    model: inspector.info.links
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        StatusPill { text: map.credWord(modelData.cred); tone: map.credTone(modelData.cred) }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: modelData.text + (String(modelData.party || "").length > 0 ? qsTr(" · relies on %1").arg(modelData.party) : "")
                            color: Theme.palette.text
                            font.pixelSize: MusterStyle.caption
                        }
                    }
                }
                // values a person reads aloud or copies: selectable
                Repeater {
                    model: inspector.info.copyable
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 2
                        LogosText { text: modelData[0]; color: Theme.palette.textSecondary; font.pixelSize: MusterStyle.caption }
                        TextEdit {
                            objectName: "roomMapFingerprint"
                            Layout.fillWidth: true
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.WrapAnywhere
                            text: modelData[1]
                            color: Theme.palette.text
                            selectionColor: MusterStyle.infoSoft
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.body
                        }
                    }
                }
                LogosTextField {
                    id: compareField
                    objectName: "roomMapCompareField"
                    visible: inspector.info.copyable.length > 0
                    Layout.fillWidth: true
                    placeholderText: qsTr("Another member's fingerprint")
                }
                LogosText {
                    objectName: "roomMapCompareResult"
                    readonly property var res: map.compareFingerprint(compareField.text)
                    visible: compareField.visible && compareField.text.trim().length > 0
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    font.pixelSize: MusterStyle.caption
                    color: res.state === "match" ? MusterStyle.settled : res.state === "differs" ? MusterStyle.refused : Theme.palette.textSecondary
                    text: res.state === "match" ? qsTr("Matches your fingerprint from epoch %1: you hold the same entries from then on.").arg(res.epoch)
                        : res.state === "differs" ? qsTr("Matches none you hold. Check you both read the same epoch's line; if you did, your logs differ. Crossings and Log show what you hold.")
                        : qsTr("Enter at least 16 characters of it.")
                }
                RowLayout {
                    spacing: Theme.spacing.small
                    ActionButton {
                        visible: inspector.n !== null && inspector.n.kind === "intent"
                        objectName: "roomMapOpenCard"
                        compact: true
                        text: qsTr("Open the card")
                        onClicked: map.openCard(inspector.n.id.slice(2))
                    }
                    ActionButton {
                        visible: inspector.n !== null && inspector.n.kind === "intent" && map.lens !== "prov"
                        compact: true; quiet: true
                        text: qsTr("Trace its inputs")
                        onClicked: { map.focusIntent = inspector.n.id.slice(2); map.lens = "prov"; }
                    }
                    ActionButton {
                        visible: inspector.n !== null && inspector.n.kind === "entry"
                        compact: true; quiet: true
                        text: qsTr("Replay to here")
                        onClicked: { map.following = false; map.k = map.rank(inspector.n.seq); }
                    }
                }
            }
        }
    }
    function describe(n) {
        var d = { kicker: "", title: "", pill: "", tone: "waiting", lead: "", rows: [], guarantee: "",
                  facets: [], links: [], copyable: [], reliance: [] };
        var i, e, a;
        if (!n && map.lens === "trust") {
            // what the room takes on someone's word, grouped by whose; what is exposed, by to whom
            d.kicker = qsTr("TRUST");
            d.title = qsTr("What this room relies on");
            var mot = {}, exp = {}, imp = 0, order = [];
            for (i = 0; i < allNodes.length; i++) {
                var en = allNodes[i];
                if (en.kind !== "entry" || !shownAt(en)) continue;
                var fs = (en.attrs || {}).facets || [];
                for (var j = 0; j < fs.length; j++) {
                    var fc = fs[j], cl = String(fc["class"]), pty = String(fc.party || "");
                    if (cl === "imperative") imp++;
                    else if (cl === "motivational") {
                        if (!mot[pty]) { mot[pty] = {}; order.push(pty); }
                        mot[pty][fc.about] = (mot[pty][fc.about] || 0) + 1;
                    } else if (cl === "exposed") exp[pty] = (exp[pty] || 0) + 1;
                }
            }
            d.lead = qsTr("%n guarantees here are imperative: the code enforces them, and no one can defect from them.", "", imp)
                   + " " + qsTr("The rest rely on someone, named below. Muster classifies; it never scores.");
            for (i = 0; i < order.length; i++) {
                var parts = [], abouts = mot[order[i]];
                for (var ab in abouts) parts.push(abouts[ab] > 1 ? ab + " ×" + abouts[ab] : ab);
                d.links.push({ cred: "motivational", text: order[i] + ": " + parts.join("; "), party: "" });
            }
            for (var p2 in exp)
                d.links.push({ cred: "exposed", text: qsTr("%1 saw when %n entries arrived, and their topic", "", exp[p2]).arg(p2), party: "" });
            var outs = ["o:rpc-provider", "o:chain-observer", "o:target-module"];
            for (i = 0; i < outs.length; i++) {
                var lf = map.learned(outs[i]);
                if (lf.length > 0) d.links.push({ cred: "exposed", text: qsTr("%1 learned %2").arg(map.obsWord(outs[i], 0)).arg(lf.join(", ")), party: "" });
            }
            return d;
        }
        if (!n && map.lens === "crossings") {
            d.kicker = qsTr("CROSSINGS");
            d.title = qsTr("In, out, and who joined");
            d.lead = qsTr("Out is what an outside observer learned, at the entry that sent it. In is what the room took from outside, and how it was recorded. A join is a member admitted; they read from that epoch on.");
            d.rows.push([qsTr("Out"), String(map.crossingCount("out")), "out"]);
            d.rows.push([qsTr("In"), String(map.crossingCount("in"))]);
            d.rows.push([qsTr("Joined"), String(map.crossingCount("join"))]);
            return d;
        }
        if (!n) {
            d.kicker = qsTr("THE ROOM");
            d.title = qsTr("How this room got here");
            d.lead = qsTr("Everything on the map is folded from the room's log. Drag the timeline to replay it; select anything to see what it is and what the code guarantees about it.");
            d.rows.push([qsTr("Members"), String(map.memberIds.length)]);
            d.rows.push([qsTr("Proposals"), String(map.intentIds.length)]);
            d.rows.push([qsTr("You read from"), map.readFrom > 0 ? qsTr("epoch %1, nothing before your admission").arg(map.readFrom) : qsTr("epoch 0, as a founder")]);
            d.rows.push([qsTr("Store node"), qsTr("timing and topic of %n envelopes", "", map.heldCount), "out"]);
            var obs = ["o:rpc-provider", "o:chain-observer", "o:target-module"];
            for (i = 0; i < obs.length; i++) {
                var f = map.learned(obs[i]);
                if (f.length > 0) d.rows.push([map.obsWord(obs[i], 0), f.join(", "), "out"]);
            }
            // validate: the room's fingerprint from each epoch this device holds, to compare
            // with another member out loud; and what the room refused to read
            var dropped = Number((map.graph || {}).dropped || 0);
            d.rows.push([qsTr("Dropped"), dropped > 0 ? qsTr("%n entries failed their author signature; no view reads them", "", dropped)
                                                      : qsTr("none: every author-signed entry verified")]);
            var fps = (map.graph || {}).fingerprints || [];
            for (i = 0; i < fps.length; i++) {
                var dg = String(fps[i].digest || "").slice(0, 32).replace(/(.{4})/g, "$1 ").trim();
                d.copyable.push([qsTr("Room fingerprint from epoch %1 · %n entries", "", Number(fps[i].entries)).arg(fps[i].fromEpoch), dg]);
            }
            if (fps.length > 0)
                d.guarantee = qsTr("To check that you and another member hold the same room, read the fingerprint from an epoch you both held aloud. If it matches, you hold the same entries from that epoch on.");
            return d;
        }
        a = n.attrs || {};
        if (n.kind === "member") {
            var hex = n.id.slice(2), self = hex === map.viewer;
            d.kicker = qsTr("MEMBER");
            d.title = map.memberName(n.id) + (self ? qsTr(" · this device") : "");
            d.lead = self ? qsTr("Your keys stay on this device. The room sees what you signed into it, and nothing else.")
                          : qsTr("What the map says about this member is only what they put in the room.");
            d.rows.push([qsTr("Joined"), Number(a.joined) >= 0 ? qsTr("epoch %1").arg(a.joined) : qsTr("not in the roster you hold")]);
            d.rows.push([qsTr("Identity"), map.shortId(hex), "mono"]);
            var did = 0, keys = [];
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.src === n.id && map.rank(e.seq) <= map.k && e.kind === "authored") did++;
                if (e.src === n.id && e.kind === "bound") keys.push(map.shortId(e.dst.slice(2)));
            }
            d.rows.push([qsTr("Signed entries"), String(did)]);
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.src !== n.id || map.rank(e.seq) > map.k || e.kind === "authored") continue;
                d.links.push({ cred: String((e.attrs || {}).credibility || ""), party: String((e.attrs || {}).party || ""), text: map.linkText(e) });
            }
            if (keys.length > 0) d.rows.push([qsTr("Approval keys"), keys.join(", "), "mono"]);
            return d;
        }
        if (n.kind === "intent") {
            var id = n.id.slice(2), it = map.intentOf(id);
            d.kicker = qsTr("PROPOSAL");
            d.title = map.intentWord(id);
            d.pill = map.stateWords(n); d.tone = map.stateTone(n);
            d.lead = it && it.summary ? String(it.summary.text || "") : String(a.summary || "");
            d.rows.push([qsTr("Runs as"), String(a.policy || a.family || "")]);
            addContent(d, a.effect, []);
            if (a.txhash) d.copyable.push([qsTr("What is signed (the materialization)"), String(a.txhash)]);
            d.rows.push([qsTr("Agreed"), qsTr("%1 of %2").arg(Number(map.stepAt(n).approvals || 0)).arg(Number(a.threshold || 0))]);
            if (Number(a.declines || 0) > 0) d.rows.push([qsTr("Declined"), String(a.declines)]);
            var inputs = 0;
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.dst === n.id && e.kind === "input") inputs++;
                if (e.src === n.id && e.kind === "leaves" && map.rank(e.seq) <= map.k)
                    d.rows.push([map.obsWord(e.dst, 0) + qsTr(" at #%1").arg(e.seq), ((e.attrs && e.attrs.fields) || []).join(", "), "out"]);
            }
            d.guarantee = qsTr("Re-derived on each device from the effect · %n inputs, each traced to its entry in the log", "", inputs);
            // before you approve: what this proposal takes on someone's word, by whose
            var rel = {}, relOrder = [], impN = 0;
            for (i = 0; i < allNodes.length; i++) {
                var en2 = allNodes[i], at2 = en2.attrs || {};
                if (en2.kind !== "entry" || String(at2.intent || "") !== id || !at2.counted || !shownAt(en2)) continue;
                var fs2 = at2.facets || [];
                for (var j2 = 0; j2 < fs2.length; j2++) {
                    var c2 = String(fs2[j2]["class"]);
                    if (c2 === "imperative") impN++;
                    if (c2 !== "motivational") continue;
                    var pty2 = String(fs2[j2].party);
                    if (!rel[pty2]) { rel[pty2] = []; relOrder.push(pty2); }
                    if (rel[pty2].indexOf(fs2[j2].about) < 0) rel[pty2].push(fs2[j2].about);
                }
            }
            for (i = 0; i < relOrder.length; i++)
                d.reliance.push({ cred: "motivational", text: relOrder[i] + ": " + rel[relOrder[i]].join("; "), party: "" });
            if (relOrder.length === 0 && impN > 0)
                d.reliance.push({ cred: "imperative", text: qsTr("nothing so far rests on anyone's word: %n guarantees, all enforced by the code", "", impN), party: "" });
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (map.rank(e.seq) > map.k) continue;
                if ((e.dst === n.id && e.kind !== "input") || (e.src === n.id && e.kind === "leaves"))
                    d.links.push({ cred: String((e.attrs || {}).credibility || ""), party: String((e.attrs || {}).party || ""), text: map.linkText(e) });
            }
            return d;
        }
        if (n.kind === "observer" || n.kind === "outside") {
            d.kicker = qsTr("OUTSIDE THE ROOM");
            d.title = map.obsWord(n.id, 0);
            d.lead = map.obsWord(n.id, 2);
            if (n.id === "o:store-node") d.rows.push([qsTr("Learned"), qsTr("timing and topic of %n envelopes", "", map.heldCount), "out"]);
            if (n.id === "o:store-node" && map.holdsVoice)
                d.rows.push([qsTr("Voice notes"), qsTr("each one's two envelopes, of one fixed size: that one was sent, never how long it is"), "out"]);
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.dst === n.id && e.kind === "leaves" && map.rank(e.seq) <= map.k)
                    d.rows.push([map.intentWord(e.src.slice(2)) + qsTr(" at #%1").arg(e.seq), ((e.attrs && e.attrs.fields) || []).join(", "), "out"]);
                if (e.src === n.id && e.kind === "enters" && map.rank(e.seq) <= map.k)
                    d.rows.push([qsTr("Into %1 at #%2").arg(map.intentWord(e.dst.slice(2))).arg(e.seq), map.kindWord(String((e.attrs || {}).kind || ""))]);
            }
            return d;
        }
        if (n.kind === "entry") {
            d.kicker = qsTr("LOG ENTRY #%1 · EPOCH %2").arg(n.seq).arg(n.epoch);
            d.title = map.kindWord(String(a.kind || "")) + (a.account ? qsTr(" by %1").arg(map.actorName(a.account)) : "");
            if (!a.counted) d.lead = a.account ? qsTr("Not counted: this entry counts for nothing, though its author signed it.")
                                               : qsTr("Not counted: the fold refused this entry, so it names no one.");
            d.rows.push([qsTr("Class"), String(a.cls || qsTr("not classed"))]);
            d.rows.push([qsTr("Attribution"), map.basisWords(String(a.basis || ""))]);
            if (a.attestation) d.rows.push([qsTr("Attestation"), String(a.attestation)]);
            d.rows.push([qsTr("Content id"), map.shortId(n.id.slice(2)), "mono"]);
            if (a.intent) d.rows.push([qsTr("Proposal"), map.intentWord(String(a.intent))]);
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.kind === "leaves" && e.seq === n.seq)
                    d.rows.push([qsTr("Left to %1").arg(map.obsWord(e.dst, 0)), ((e.attrs && e.attrs.fields) || []).join(", "), "out"]);
            }
            d.guarantee = String(a.guarantee || "");
            d.facets = a.facets || [];
            var ct = a.content || {};
            if (String(a.kind) === "message" && ct.body !== undefined) d.lead = (d.lead.length > 0 ? d.lead + " " : "") + map.messageText(ct.body);
            addContent(d, ct, ["body", "authorSig"]);
            if (ct.authorSig) d.copyable.push([qsTr("author signature"), valueText(ct.authorSig)]);
            return d;
        }
        if (n.kind === "account") {
            d.kicker = qsTr("ACCOUNT IN THE ROOM");
            d.title = String(a.family || qsTr("Account"));
            d.rows.push([qsTr("Chain"), String(a.chain || ""), "mono"]);
            if (a.label) d.lead = String(a.label);
            if (a.address) d.copyable.push([qsTr("Address"), String(a.address)]);
            var sl = a.signerList || [];
            for (var si = 0; si < sl.length; si++) d.copyable.push([qsTr("Signer %1").arg(si + 1), String(sl[si])]);
            if (a.config) d.copyable.push([qsTr("Configuration"), String(a.config)]);
            if (Number(a.threshold || 0) > 0) d.rows.push([qsTr("Rule"), qsTr("%1 of %2").arg(a.threshold).arg(a.signers)]);
            if (a.conflict) d.rows.push([qsTr("Note"), qsTr("Members disclosed different configurations for it")]);
            d.guarantee = qsTr("Disclosed by a member, signed by them; each client checks it against the chain before acting from it.");
            return d;
        }
        if (n.kind === "signer") {
            d.kicker = qsTr("APPROVAL KEY");
            d.title = map.shortId(n.id.slice(2));
            var owner = "";
            for (i = 0; i < allEdges.length; i++) if (allEdges[i].kind === "bound" && allEdges[i].dst === n.id) owner = allEdges[i].src;
            d.lead = owner.length > 0 ? qsTr("Tied to %1 by a statement this key signed, which the room checked.").arg(map.memberName(owner))
                                      : qsTr("No binding in the room ties this key to a member, so the map names no one.");
            d.guarantee = qsTr("The driver verified that each approval from this key recovers to a configured signer.");
            return d;
        }
        if (n.kind === "ceremony") {
            d.kicker = qsTr("KEY CEREMONY");
            d.title = qsTr("FROST key ceremony");
            d.lead = qsTr("A group key made in the room. Every member computes the coordinator's steps from the log.");
            return d;
        }
        if (n.kind === "sealed") {
            d.kicker = qsTr("SEALED");
            d.title = qsTr("Before you joined");
            d.lead = qsTr("Entries from epochs before your admission. Your client never held those epochs' keys, so it cannot open them, and this map cannot show them.");
            d.guarantee = qsTr("Someone who joins reads from the moment they were let in, never what came before.");
            return d;
        }
        if (n.kind === "bytes") {
            d.kicker = qsTr("INVARIANTS 1 AND 10");
            d.title = qsTr("The signed bytes");
            d.lead = qsTr("The materialization of the effect, with the provenance record P committed inside it. Each input on the left is named in P by class, author and log position.");
            d.guarantee = qsTr("Each device re-derives the materialization and refuses on mismatch; signing is refused if any input's origin cannot be accounted for.");
            return d;
        }
        return d;
    }

    // ── the timeline: one tick per entry; drag or play to replay ─────────────
    Rectangle {
        id: timeline
        objectName: "roomMapTimeline"
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.spacing.small }
        height: 74
        radius: 10
        color: Theme.palette.surfaceRaised
        border.color: Theme.palette.borderSubtle

        Timer {
            id: player
            interval: 700; repeat: true
            onTriggered: { if (map.k >= map.seqMax) { stop(); map.following = true; } else map.k = map.k + 1; }
        }
        RowLayout {
            anchors { fill: parent; margins: Theme.spacing.small }
            spacing: Theme.spacing.medium
            ActionButton {
                objectName: "roomMapPlay"
                compact: true
                text: player.running ? qsTr("Pause") : qsTr("Replay")
                enabled: map.seqMax >= 0
                onClicked: {
                    if (player.running) { player.stop(); return; }
                    map.following = false;
                    if (map.k >= map.seqMax) map.k = 0;
                    player.start();
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Item {
                    id: track
                    Layout.fillWidth: true
                    implicitHeight: 30
                    readonly property real step: map.seqMax > 0 ? width / map.seqMax : 0
                    Rectangle {      // the Log lens's window over a long log
                        readonly property real off: map.readFrom > 0 ? 14 : 0
                        visible: map.lens === "log" && map.replayOrder.length > map.logWindow
                        x: off + map.logLo * (track.width - off) / Math.max(1, map.seqMax) - 3
                        width: (map.logHi - map.logLo) * (track.width - off) / Math.max(1, map.seqMax) + 6
                        y: 0; height: 30; radius: 3
                        color: MusterStyle.infoSoft; border.color: MusterStyle.info; border.width: 1
                    }
                    Rectangle {      // before you joined
                        visible: map.readFrom > 0
                        x: 0; y: 4; width: 10; height: 22; radius: 2
                        color: Theme.palette.surfaceRecessed; border.color: Theme.palette.border
                    }
                    Repeater {
                        objectName: "roomMapTicks"
                        model: map.ticks
                        delegate: Rectangle {
                            required property var modelData
                            x: (map.readFrom > 0 ? 14 : 0) + modelData.at * (track.width - (map.readFrom > 0 ? 14 : 0)) / Math.max(1, map.seqMax) - 2
                            y: modelData.out ? 2 : 8
                            width: map.replayOrder.length > 400 ? 2 : 4; height: modelData.out ? 26 : 16; radius: 1
                            color: modelData.out ? MusterStyle.info : map.clsColor(modelData.cls)
                            opacity: modelData.at <= map.k ? 1 : 0.25
                        }
                    }
                    Rectangle {      // where what is new since the last look begins
                        visible: map.newCount > 0
                        x: (map.readFrom > 0 ? 14 : 0) + map.lastSeen * (track.width - (map.readFrom > 0 ? 14 : 0)) / Math.max(1, map.seqMax) - 6
                        y: 0; width: Math.max(4, track.width - x); height: 2
                        color: MusterStyle.needs
                    }
                    Rectangle {
                        x: (map.readFrom > 0 ? 14 : 0) + Math.max(0, map.k) * (track.width - (map.readFrom > 0 ? 14 : 0)) / Math.max(1, map.seqMax) - 1
                        width: 2; height: parent.height
                        color: Theme.palette.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        function seekTo(mx) {
                            var off = map.readFrom > 0 ? 14 : 0;
                            var s = Math.round((mx - off) / Math.max(1, track.width - off) * Math.max(1, map.seqMax));
                            map.following = s >= map.seqMax;
                            map.k = Math.max(0, Math.min(map.seqMax, s));
                        }
                        onPressed: (m) => { player.stop(); seekTo(m.x); }
                        onPositionChanged: (m) => { if (pressed) seekTo(m.x); }
                    }
                }
                LogosText {
                    objectName: "roomMapNow"
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    text: {
                        if (map.seqMax < 0) return qsTr("The log is empty.");
                        var n = null;
                        n = map.replayOrder[map.k] || null;
                        var w = n ? map.kindWord(String((n.attrs || {}).kind || "")) + (n.attrs && n.attrs.account ? qsTr(" by %1").arg(map.actorName(n.attrs.account)) : "") : "";
                        return qsTr("%1 of %2 · in the order members saw them").arg(map.k + 1).arg(map.seqMax + 1) + (w.length > 0 ? " · " + w : "")
                               + (n ? qsTr(" · epoch %1").arg(n.epoch) : "");
                    }
                }
            }
        }
    }
}
