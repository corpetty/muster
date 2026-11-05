import QtQuick
import QtQuick.Layouts
import QtCore as Prefs   // qualified: a stored preference, not our Settings.qml surface

import Logos.Theme
import Logos.Controls

// The room / conversation surface — the substrate of the spec-first client. ONE
// timeline: chat text and cards interleave in the order they were sent, because a
// proposal is a card IN the conversation, not a side panel. Two folds off the SAME
// sealed log feed it (state = reduce(log)):
//   • messages (coordinate_messages) — the timeline itself: chat text, address-share
//     / receipt cards, and `intent-ref` cards that a proposal posts to announce
//     itself (authored + timestamped, so it lands in order and names who proposed).
//   • intents (coordinate_intents) — the verified proposal fold. A thread `intent-ref`
//     resolves to its live intent here (state + verify + provenance), so the inline
//     card is real folded state, never the posted JSON. Proposing goes through
//     coordinate_propose (content-addressed id); approving is an owner signature over
//     the safeTxHash the module re-derives — the client holds no keys, so you paste
//     the signature your own device produced (coordinate_contribute).
// Everything the room shows is reduce(log) from the module — this view holds no
// state of its own.
//
// NB (ADR-011): nix build does not evaluate QML; this needs a launch in the
// ui-host to be believed. Restricted to Theme keys + Logos.Controls types Main.qml
// already uses.
Item {
    id: room

    property var backend

    // The pieces of this surface (RoomHeader, RoomThread, RoomComposer, RoomDetails) each
    // take this Room as their `room`. Passed by this name, since `room: room` inside one of
    // them would bind its own property to itself.
    readonly property Item roomItem: room
    // The payment form's recipient and amount fields live in RoomComposer; prefillPayment
    // and a card's "Use as recipient" write to them through these.
    readonly property Item proposeTo: composerPanel.proposeToField
    readonly property Item proposeValue: composerPanel.proposeValueField

    // ── the room's chrome (exo-720.7, exo-720.8) ──────────────────────────
    // Room details is a drawer, closed by default; whether it is open, and on which tab, is
    // the person's choice, kept on this device (never in the room).
    Prefs.Settings {
        id: roomPrefs
        category: "MusterUi"
        property bool detailsOpen: false
        property string detailsTab: "people"
        // the room map: how many entries each room held when this device last closed it
        // (a per-device convenience, never in the room)
        property string mapSeen: "{}"
    }
    property alias detailsOpen: roomPrefs.detailsOpen
    property alias detailsTab: roomPrefs.detailsTab
    function openDetails(tab) { if (tab) room.detailsTab = tab; room.detailsIntent = ""; room.detailsOpen = true; }
    function closeDetails() { room.detailsOpen = false; room.detailsIntent = ""; }
    // A card's "Who sees this?": Privacy, showing that one proposal's flow. Cleared when the
    // drawer closes or another tab opens, so a filtered view never passes for the room's.
    property string detailsIntent: ""
    function showWhoSees(intentId) { room.detailsTab = "privacy"; room.detailsOpen = true; room.detailsIntent = String(intentId || ""); }
    onDetailsTabChanged: if (room.detailsTab !== "privacy") room.detailsIntent = ""
    // The pinned line's Review: the thread scrolls to that proposal's card.
    signal jumpRequested(string intentId)
    // The room map (exo-dde, RoomMap.qml): the room as a graph, over the conversation.
    // Opened from ⋯ or from Privacy; a proposal opens it on that proposal.
    property bool mapOpen: false
    // however the map closes (its ×, Esc, a card), remember how much of the log it showed
    onMapOpenChanged: if (!room.mapOpen && roomMap.replayOrder.length > 0) roomMap.seen(roomMap.replayOrder.length)
    function openMap(lens, intentId) {
        if (room.backend) room.backend.loadGraph("");
        roomMap.lens = lens || "room";
        roomMap.focusIntent = String(intentId || "");
        roomMap.crossingsFilter = lens === "crossings" ? String(intentId || "") : "";
        roomMap.selected = intentId ? "i:" + intentId : "";
        var seen = {};
        try { seen = JSON.parse(roomPrefs.mapSeen); } catch (e) { seen = {}; }
        roomMap.lastSeen = seen[room.topic] !== undefined ? Number(seen[room.topic]) : -1;
        room.detailsOpen = false;
        room.mapOpen = true;
    }
    readonly property var graph: {
        var g;
        try { g = JSON.parse(backend ? backend.graphJson : "{}"); }
        catch (e) { return ({}); }
        // the module sends each shared facet set and guarantee once (exo-dde.19): an attr
        // holding a number is an index into facetSets / texts. A map recorded before has none.
        var sets = g.facetSets || [], texts = g.texts || [];
        function expand(list) {
            for (var i = 0; i < (list || []).length; i++) {
                var a = list[i].attrs;
                if (!a) continue;
                if (typeof a.facets === "number") a.facets = sets[a.facets] || [];
                if (typeof a.guarantee === "number") a.guarantee = texts[a.guarantee] || "";
            }
        }
        expand(g.nodes); expand(g.edges);
        return g;
    }

    // Admit someone who asked to join — from the notice in the thread, or People.
    function admitMember(identityHex) {
        if (!room.backend) return;
        room.backend.admit(identityHex);
        // The admit re-keyed the room to a new epoch the joiner now shares. Anything from
        // before their epoch is unreadable to them (F-16), so re-send it into the new
        // epoch: an unanswered address request, and any open proposal (its card) —
        // otherwise a payment proposed before they joined never reaches them to approve.
        room.resendOutstandingAsk();
        room.backend.reannounce();
    }
    // "Not now" on a join request hides its notice, this session only: the request stays,
    // and People still offers Admit. The module has no "refuse": nobody is told anything.
    // Someone in the room you haven't named (exo-d1a): the room asks once who they are, so
    // they read as a name everywhere after — the roster, the thread, the cards. The name is
    // yours (your address book), never sent. "Not now" leaves them unnamed this session.
    property var namingSkipped: ({})
    readonly property var unnamedMember: {
        for (var i = 0; i < room.members.length; ++i) {
            var m = room.members[i];
            if (!m || m.self || String(m.alias || "").length > 0) continue;
            if (room.namingSkipped[String(m.identity)]) continue;
            return m;
        }
        return null;
    }
    function nameMember(identityHex, alias) {
        var a = String(alias || "").trim();
        if (!room.backend || a.length === 0) return;
        room.backend.addContact(identityHex, a);
        room.backend.loadMembers();
        room.backend.loadMessages();
        room.backend.loadIntents();
        MusterStyle.notify(qsTr("Saved as %1").arg(a));
    }
    function skipNaming(identityHex) {
        var s = Object.assign({}, room.namingSkipped);
        s[String(identityHex)] = true;
        room.namingSkipped = s;
    }
    property var dismissedRequests: ({})
    function dismissRequest(identityHex) {
        var m = Object.assign({}, room.dismissedRequests); m[identityHex] = true; room.dismissedRequests = m;
    }
    readonly property var visibleRequests: room.pending.filter(function (p) { return !room.dismissedRequests[String(p.identity || "")]; })

    // This room's line from coordinate_conversations: what waits on YOU here (F-18).
    readonly property var conversation: {
        try {
            var convs = JSON.parse(room.backend ? room.backend.conversationsJson : "[]");
            for (var i = 0; i < convs.length; ++i)
                if (String(convs[i].topic || "") === room.topic) return convs[i];
        } catch (e) {}
        return null;
    }
    function needsWord(what) {
        return what === "agree" ? qsTr("Needs your agreement") : what === "pay" ? qsTr("Pay your share")
             : what === "approve" ? qsTr("Needs your approval") : what === "submit" ? qsTr("Ready to settle")
             : qsTr("Waiting on you");
    }
    // the pinned bar's word for a proposal that does not wait on you (exo-ce0)
    function stateWord(st) {
        return st === "proposed" || st === "collecting" ? qsTr("Waiting on others")
             : st === "executable" ? qsTr("Agreed") : st === "submitted" ? qsTr("Sent to the chain")
             : st === "settling" ? qsTr("Settling") : st === "final" ? qsTr("Done") : String(st || "");
    }
    // The pinned proposal (U-3): what waits on you first, else the latest still under way.
    readonly property var liveProposal: {
        var ns = (room.conversation && Array.isArray(room.conversation.needs)) ? room.conversation.needs : [];
        for (var i = 0; i < ns.length; ++i) {
            var it = room.intentById(String(ns[i].id || ""));
            return { id: String(ns[i].id || ""), needsYou: true, label: room.needsWord(String(ns[i].what || "")),
                     text: String(ns[i].text || (it && it.summary && it.summary.text) || "") };
        }
        for (var j = room.intents.length - 1; j >= 0; --j) {
            var x = room.intents[j], st = String(x.state || "");
            if (st !== "final" && st !== "declined" && st !== "expired")
                return { id: String(x.id || ""), needsYou: false, label: room.stateWord(st),
                         text: String((x.summary && x.summary.text) || "") };
        }
        return null;
    }
    // How many proposals reached a chain: only a driver that settles outside the room
    // counts (profile.settlement), so a ratified statement — final in the room — does not.
    readonly property int settledOutside: room.intents.filter(function (x) {
        var how = String((x.profile && x.profile.settlement) || "none");
        var st = String(x.state || "");
        return how !== "none" && how !== "stub" && (st === "submitted" || st === "settling" || st === "final");
    }).length
    // The scope line (U-1): always on screen in a room.
    readonly property string scopeLine: qsTr("end-to-end · %1 can read").arg(room.members.length)
        + (room.settledOutside === 0 ? qsTr(" · nothing has settled outside the room")
           : room.settledOutside === 1 ? qsTr(" · 1 proposal settled outside the room")
           : qsTr(" · %1 proposals settled outside the room").arg(room.settledOutside))

    readonly property string topic: backend ? backend.roomTopic : ""
    // What this instance knows the room as (Main's session-only title), shown instead of
    // the topic, which names nothing (exo-661.7 / exo-59c). Empty → the topic.
    property string roomTitle: ""
    // The room being opened (exo-ba0): set by Main when it asks the module to join, and
    // cleared when the module's room is that room. Until then the room says it is opening —
    // never the previous room's thread, and never the join form.
    property string openingTopic: ""
    readonly property bool opening: room.openingTopic.length > 0 && room.openingTopic !== room.topic
    function beginOpening(t) { room.openingTopic = String(t || ""); openingGiveUp.restart(); }
    onTopicChanged: {
        if (room.topic === room.openingTopic) room.openingTopic = "";
        room.voiceOpTopic = "";     // a voice call's answer stays with the room it was made in
    }
    Timer { id: openingGiveUp; interval: 45000; onTriggered: room.openingTopic = "" }
    property bool openingSlow: false
    onOpeningChanged: room.openingSlow = false
    Timer { interval: 5000; running: room.opening; onTriggered: room.openingSlow = true }
    readonly property bool joined: room.topic.length > 0 && !room.opening

    // Whether the proposal composer is open (the "+" in the message row), and which
    // effect type is being composed: "payment" (a transfer) or "statement" (text the
    // room ratifies). The action is pluggable — the same path coordinates either.
    property bool composing: false
    property string composeType: "payment"

    // The chat id "Start something" named for this room (the person the room is FOR).
    // When their join-request arrives we admit them automatically — you already chose
    // them, so you shouldn't have to click Admit, and they shouldn't have to ask. The
    // binding is still verified on admit (F-9); this only removes the manual step.
    property string expectedMember: ""
    // Whether this member opened this room from the composer (Main.enterRoom sets it).
    // A founder has no one to ask to let them in (exo-dcc.30).
    property bool founded: false
    // ids we've already auto-admitted, so a pending entry lingering one extra tick
    // (before the re-key propagates) doesn't trigger a second admit.
    property var autoAdmitted: ({})

    // When composeType is "action" (a generic module action, P-D4), which action the
    // picker has selected — {module, method, signature, params, allowed} — or null.
    property var chosenAction: null

    // Mode B (exo-45e): the chosen action is a COORDINATED TRANSFER — the recipient
    // supplies their own address (a counterparty slot), rather than the proposer guessing
    // it. Reset whenever the chosen action changes (and when the panel closes, below).
    property bool modeB: false
    onChosenActionChanged: modeB = false

    // Parsed folds. A parse failure yields [] (absent), never fiction.
    readonly property var messages: {
        try { return JSON.parse(backend ? backend.messagesJson : "[]"); }
        catch (e) { return []; }
    }
    // What I sent that the room's log has not shown back yet (exo-49d): the line appears in
    // the thread at once, "sending…", and leaves the outbox when the log returns it. Still
    // missing after a while, it reads "Not sent" with a retry. Never a second record: the
    // log is the thread; this is only the wait before it catches up.
    property var outbox: []        // [{key, body, at, failed}]
    function sendChat(body) {
        var b = String(body || "");
        if (!room.backend || b.length === 0) return;
        room.outbox = room.outbox.concat([{ key: String(Date.now()) + "-" + room.outbox.length,
                                            body: b, at: Date.now(), failed: false }]);
        room.backend.postMessage(b);
    }
    function retrySend(key) {
        var keep = [], body = "";
        for (var i = 0; i < room.outbox.length; ++i)
            if (room.outbox[i].key === key) body = room.outbox[i].body; else keep.push(room.outbox[i]);
        room.outbox = keep;
        room.sendChat(body);
    }
    // each outbox line is matched to one of my own messages with the same text, sent no
    // earlier than a minute before it (the log's clock is in seconds)
    function reconcileOutbox() {
        if (room.outbox.length === 0) return;
        var used = {}, keep = [], changed = false;
        for (var i = 0; i < room.outbox.length; ++i) {
            var o = room.outbox[i], hit = false;
            for (var j = 0; j < room.messages.length && !hit; ++j) {
                var m = room.messages[j];
                if (used[j] || !m.self || String(m.body) !== o.body) continue;
                if (MusterStyle.msOf(m.ts) < o.at - 60000) continue;
                used[j] = true; hit = true;
            }
            if (hit) { changed = true; continue; }
            if (!o.failed && Date.now() - o.at > 30000) {
                o = { key: o.key, body: o.body, at: o.at, failed: true }; changed = true;
            }
            keep.push(o);
        }
        if (changed) room.outbox = keep;
    }
    onMessagesChanged: room.reconcileOutbox()
    Timer {
        interval: 5000; repeat: true
        running: room.outbox.length > 0
        onTriggered: room.reconcileOutbox()
    }
    // the thread as drawn: the log, then what is on its way
    readonly property var threadItems: {
        var out = room.messages.slice();
        for (var i = 0; i < room.outbox.length; ++i) {
            var o = room.outbox[i];
            out.push({ id: "outbox:" + o.key, outboxKey: o.key, author: room.myIdentity, self: true,
                       ts: Math.floor(o.at / 1000), body: o.body, alias: "",
                       pending: !o.failed, failed: o.failed });
        }
        return out;
    }
    readonly property var members: {
        try { return JSON.parse(backend ? backend.membersJson : "[]"); }
        catch (e) { return []; }
    }

    // ── voice notes (docs/design/voice-notes.md §8) ──────────────────────
    // The module records, holds the draft, sends and plays; no audio reaches this view.
    // voice_status ({ready, recording, playing}) and the last voice call's answer, each
    // parsed once here for the composer's voice surface and the thread's cards.
    readonly property var voice: {
        try {
            var v = JSON.parse(backend ? (backend.voiceJson || "{}") : "{}");
            return (v && typeof v === "object") ? v : ({});
        } catch (e) { return ({}); }
    }
    readonly property string voiceState: String(((room.voice && room.voice.recording) || {}).state || "idle")
    readonly property var voicePlaying: (room.voice && room.voice.playing) ? room.voice.playing : null
    // where voice_status stands: the recording's state and the note playing, if any
    readonly property string voiceAt: room.voiceState + "/" + (room.voicePlaying ? String(room.voicePlaying.note || "") : "")
    // which voice call that answer is to (record, stop, send, discard, play, stopPlay), so
    // a refusal can say what was refused: the module's words are the same for each; and
    // the room it was made in and where voice_status stood then. A refusal describes that
    // state, so it shows only while it holds: once another room opens, or voice_status moves
    // on (the other recording ended, the note stopped playing), the answer is not shown
    // again, even if voice_status comes back to where it was (an idle busy is still stale).
    property string voiceOp: ""
    property string voiceOpTopic: ""
    property string voiceOpAt: ""
    // how many voice answers the backend has given (voiceResultSeq: one more per answer, one
    // identical to the last too), and that count when this room made its last voice call.
    // Until the count moves the call is in flight, and the last answer, to an earlier call,
    // is not shown. RoomVoiceNote keys a dismissed refusal by the count: it stays dismissed
    // until a new answer, and shows again if that answer refuses in the same words.
    readonly property int voiceAnswers: backend ? (parseInt(String(backend.voiceResultSeq || "0"), 10) || 0) : 0
    property int voiceCallAnswers: -1
    readonly property bool voicePending: room.voiceCallAnswers >= 0 && room.voiceAnswers === room.voiceCallAnswers
    // One move is the call's own, and its answer is about that move: a Stop while the device
    // was still starting drops the recording (starting → idle) and answers not-started,
    // "nothing was recorded", so that answer follows voice_status to idle instead of going
    // stale with it, whichever of the two arrives first (voice-notes.md §8).
    onVoiceAtChanged: {
        if (room.voiceAt === room.voiceOpAt) return;
        var stopWhileStarting = room.voiceOp === "stop" && room.voiceOpAt.indexOf("starting/") === 0
                                && room.voiceAt.indexOf("idle/") === 0;
        room.voiceOpAt = stopWhileStarting ? room.voiceAt : "";
    }
    readonly property var voiceResult: {
        if (room.voicePending || room.voiceOpTopic !== room.topic || room.voiceOpAt !== room.voiceAt) return ({});
        var r = backend ? String(backend.voiceResultJson || "") : "";
        if (r.length === 0 || r === "ok") return ({});
        try { var o = JSON.parse(r); return (o && typeof o === "object") ? o : ({}); }
        catch (e) { return ({}); }
    }
    function voiceCall(op) { room.voiceOp = op; room.voiceOpTopic = room.topic; room.voiceOpAt = room.voiceAt; room.voiceCallAnswers = room.voiceAnswers; }
    function startVoice() { if (!room.backend) return; room.voiceCall("record"); room.backend.startVoiceRecording(); }
    function stopVoice() { if (!room.backend) return; room.voiceCall("stop"); room.backend.stopVoiceRecording(); }
    function sendVoice() { if (!room.backend) return; room.voiceCall("send"); room.backend.sendVoiceDraft(); }
    function discardVoice() { if (!room.backend) return; room.voiceCall("discard"); room.backend.discardVoiceDraft(); }
    function playVoice(note) { if (!room.backend) return; room.voiceCall("play"); room.backend.playVoiceNote(String(note || "")); }
    function stopVoicePlay() { if (!room.backend) return; room.voiceCall("stopPlay"); room.backend.stopVoicePlayback(); }
    // This instance's own encryption identity (the roster row flagged self) — the id
    // a decline is keyed by, so the card knows "you declined".
    readonly property string myIdentity: {
        var arr = room.members;
        for (var i = 0; i < arr.length; ++i)
            if (arr[i] && arr[i].self) return String(arr[i].identity || "");
        return "";
    }
    // Join-requests not yet admitted: [{ identity, alias }]. The scope panel
    // lists these with an Admit action (the membership handshake).
    readonly property var pending: {
        try { return JSON.parse(backend ? backend.pendingJson : "[]"); }
        catch (e) { return []; }
    }
    // Readiness per intent (coordinate_readiness), keyed by id — loaded on demand when
    // a card's "What this needs" box opens (exo-002.3).
    readonly property var readinessMap: {
        try { return JSON.parse(backend ? backend.readinessJson : "{}"); }
        catch (e) { return ({}); }
    }
    function readinessFor(id) {
        var m = room.readinessMap;
        return (m && m[String(id)]) ? m[String(id)] : null;
    }
    // Offers per intent (coordinate_offers, exo-45e K6), keyed by id — which of MY OWN
    // holdings fill the slots this proposal asks of me; loaded when the card opens.
    readonly property var offersMap: {
        try { return JSON.parse(backend ? backend.offersJson : "{}"); }
        catch (e) { return ({}); }
    }
    function offersFor(id) {
        var m = room.offersMap;
        return (m && m[String(id)]) ? m[String(id)] : null;
    }
    // A remedy that lives in Settings (repoint the RPC): the shell switches views.
    signal settingsRequested()
    // Leave this room (exo-dcc.28) and rename it for yourself (exo-dcc.25): the shell
    // calls the module and moves the view.
    signal leaveRequested(string topic)
    signal renameRequested(string topic, string title)
    // Install what a proposal needs (exo-dcc.10): a card or the proposal form asks
    // Basecamp's Package Manager to open on a package; the shell raises the request
    // (packages.install / packages.show) and hands every answer back in packageRequests,
    // one entry per package: {state: asking|open|unavailable|failed|cancelled|error, …}.
    signal packageInstallRequested(string pkg)
    signal packageShowRequested(string pkg)
    property var packageRequests: ({})
    // Open the Monero wallet (exo-dcc.5): a Monero request is vouched for and confirmed by
    // the requester's own open wallet. The shell raises monero.wallet.unlock (a wallet
    // named) or monero.accounts.manage, and the answer comes back in moneroWallet:
    // {intent, wallet, state: asking|open|unavailable|failed|cancelled|error, error, at}.
    signal moneroWalletRequested(string wallet)
    // pay from Monero Wallet: Send filled in (monero.wallet.send), else the wallet brought up
    signal moneroWalletPresentRequested(string address, string amount)
    // whether the last pay request filled Monero Wallet's Send (and is still current)
    function moneroWalletFilled() {
        var r = room.moneroWallet || {};
        var at = Number(r.at || 0);
        return String(r.intent || "") === "monero.wallet.send" && String(r.state || "") === "open"
               && room.moneroStateAt <= at && room.moneroNow - at <= 120000;
    }
    property var moneroWallet: ({})
    // When the state a wallet note describes last changed (exo-dcc.20): a newer split or
    // share answer, or a Monero request's wallet state in the projection. A note older
    // than that is about something that is over, and one answered over two minutes ago
    // has done its job: neither is shown. moneroNow is the clock it is read against.
    property double moneroStateAt: 0
    property double moneroNow: Date.now()
    Timer {
        interval: 5000
        repeat: true
        running: String((room.moneroWallet || {}).state || "").length > 0
        onTriggered: room.moneroNow = Date.now()
    }
    // every Monero request's wallet state, as the projection says it (its changes date the note)
    readonly property string xmrWalletSig: {
        var out = [];
        var its = room.intents || [];
        for (var i = 0; i < its.length; ++i) {
            var w = its[i] && its[i].split && its[i].split.xmr ? its[i].split.xmr.wallet : null;
            if (w) out.push(String(its[i].id || "") + ":" + (w.ready ? "ready" : String(w.code || "")));
        }
        return out.join(",");
    }
    onXmrWalletSigChanged: room.moneroStateAt = Date.now()
    // What the last Monero wallet request answered, in words ("" = nothing asked yet, or
    // the answer is stale).
    function moneroWalletNote() {
        var r = room.moneroWallet || {};
        var st = String(r.state || "");
        var at = Number(r.at || 0);
        if (st !== "asking" && (room.moneroStateAt > at || room.moneroNow - at > 120000)) return "";
        if (st === "asking") return qsTr("Asking Monero Wallet to open…");
        // the shell answers a launch the same way whether or not the app is there (it offers
        // the install itself): the card's own steps say what to do next
        if (String(r.intent || "") === "basecamp.apps.launch") return "";
        // a filled Send: the card says what to check; a refusal is the wallet's own reason
        if (String(r.intent || "") === "monero.wallet.send") {
            if (st === "open") return "";
            if (String(r.error || "") === "view-only wallet")
                return qsTr("The wallet open in Monero Wallet is view-only: it can't send. Open a wallet that can.");
            if (String(r.error || "") === "busy")
                return qsTr("Monero Wallet has a send on screen already: finish or cancel it there, then try again.");
        }
        if (st === "open")
            return String(r.intent || "") === "monero.wallet.unlock"
                   ? qsTr("Your Monero wallet is open.")
                   : qsTr("Monero Wallet is open: open your wallet there, then come back.");
        if (st === "unavailable")
            return qsTr("Monero Wallet is not installed here: install monero_wallet_ui from Basecamp's Package Manager.");
        if (st === "cancelled") return qsTr("Cancelled.");
        if (st === "failed" || st === "error")
            return qsTr("Monero Wallet answered: %1").arg(String(r.error || qsTr("no answer")));
        return "";
    }
    // A chain a split cannot reach, in plain words (exo-408 item 9): each names the setting
    // that fixes it, and "" for any other error. `detail` is what the endpoint answered.
    function chainErrorWords(code, detail) {
        var d = String(detail || "");
        if (code === "no-rpc")
            return qsTr("A split settles on the chain your RPC serves, and it did not answer — check Settings → RPC. %1").arg(d);
        if (code === "no-btc-node")
            return qsTr("A Bitcoin split settles on the network your Bitcoin node serves, and it did not answer — check Settings → Bitcoin node. %1").arg(d);
        if (code === "no-lez-wallet")
            return qsTr("A private split is paid from your LEZ wallet, and it could not be read — set it up under Wallet. %1").arg(d);
        return "";
    }
    // A Monero wallet refusal in plain words: the module's code (before the first ':') and
    // its detail, which already names the network and the remedy.
    function moneroWhy(code, detail) {
        var c = String(code || ""), d = String(detail || "");
        var rest = d.indexOf(": ") > 0 && d.indexOf(c) === 0 ? d.slice(d.indexOf(": ") + 2) : d;
        if (c === "no-wallet") return qsTr("no Monero wallet is open. Open it in Monero Wallet: it makes the address you are paid at.");
        if (c === "wallet-other-network") return qsTr("your open Monero wallet is on another network (%1).").arg(rest);
        if (c === "wallet-watch-only") return qsTr("your open Monero wallet is view-only. Open the wallet that can spend what it receives.");
        if (c === "wallet-busy") return qsTr("your Monero wallet is busy. Try again in a moment.");
        if (c === "wallet-unread")
            return qsTr("Muster could not reach a Monero wallet here. Install Monero Wallet (monero_wallet_ui) and open your wallet, then try again.");
        if (c === "payto-not-mine") return qsTr("your open wallet does not list that address as its own.");
        return rest.length > 0 ? c + ": " + rest : c;
    }
    function packageReq(pkg) {
        var m = room.packageRequests;
        return (pkg && m && m[pkg]) ? m[pkg] : null;
    }

    readonly property var intents: {
        try { return JSON.parse(backend ? backend.intentsJson : "[]"); }
        catch (e) { return []; }
    }

    // What other people did since the last look, said once as a toast (exo-773): an
    // approval, a payment, a decline, a join, a proposal done. Facts are kept per intent and
    // compared on each refresh; for a few seconds after the room changes they are only
    // recorded, since the folds for the new room arrive one by one and are not news.
    property var facts: ({})
    property var memberFacts: ({})
    property string factsTopic: ""
    property double factsSince: 0
    function nameOr(n) { var s = String(n || ""); return s.length > 0 ? s : qsTr("Someone"); }
    function noteChanges() {
        var t = room.backend ? String(room.backend.roomTopic || "") : "";
        if (t !== room.factsTopic) { room.factsTopic = t; room.factsSince = Date.now(); }
        var quiet = Date.now() - room.factsSince < 4000;
        var news = [], fresh = {};
        for (var i = 0; i < room.intents.length; ++i) {
            var it = room.intents[i];
            if (!it || !it.id) continue;
            var id = String(it.id), old = room.facts[id];
            var f = { ap: {}, paid: {}, conf: {}, dec: {}, st: String(it.state || "") };
            var ap = Array.isArray(it.approvers) ? it.approvers : [];
            for (var a = 0; a < ap.length; ++a) {
                f.ap[ap[a].who] = true;
                if (old && !old.ap[ap[a].who] && !ap[a].mine) news.push(qsTr("%1 approved").arg(room.nameOr(ap[a].name)));
            }
            var ps = Array.isArray(it.parts) ? it.parts : [];
            for (var p = 0; p < ps.length; ++p) {
                var k = String(ps[p].part || p);
                if (ps[p].settled) f.paid[k] = true;
                if (ps[p].confirmed) f.conf[k] = true;
                if (!old || ps[p].mine) continue;
                if (ps[p].confirmed && !old.conf[k]) news.push(qsTr("%1's payment arrived").arg(room.nameOr(ps[p].name)));
                else if (ps[p].settled && !old.paid[k]) news.push(qsTr("%1 paid their share").arg(room.nameOr(ps[p].name)));
            }
            var dn = Array.isArray(it.declinerNames) ? it.declinerNames : [];
            for (var d = 0; d < dn.length; ++d) {
                f.dec[dn[d].who] = true;
                if (old && !old.dec[dn[d].who] && !dn[d].mine && String(dn[d].name) !== qsTr("you"))
                    news.push(qsTr("%1 declined").arg(room.nameOr(dn[d].name)));
            }
            if (old && old.st !== f.st && f.st === "final") news.push(ps.length > 0 ? qsTr("Every share is paid") : qsTr("Settled"));
            fresh[id] = f;
        }
        room.facts = fresh;
        var mf = {};
        for (var m = 0; m < room.members.length; ++m) {
            var mm = room.members[m];
            if (!mm) continue;
            mf[String(mm.identity)] = true;
            if (Object.keys(room.memberFacts).length > 0 && !room.memberFacts[String(mm.identity)] && !mm.self)
                news.push(qsTr("%1 joined").arg(String(mm.alias || "").length > 0 ? String(mm.alias) : qsTr("Someone new")));
        }
        room.memberFacts = mf;
        if (quiet || news.length === 0) return;
        MusterStyle.notify(news.length > 2 ? qsTr("%1, and %2 more").arg(news[0]).arg(news.length - 1)
                                          : news.join(" · "));
    }
    onIntentsChanged: room.noteChanges()
    onMembersChanged: room.noteChanges()
    // The room's coordination history (coordinate_activity): a plain-language
    // narrative of every state transition, in causal order, folded from the SAME
    // log the cards come from. The education seam — how the room got here.
    // The information flow (coordinate_flow): who could see what, per action.
    readonly property var flow: {
        try { return JSON.parse(backend ? backend.flowJson : "{}"); }
        catch (e) { return ({ rows: [], matrix: {} }); }
    }
    // The last signature-audit download (exo-403), shown on the card it was for.
    readonly property var lastAudit: {
        try { return JSON.parse(backend ? backend.auditJson : "{}"); }
        catch (e) { return ({}); }
    }
    function auditStatusFor(id) {
        var a = room.lastAudit;
        if (!a || String(a.intentId || "") !== id) return "";
        if (a.ok) return qsTr("Saved %1 (verifies on its own) and a readable report beside it").arg(String(a.cbor || ""));
        return qsTr("Audit trail not exported: %1").arg(String(a.reason || ""));
    }
    readonly property var activity: {
        try { return JSON.parse(backend ? backend.activityJson : "[]"); }
        catch (e) { return []; }
    }
    // Liveness of the infrastructure the room relies on (connectivity): {rows:[…]} —
    // the delivery node, plus whatever the room's proposals' drivers introduced (the
    // RPC appears only once a Safe proposal is on the log, exo-428). Invariant 8 — the
    // store nodes and RPC are untrusted, user-chosen infra, so their status is shown,
    // never assumed.
    readonly property var connectivity: {
        try { return JSON.parse(backend ? backend.connectivityJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The room's ACTIVE null-ladder level on the three axes (security_levels, exo-1ec.5):
    // {axes:[{axis,rung,real,mechanism}]}. Which nulls are still in place — shown, never
    // assumed; a level is never a silent fallback (the module refuses a failed upgrade).
    readonly property var securityLevels: {
        try { return JSON.parse(backend ? backend.securityLevelsJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The composer's sending context (coordinate_account): what an intent here would
    // move (the Safe's live balance — what's available to send) and who you act as
    // (your owner address + whether it's a real Safe owner). Ask-then-disclose: this
    // is loaded when the composer opens, not silently on room entry.
    readonly property var roomAccount: {
        try { return JSON.parse(backend ? backend.roomAccountJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The one asset available to send today (ETH). A picker when ERC-20 lands; for now
    // the composer shows it and the amount is checked against its balance.
    readonly property var roomAsset: {
        var a = (room.roomAccount && room.roomAccount.assets) ? room.roomAccount.assets : [];
        return a.length > 0 ? a[0] : null;
    }
    // Ask the module for the sending context — called when the composer opens (it reads
    // the RPC, so not on the message tick).
    function refreshRoomAccount() { if (room.backend) room.backend.loadRoomAccount(); }

    // Load the sending context the moment the composer opens, and again if the policy
    // changes while it's open (the acting-as owner check is Safe-specific). Not on
    // entry — ask-then-disclose. Also snap the policy to the current kind on open (it
    // may have been left on another kind's policy from a previous compose).
    // The kind list is re-read too, so each kind's module needs are graded as they are now
    // (exo-dcc.10: a module installed since launch no longer reads missing).
    onComposingChanged: { if (!composing) room.modeB = false;
                          if (composing) { refreshRoomAccount(); room.coherePolicy();
                                           room.installNow = Date.now();
                                           if (room.backend) room.backend.loadDrivers(); } }
    onPolicyKindChanged: {
        if (room.policyKind === room.requestedPolicy.split("@")[0]) room.requestedPolicy = "";
        if (room.policyKind === room.pickedKind) room.pickedKind = "";
        if (composing) refreshRoomAccount();
    }
    // A policy asked of the module and not yet read back (setPolicy answers through
    // policyJson, a moment later). coherePolicy judges by it, so opening a room under a
    // verb's policy (a request's monero-split) is not snapped back to the kind's first
    // policy by a policyKind that has not caught up yet (exo-dcc.5, seen in Basecamp).
    property string requestedPolicy: ""
    // The kind the person last picked in the picker. A pick the module refuses (no account
    // to act from yet) leaves policyKind where it was, so the picker shows THIS, and the
    // amount's unit follows it; Propose waits until the module has taken it (exo-dcc.31).
    property string pickedKind: ""
    readonly property string shownKind: room.pickedKind.length > 0 ? room.pickedKind : room.policyKind
    readonly property bool pickPending: room.pickedKind.length > 0 && room.pickedKind !== room.policyKind
    readonly property bool shownBtc: room.shownKind.indexOf("btc-") === 0
    readonly property bool shownLez: room.shownKind === "lez-multisig" || room.shownKind === "lez-frost"
    // the unit a payment's amount is typed in, for the kind picked
    readonly property string payUnit: room.shownBtc ? qsTr("sat") : room.shownLez ? qsTr("token units") : qsTr("wei")
    function choosePolicy(k) {
        room.requestedPolicy = String(k || "");
        // the composer's own pick (coherePolicy) is shown as picked too, so a kind refused for
        // want of an account still reads as the selection, with the remedy under it
        if (room.requestedPolicy.length > 0) room.pickedKind = room.requestedPolicy.split("@")[0];
        if (room.backend && room.requestedPolicy.length > 0) room.backend.setPolicy(room.requestedPolicy);
    }
    onPolicyErrorChanged: {
        room.requestedPolicy = "";
        // refused for want of an account this kind acts from: open the form that discloses
        // one (exo-dcc.30), in Room details › Accounts
        var e = room.policyError || {};
        if (e.error === "no-account" && room.kindNeedsAccount(room.policyKind)) room.openDetails("accounts");
    }
    // The outcome of the last room-side submit (coordinate_submit): {id, state,
    // onchain, txHash} or {id, error, ...}. Matched to a card by its intent id.
    readonly property var roomSubmit: {
        try { return JSON.parse(backend ? backend.roomSubmitJson : "{}"); }
        catch (e) { return ({}); }
    }
    // Every driver kind this client has (coordinate_drivers — the ONE list, the module's
    // drivers/kinds.nim, exo-a50.1.2): [{kind, family, label, composes, founding,
    // admitted}]. The UI names no kind of its own; `admitted` grows by approved
    // add-driver proposal (driver-as-proposal). Nothing loaded yet → no kinds, never a
    // guessed fallback list.
    readonly property var kinds: {
        try {
            var j = JSON.parse(backend ? backend.driversJson : "[]");
            return Array.isArray(j) ? j.filter(function (k) { return k && typeof k === "object"; }) : [];
        } catch (e) { return []; }
    }
    // the kinds the room has admitted (strings), as before
    readonly property var drivers: room.kinds.filter(function (k) { return k.admitted; })
                                             .map(function (k) { return String(k.kind); })
    function hasDriver(k) { return (room.drivers || []).indexOf(k) >= 0; }
    function kindInfo(k) {
        for (var i = 0; i < room.kinds.length; ++i)
            if (room.kinds[i].kind === k) return room.kinds[i];
        return null;
    }

    // What the selected kind needs from this instance's own modules and does not have
    // yet (exo-dcc.10): its `needs` from coordinate_drivers, graded here, not met. The
    // form shows each under the picker, with "Install …" where installing would help;
    // the kind itself stays on the list.
    readonly property var composeNeeds: {
        if (room.composeType === "action") return [];
        var info = room.kindInfo(room.policyKind);
        var ns = (info && Array.isArray(info.needs)) ? info.needs : [];
        return ns.filter(function (n) { return n && typeof n === "object" && String(n.status || "") !== "met"; });
    }
    // Propose waits only on a need that is definitely missing for the proposer's own
    // part: not installed, installed but not running, or failed. "unknown" and
    // "starting" warn and never block: a host that cannot tell must not stop a proposal.
    // A need another party's part has (an approver's, a payer's) never blocks proposing.
    function needBlocks(n) {
        var st = String((n && n.moduleState) || "");
        var p = String((n && n.party) || "");
        return (st === "not-installed" || st === "installed" || st === "error")
               && p !== "contributor" && p !== "payer" && p !== "counterparty";
    }
    readonly property var composeBlockers: room.composeNeeds.filter(function (n) { return room.needBlocks(n); })
    // a Monero send's payer needs no module of the kind's: they pay from any wallet (exo-dcc.32)
    readonly property bool composeBlocked: (room.composeBlockers.length > 0 && !(room.composeType === "split" && room.splitSend && room.splitMonero))
                                           || room.pickPending
    function composeNeedLine(n) {
        var info = room.kindInfo(room.policyKind);
        var label = (info && info.label) ? String(info.label) : room.policyKind;
        var name = String((n && n.name) || "");
        var d = String((n && n.detail) || "");
        var p = String((n && n.party) || "");
        return (d.length > 0 ? qsTr("%1 needs %2 (%3)").arg(label).arg(name).arg(d)
                             : qsTr("%1 needs %2").arg(label).arg(name))
             + (p === "contributor" ? qsTr(", to approve") : p === "payer" ? qsTr(", to pay your part") : "");
    }
    // "Install …" only where installing would help (as on the card)
    function needCanInstall(n) {
        var st = String((n && n.moduleState) || "");
        return String((n && n.install) || "").length > 0
               && st !== "installed" && st !== "starting" && st !== "error" && st !== "ready";
    }
    // need name → the package the form asked for it
    property var installAsked: ({})
    function needPkg(n) {
        var p = String((n && n.install) || "");
        return p.length > 0 ? p : String(room.installAsked[String((n && n.name) || "")] || "");
    }
    function installNote(pkg, item) {
        var r = room.packageReq(pkg);
        if (!r) return "";
        var st = String((item && item.moduleState) || "");
        // installed, starting, running or failed: the item's own detail and remedy say
        // what comes next, so a "Package Manager is open" line would only contradict them
        if (r.state === "open" && (st === "installed" || st === "starting" || st === "ready" || st === "error"))
            return "";
        if (r.state === "asking") return qsTr("Asking Package Manager to open %1…").arg(pkg);
        if (r.state === "open")
            return room.installNow - Number(r.at || 0) >= 180000
                   // the 3-minute re-read is over: say how to look again, never a stale promise
                   ? qsTr("Package Manager was opened on %1. To check again, close and reopen this form.").arg(pkg)
                   : qsTr("Package Manager is open on %1. Confirm the install there; this form updates once it is installed.").arg(pkg);
        if (r.state === "unavailable") return qsTr("Install %1 from Basecamp's Package Manager.").arg(pkg);
        if (r.state === "failed")
            return qsTr("%1 was not found in your catalogues. Check the catalogues in Package Manager.").arg(pkg);
        // the person cancelled Basecamp's "Use this app?" chooser, or a newer request
        // replaced this one: the broker answers both as cancelled
        if (r.state === "cancelled") return qsTr("The install request was cancelled.");
        return qsTr("Package Manager did not answer (%1). Install %2 from Basecamp's Package Manager.")
               .arg(String(r.error || "")).arg(pkg);
    }
    function askInstall(n) {
        var pkg = String((n && n.install) || "");
        if (pkg.length === 0) return;
        var m = Object.assign({}, room.installAsked);
        m[String(n.name || "")] = pkg;
        room.installAsked = m;
        room.installNow = Date.now();
        room.packageInstallRequested(pkg);
    }
    // After Package Manager opened on a package the selected kind needs, re-read the
    // kind list every 3 s, for up to 3 minutes or until that need reads met.
    property double installNow: Date.now()
    readonly property bool composeInstallAwaited: {
        var ns = room.composeNeeds;
        for (var i = 0; i < ns.length; ++i) {
            // installed but stopped, or failed: nothing changes until the person acts
            var st = String(ns[i].moduleState || "");
            if (st === "installed" || st === "error") continue;
            var r = room.packageReq(room.needPkg(ns[i]));
            if (r && r.state === "open" && room.installNow - Number(r.at || 0) < 180000) return true;
        }
        return false;
    }
    Timer {
        interval: 3000
        repeat: true
        running: room.composing && room.composeInstallAwaited
        onTriggered: {
            room.installNow = Date.now();
            if (room.composeInstallAwaited && room.backend) room.backend.loadDrivers();
        }
    }

    // Which policies COHERE with a proposal kind. The policy is HOW the room agrees;
    // the kind is WHAT it agrees to — and not every pairing means anything. An
    // ethereum payment settles on chain, so it can only go through the Safe; a
    // statement is a group endorsement, so it takes the roster policies (threshold /
    // FROST / attest / unanimous) and never the Safe (which settles a transfer, not a
    // claim); an action carries its own driver (invoke), so it shows no policy row.
    // The composer offers ONLY these for the current kind, so "payment via FROST" —
    // which meant nothing — can't be built.
    function policiesForKind(k) {
        // read from the module's one kind list (each kind says which proposals it serves)
        var out = [];
        for (var i = 0; i < room.kinds.length; ++i) {
            var c = room.kinds[i].composes || [];
            if (c.indexOf(k) >= 0) out.push(String(room.kinds[i].kind));
        }
        return out;
    }
    function policyValidForKind(p) {
        return room.policiesForKind(room.composeType).indexOf(p) >= 0;
    }
    // Snap the compose policy to one the current kind allows, so the "Next proposal"
    // selection is never left on a policy that doesn't fit the kind (e.g. after
    // switching payment→statement, or reopening the composer). No-op when it already
    // fits. Action manages its own policy in proposeAction, so it's left alone.
    function coherePolicy() {
        if (!room.backend || room.composeType === "action") return;
        var valid = room.policiesForKind(room.composeType).filter(function (p) { return room.hasDriver(p); });
        var cur = room.requestedPolicy.length > 0 ? room.requestedPolicy.split("@")[0] : room.policyKind;
        if (valid.length > 0 && valid.indexOf(cur) < 0)
            room.choosePolicy(valid[0]);
    }

    // The coordinatable module actions available to the room (loadAvailableActions):
    // [{module, method, signature, params, allowed}]. The action composer lists these;
    // picking one composes an invoke intent. Loaded when the action composer opens.
    readonly property var availableActions: {
        try { return JSON.parse(backend ? backend.availableActionsJson : "[]"); }
        catch (e) { return []; }
    }
    // The outcome of the last room-side invoke execution (executeInRoom): {id, state,
    // executed, detail} or {id, error, ...}. Matched to a card by its intent id, just
    // like roomSubmit is for a Safe settle.
    readonly property var executeResult: {
        try { return JSON.parse(backend ? backend.executeJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The outcome of the last in-app approval: {intentId, state, ok, reason}. When ok
    // is false the approval didn't count — surfaced so a rejected signature says WHY
    // instead of nothing happening (the "I clicked Approve and nothing changed" case).
    readonly property var contributeResult: {
        try { return JSON.parse(backend ? backend.contributeJson : "{}"); }
        catch (e) { return ({}); }
    }
    // Signers outside muster (exo-a50.2.6): the last export (a PSBT for an outside
    // signer) and the last import (what came back), each naming its intent.
    readonly property var outsideExport: {
        try { return JSON.parse(backend ? backend.outsideJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var outsideImport: {
        try { return JSON.parse(backend ? backend.outsideImportJson : "{}"); }
        catch (e) { return ({}); }
    }
    // the last Bitcoin payment proposal: {id} or {error, detail}
    readonly property var btcPropose: {
        try { return JSON.parse(backend ? backend.btcProposeJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The last split action's outcome (exo-a90): {op: propose|pay|confirm, id, …} or
    // {op, id, error} — so a Pay / Propose that did nothing says why.
    readonly property var splitResult: {
        try { return JSON.parse(backend ? backend.splitJson : "{}"); }
        catch (e) { return ({}); }
    }
    // a Bitcoin multisig policy: a payment in sat from the account's own coins, read
    // from the user's node — no Safe balance, no nonce (exo-a50.2.6)
    readonly property bool isBtcPolicy: room.policyKind.indexOf("btc-") === 0
    // a LEZ multisig policy (exo-3c9): a payment moves a token out of the multisig's
    // vault; proposing and approving are members' own on-chain transactions
    readonly property bool isLezPolicy: room.policyKind === "lez-multisig" || room.policyKind === "lez-frost"
    // the last LEZ proposal ({pending: "propose", index, tx} or {error, detail}), the
    // member account shown, and the last create
    readonly property var lezPropose: {
        try { return JSON.parse(backend ? backend.lezProposeJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var lezMember: {
        try { return JSON.parse(backend ? backend.lezMemberJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var lezCreate: {
        try { return JSON.parse(backend ? backend.lezCreateJson : "{}"); }
        catch (e) { return ({}); }
    }
    // the room's FROST key ceremonies, and the last open/join result (Phase D)
    readonly property var frostCeremonies: {
        try { return JSON.parse(backend ? backend.frostCeremoniesJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var frostCeremony: {
        try { return JSON.parse(backend ? backend.frostCeremonyJson : "{}"); }
        catch (e) { return ({}); }
    }
    // the room's Monero multisig setups and spends (ADR-020), parsed once; the card looks a
    // spend up by intent id, and the accounts panel shows the setups and the last results
    // lez-msig (exo-0d3): its ceremonies, the last open / propose results, the account's state
    readonly property var lezMsigCeremonies: {
        try { return JSON.parse(backend ? backend.lezMsigCeremoniesJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var lezMsigOpen: {
        try { return JSON.parse(backend ? backend.lezMsigOpenJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var lezMsigPropose: {
        try { return JSON.parse(backend ? backend.lezMsigProposeJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var lezMsigFund: {
        try { return JSON.parse(backend ? backend.lezMsigFundJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var lezMsigRecover: {
        try { return JSON.parse(backend ? backend.lezMsigRecoverJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var memberAccounts: {
        try { return JSON.parse(backend ? backend.memberAccountsJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var discloseAccount: {
        try { return JSON.parse(backend ? backend.discloseAccountJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var lezMsigState: {
        try { return JSON.parse(backend ? backend.lezMsigStateJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var xmrMsigSetups: {
        try { return JSON.parse(backend ? backend.xmrMsigSetupsJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var xmrMsigSetup: {
        try { return JSON.parse(backend ? backend.xmrMsigSetupJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var xmrMsigSpends: {
        try { return JSON.parse(backend ? backend.xmrMsigSpendsJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var xmrMsigPropose: {
        try { return JSON.parse(backend ? backend.xmrMsigProposeJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property bool xmrMsigWalletSet: {
        try { return !!JSON.parse(backend ? backend.settingsJson : "{}").xmrMsigRpc; }
        catch (e) { return false; }
    }
    function xmrMsigSpendOf(id) {
        var arr = room.xmrMsigSpends;
        for (var i = 0; i < arr.length; ++i)
            if (arr[i] && String(arr[i].intentId || "") === String(id || "")) return arr[i];
        return null;
    }
    // A LEZ multisig proposal in words: the effect carries the target program, the
    // instruction words and the accounts. A token Transfer is [0, amount (u128, 4 words)],
    // InitializeAccount is [3]; anything else is shown as the raw call.
    function lezSummary(eff, it) {
        // the LEZ v0.3 port (exo-eb6.4.4): the module reads the call in words, by exact
        // string arithmetic (effect_summary.nim); use its line
        if (String(eff.lez || "") === "v0.3" && it && it.summary && it.summary.text) {
            var t = String(it.summary.text);
            return t.charAt(0).toUpperCase() + t.slice(1);
        }
        var ins = eff.instruction || [];
        var acc = eff.accounts || [];
        var idx = String(eff.index || "?");
        function abbrev(h) { h = String(h || ""); return h.length > 16 ? h.slice(0, 8) + "…" + h.slice(-6) : h; }
        if (ins.length === 5 && Number(ins[0]) === 0 && acc.length === 2)
            return qsTr("On-chain proposal #%1: transfer %2 from the vault to %3")
                   .arg(idx).arg(Number(ins[1]) + Number(ins[2]) * 4294967296).arg(abbrev(acc[1]));
        if (ins.length === 1 && Number(ins[0]) === 3 && acc.length === 2)
            return qsTr("On-chain proposal #%1: set up the vault to hold token %2").arg(idx).arg(abbrev(acc[0]));
        return qsTr("On-chain proposal #%1: call %2 with %3 words on %4 accounts")
               .arg(idx).arg(abbrev(eff.target)).arg(ins.length).arg(acc.length);
    }
    // Whether MY share of a split has been reported paid (or confirmed) — then the card's own
    // row says so, and a "sent … once it settles" note would only go stale.
    function myPartSettled(it) {
        var parts = (it && Array.isArray(it.parts)) ? it.parts : [];
        for (var i = 0; i < parts.length; ++i)
            if (parts[i].mine) return !!(parts[i].settled || parts[i].confirmed);
        return false;
    }
    function headingFor(kind) {
        return kind === "btc-spend" ? qsTr("Proposed a Bitcoin payment")
             : kind === "lez-transfer" ? qsTr("Proposed a LEZ transfer")
             : kind === "lez-call" ? qsTr("Proposed a LEZ call")
             : kind === "lez-proposal" ? qsTr("Proposed an on-chain LEZ multisig proposal")
             : kind === "policy" ? qsTr("Proposed a new way to agree")
             : kind === "contract-call" ? qsTr("Proposed a contract call")
             : kind === "delegatecall" ? qsTr("Proposed a DELEGATECALL")
             : "";
    }
    // a Bitcoin intent that spends from a shared account — what a PSBT can carry to a signer
    // outside muster. A split or a settle-up has no shared account: each pays their own.
    function isBtcIntent(it) {
        return String((it && it.policy) || "").indexOf("btc-") === 0 && !(it && (it.split || it.settleUp));
    }
    // a Bitcoin split whose shares would be below the 546-sat dust limit can never be paid
    function splitDust(pv) { return room.splitBitcoin && pv !== null && pv !== undefined && Number(pv.each) < 546; }
    // Refresh the action menu when the action composer opens — the module queries each
    // candidate module's methods (never a blind scan), so not on the message tick.
    // Also keep the policy coherent with the kind (payment→Safe, statement→endorsement),
    // so the composer can never hold a nonsense pairing.
    onComposeTypeChanged: {
        room.pickedKind = "";
        if (composing && composeType === "action" && room.backend)
            room.backend.loadAvailableActions();
        room.coherePolicy();
    }

    // The COMPOSE DEFAULT policy (driver) for the next thing you propose here, from
    // coordinate_policy. Policy is a property of each intent, not the room — the room
    // is a security/privacy boundary, an intent is a policy boundary — so this only
    // stamps the next proposal; each card keeps the policy it was proposed under.
    readonly property var policy: {
        try { return JSON.parse(backend ? backend.policyJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The compose default's KIND ("safe", "threshold", …) — an account-bound policy is
    // "<kind>@<CAIP-10 account>" (exo-a50.1.3), so the picker compares the kind.
    readonly property string policyKind:
        (room.policy && room.policy.kind) ? String(room.policy.kind)
        : (room.policy && room.policy.policy) ? String(room.policy.policy).split("@")[0] : ""
    // the account the compose default acts from (CAIP-10), "" for a room kind
    readonly property string policyAccount: (room.policy && room.policy.account) ? String(room.policy.account) : ""
    // the last policy choice the module refused (no-account / choose-account / not admitted)
    readonly property var policyError: {
        try { return JSON.parse(backend ? backend.policyErrorJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The accounts members have disclosed into this room (coordinate_accounts, exo-a50.1.3).
    readonly property var roomAccounts: {
        try { var j = JSON.parse(backend ? backend.accountsJson : "[]"); return Array.isArray(j) ? j : []; }
        catch (e) { return []; }
    }
    readonly property var discloseResult: {
        try { return JSON.parse(backend ? backend.accountDiscloseJson : "{}"); }
        catch (e) { return ({}); }
    }
    // the disclosed accounts a kind can act from (its accountFamilies)
    function accountsForKind(k) {
        var info = room.kindInfo(k);
        var fams = (info && info.accountFamilies) ? info.accountFamilies : [];
        return room.roomAccounts.filter(function (a) { return fams.indexOf(a.family) >= 0; });
    }
    function kindNeedsAccount(k) {
        var info = room.kindInfo(k);
        return !!(info && info.accountFamilies && info.accountFamilies.length > 0);
    }

    // How many people must be in the room before a proposal can be submitted. A
    // proposal is something the room acts on together — it needs enough of the people
    // it takes to agree (the policy's threshold) present FIRST, so it lands in an epoch
    // they all share rather than one sealed to you alone (F-16). From coordinate_policy;
    // falls back to needing one other person (2) when the threshold isn't known yet.
    readonly property int requiredToPropose: {
        var t = (room.policy && room.policy.threshold !== undefined)
                ? Number(room.policy.threshold) : 0;
        return t >= 1 ? t : 2;
    }
    readonly property bool enoughToPropose: room.members.length >= room.requiredToPropose

    // Project one folded intent view onto the card vocabulary. The module's
    // lifecycle names (draft/proposed/collecting/executable/submitted/final) map to
    // the card's shorter rail (proposed/collecting/ready/paid). The one per-viewer claim,
    // approvedByMe, is what the module proves from the log + this member's keys (or an
    // approval this instance made) — never assumed (exo-59c). What the effect moves comes
    // from the module's summary, the same reading the room history uses.
    function intentToCard(it) {
        var st = String((it && it.state) || "proposed");
        // settling (some of a split's shares confirmed, exo-a90) is past agreement, like submitted
        var cardState = (st === "executable" || st === "submitted" || st === "settling") ? "ready"
                      : st === "final" ? "paid"
                      : st === "collecting" ? "collecting"
                      // closed without settling: said as such, never as "Proposed" (exo-720)
                      : st === "declined" || st === "expired" ? st : "proposed";
        var eff = (it && it.effect) ? it.effect : ({});
        var effKind = eff ? String(eff.effect || "") : "";
        var isStatement = effKind === "statement";
        // driver-as-proposal: an add-driver governance intent renders as a decision to
        // grant the room a new policy (reusing the statement text slot for the sentence).
        var isGovernance = effKind === "add-driver";
        // a generic module action (P-D4): the effect names module.method(args); the card
        // shows "call module.method(…)" instead of amount → destination.
        var isInvoke = effKind === "invoke";
        var invokeArgs = (isInvoke && eff.args) ? eff.args : [];
        var isLez = effKind === "lez-multisig-proposal";
        // a lez-msig proposal (exo-0d3): the module decodes it from the bytes approvals sign
        var isMsig = effKind === "lez-msig";
        // a split (exo-a90): its own body on the card — who owes what, and where each stands
        var isSplit = effKind === "split";
        // a settle-up (exo-3c6): several splits netted — its own body: the net payments
        var isSettleUp = effKind === "settle-up";
        // a payment request (exo-dcc.5): one share, the creditor's own share nothing
        var isRequest = isSplit && it && it.split && Array.isArray(it.parts) && it.parts.length === 1
                        && String(it.split.creditorShare || "") === "0";
        return {
            kind: "intent-propose",
            split: (isSplit && it && it.split) ? it.split : null,
            settleUp: (isSettleUp && it && it.settleUp) ? it.settleUp : null,
            parts: (isSplit && it && Array.isArray(it.parts)) ? it.parts : [],
            // who proposed it, by their signed claim (exo-770); [] = unattributed
            proposedBy: (it && Array.isArray(it.proposedBy)) ? it.proposedBy : [],
            label: isSettleUp ? qsTr("Settle up") : isRequest ? qsTr("Request") : isSplit ? qsTr("Split")
                 : isGovernance ? qsTr("A new way to agree")
                 : isLez ? qsTr("LEZ multisig")
                 : isMsig ? qsTr("LEZ multisig")
                 : isInvoke ? qsTr("Action")
                 : isStatement ? qsTr("Statement") : qsTr("Payment"),
            // an invoke intent's target, rendered by the card as "call module.method(…)".
            action: isInvoke ? (String(eff.module || "") + "." + String(eff.method || "")) : "",
            actionArgs: invokeArgs,
            // a statement the room ratifies, or a governance decision — the card shows
            // the text instead of amount → destination.
            statement: isGovernance
                     ? qsTr("Let the room agree by “%1”").arg(String(eff.kind || ""))
                     : isLez ? room.lezSummary(eff, it)
                     : isStatement ? String(eff.text || "") : "",
            // a LEZ step the chain has not included yet: "vote" | "settle" (exo-3c9)
            chainPending: (it && it.chainPending) ? String(it.chainPending) : "",
            amount: (isSplit || isSettleUp) ? ""
                  : (!isStatement && eff.value !== undefined) ? String(eff.value)
                  : (it && it.summary && it.summary.amount) ? String(it.summary.amount) : "",
            denom: (isSplit || isSettleUp) ? "" : (it && it.summary && it.summary.unit) ? String(it.summary.unit) : "",
            to: (isSplit || isSettleUp) ? ""
              : (!isStatement && eff.to !== undefined) ? String(eff.to)
              : (it && it.summary && it.summary.to && !isInvoke && !isLez) ? String(it.summary.to) : "",
            // the heading, in the family's words (a Bitcoin payment, a LEZ transfer, a new policy…)
            heading: isSettleUp ? qsTr("Proposed to settle up") : isRequest ? qsTr("Requested a payment")
                   : isSplit ? qsTr("Proposed a split")
                   : room.headingFor(it && it.summary ? String(it.summary.kind || "") : ""),
            // who approved, named (or "you"), and whether I did (exo-59c)
            approvers: (it && Array.isArray(it.approvers)) ? it.approvers : [],
            approvedByMe: !!(it && it.approvedByMe),
            declinerNames: (it && Array.isArray(it.declinerNames)) ? it.declinerNames : [],
            // a full Safe transaction's own fields (exo-a50.1.4): what it calls and HOW —
            // a DELEGATECALL runs the target's code as the Safe, so the card must say so
            safeData: (!isStatement && eff.data !== undefined) ? String(eff.data) : "",
            // the card's fixed rows + the family profile (exo-a50.1.6): the same ten
            // questions for every multisig family, answered by the module from the profile
            rows: (it && Array.isArray(it.rows)) ? it.rows : [],
            profile: (it && it.profile) ? it.profile : null,
            operation: (!isStatement && eff.operation !== undefined) ? Number(eff.operation) : 0,
            rail: (it && it.rail) ? String(it.rail) : "safe",
            threshold: Number((it && it.threshold) || 0),
            n: Number((it && it.n) || 0),
            approvals: Number((it && it.approvals) || 0),
            // how many approvals commit to their inputs (signed in muster, attested) vs
            // were signed outside muster and pasted in (exo-ef1). Older payloads carry
            // neither: treat every approval as committed-unknown by leaving both 0.
            committed: Number((it && it.committed) || 0),
            unattested: Number((it && it.unattested) || 0),
            state: cardState,
            stage: st,                       // the lifecycle state, for the status in words (exo-ce0)
            // the verify view: the re-derived safeTxHash and the domain it binds to
            txhash: (it && it.txhash) ? String(it.txhash) : "",
            chainId: (it && it.chainId !== undefined) ? Number(it.chainId) : 0,
            safe: (it && it.safe) ? String(it.safe) : "",
            environment: (it && it.environment) ? String(it.environment) : "",
            // the provenance lineage: how this decision's data got here (inv 10)
            provenance: (it && it.provenance) ? it.provenance : [],
            // multi-round (FROST): the round chrome the card header renders
            rounds: Number((it && it.rounds) || 1),
            round: Number((it && it.round) || 1),
            roundApprovals: Number((it && it.roundApprovals) || 0),
            policy: (it && it.kind) ? String(it.kind) : (it && it.policy) ? String(it.policy).split("@")[0] : "",
            // who declined to take part
            declines: Number((it && it.declines) || 0),
            decliners: (it && it.decliners) ? it.decliners : [],
            declinedByMe: !!(it && it.decliners && room.myIdentity
                             && it.decliners.indexOf(room.myIdentity) >= 0),
            // a lez-msig proposal, decoded from the bytes its approvals sign (RFP U.6)
            msig: (isMsig && it && it.msig) ? it.msig : null,
            // a Monero multisig spend's progress (ADR-020), null for any other intent
            xmrMsig: room.xmrMsigSpendOf(it && it.id),
            // the five questions + your readiness, once asked for
            readiness: room.readinessFor(it && it.id),
            // "From you": which of my own holdings fill the slots this asks of me (K6)
            offers: room.offersFor(it && it.id),
            // the declared schema + whether muster recognizes it (exo-1ec.3). When it does
            // not, the card renders a NAMED "schema unknown" failure instead of the body
            // below — an activity renders only from a declared, versioned schema.
            schemaId: (it && it.schemaId) ? String(it.schemaId) : "",
            // default TRUE so an older payload (no field) still renders as before, never a
            // spurious failure; only an explicit false gates the render.
            schemaKnown: (it && it.schemaKnown !== undefined) ? !!it.schemaKnown : true
        };
    }

    // Resolve a thread ref card to its live intent (verified fold), by id. Returns
    // null until the fold has it — the thread then shows a quiet placeholder rather
    // than inventing a card.
    function intentById(id) {
        var arr = room.intents;
        for (var i = 0; i < arr.length; ++i)
            if (arr[i] && String(arr[i].id || "") === String(id))
                return arr[i];
        return null;
    }

    // Put a real proposal to the room through the verified path: the module
    // canonicalizes the effect to the EIP-712 safeTxHash and folds it as a
    // content-addressed intent, then announces it into the thread as an intent-ref
    // card. The nonce is the Safe's LIVE on-chain nonce (from coordinate_account),
    // which the safeTxHash commits to — so sequential settles each use the right one
    // (the Safe increments it per execTransaction). Falls back to 0 when the account
    // read is unavailable. A blank/zero amount is allowed; the recipient is required.
    // Would this payment amount exceed the Safe's KNOWN balance? True only when the
    // balance was actually read (never on an error/unknown — we don't block what we
    // can't check, and never a false zero). Drives both the hard block on the propose
    // button and the refusal in proposeFrom (exo-bf9 — can't over-send).
    // Pre-fill the payment composer from the "Start something" draft instead of
    // proposing it straight away: a proposal must wait until the room has the people to
    // act on it (see the Propose gate), so we carry the amount/recipient into the
    // composer and let you submit once they've joined — never into an empty room.
    function prefillPayment(toAddr, valStr) {
        room.composeType = "payment";
        room.composing = true;
        proposeTo.text = String(toAddr || "");
        proposeValue.text = String(valStr || "");
    }

    // Admit the person "Start something" named the moment their join-request lands —
    // you already chose them, so the room keys to them without a manual Admit (or a
    // manual "ask to join" on their side, which is already automatic). The module still
    // verifies their binding on admit (F-9); this just removes the click. Runs on every
    // pending refresh; the autoAdmitted guard stops a double-admit.
    function autoAdmitExpected() {
        if (!room.backend || room.expectedMember.length === 0) return;
        var want = room.expectedMember.replace(/^0x/i, "").toLowerCase();
        var p = room.pending;
        for (var i = 0; i < p.length; ++i) {
            var raw = String((p[i] && p[i].identity) || "");
            var id = raw.replace(/^0x/i, "").toLowerCase();
            if (id === want && !room.autoAdmitted[id]) {
                room.autoAdmitted[id] = true;
                room.backend.admit(raw);
                room.resendOutstandingAsk();
                room.backend.reannounce();
                return;
            }
        }
    }
    onPendingChanged: room.autoAdmitExpected()

    // Re-send an UNANSWERED address request into the current epoch, so a just-admitted
    // member is actually asked to disclose — they can't read a request posted before
    // they joined (F-16 re-keys on admit). Called from onAdmit. Scans the thread: if the
    // most recent address-request has no address-share after it, post a fresh one.
    function resendOutstandingAsk() {
        if (!room.backend) return;
        var msgs = room.messages;
        var pending = false;
        for (var i = 0; i < msgs.length; ++i) {
            var o = null;
            try { o = JSON.parse(msgs[i].body); } catch (e) { o = null; }
            if (!o) continue;
            var k = String(o.kind || "");
            if (k === "address-request") pending = true;
            else if (k === "address-share") pending = false;
        }
        if (pending)
            room.backend.postMessage(JSON.stringify({
                kind: "address-request", intent: "pay",
                purpose: qsTr("Pay someone from the room")
            }));
    }

    function overSends(valueStr) {
        if (!room.roomAsset || room.roomAsset.error) return false;
        var amt = parseFloat(valueStr || "0");
        var avail = parseFloat(room.roomAsset.raw || "0");
        return amt > 0 && amt > avail;
    }
    function proposeFrom(toAddr, valueStr) {
        if (!room.backend || String(toAddr).length === 0)
            return;
        // Can't over-send: a value above the Safe's known balance would revert on-chain,
        // so refuse it here rather than propose a payment that cannot settle (exo-bf9).
        if (room.overSends(valueStr))
            return;
        var v = parseInt(valueStr, 10);
        if (isNaN(v) || v < 0) v = 0;
        var n = (room.roomAccount && room.roomAccount.nonce !== undefined)
                ? parseInt(room.roomAccount.nonce, 10) : 0;
        if (isNaN(n) || n < 0) n = 0;
        room.backend.proposeInRoom(JSON.stringify({
            to: String(toAddr), value: v, nonce: n
        }));
        room.composing = false;
    }

    // ── a split (exo-a90): you fronted a bill; the people named each owe you a share ──
    // Money is decimal TEXT end to end (the module's amounts are canonical decimal wei), so
    // ETH ↔ wei is string arithmetic here — never a float, never a rounding surprise.
    property var splitOut: ({})              // members left OUT of the next split (identity → true)
    property bool splitCreditorShares: true  // "I'm in it too": the total is shared with you
    // Who fronted the next split (exo-770): "" = you. Anyone else is the creditor you
    // propose it for — paid at the address THEY shared, and payable only once they agree.
    // A private split is proposed only by whoever fronted it (their shielded key node is
    // not shared in the room).
    property string splitCreditor: ""
    readonly property string splitFor: room.splitRequest ? "" : room.splitSend ? room.sendTo
                                       : (room.splitPrivate || room.splitBitcoin) ? "" : room.splitCreditor
    // "Send" (exo-dcc.32, .33): one payment from you to one member, in any asset a split
    // takes (XMR, ETH or a token, BTC, LEZ) — a split on their behalf with you its only
    // payer. Paid at the address they shared; proposing it is your agreement, so it is
    // payable once they accept.
    property bool splitSend: false
    // who you send to: the member picked, else the only other member
    readonly property string sendTo: {
        if (!room.splitSend) return "";
        var others = [];
        for (var k = 0; k < room.members.length; ++k)
            if (room.members[k] && !room.members[k].self) others.push(String(room.members[k].identity || ""));
        if (room.splitCreditor.length > 0 && others.indexOf(room.splitCreditor) >= 0) return room.splitCreditor;
        return others.length === 1 ? others[0] : "";
    }

    // where the split for someone else is paid: the address they shared — on Monero, the
    // subaddress their own wallet minted for this chain (exo-dcc.20)
    readonly property string splitForAddress: room.splitFor.length === 0 ? ""
                                            : room.splitMonero ? (room.splitForAddressUsed ? ""
                                                                  : room.sharedMoneroAddressOf(room.splitFor, room.splitMoneroChain))
                                            : room.splitBitcoin ? room.sharedBtcAddressOf(room.splitFor)
                                            : room.splitPrivate ? room.sharedLezAddressOf(room.splitFor)
                                            : room.sharedAddressOf(room.splitFor)
    // Their newest shared Monero address already backs a payment in this room: their wallet
    // confirms by amount at a subaddress, so one address can't back two payments, and the
    // module refuses it (shared-address-used). The form asks them for a new one instead.
    readonly property bool splitForAddressUsed: room.splitMonero && room.splitFor.length > 0
        && room.moneroPayToUsed(room.sharedMoneroAddressOf(room.splitFor, room.splitMoneroChain))
    // Whether a Monero payment proposed in this room pays `addr` — the module's own rule
    // (moneroPayTosInUse): every Monero split proposed here, whatever became of it.
    function moneroPayToUsed(addr) {
        var a = String(addr || "");
        if (a.length === 0) return false;
        var its = room.intents || [];
        for (var i = 0; i < its.length; ++i) {
            var e = its[i] ? its[i].effect : null;
            if (e && String(e.effect || "") === "split" && String(e.chain || "").indexOf("monero:") === 0
                && String(e.payTo || "") === a) return true;
        }
        return false;
    }
    function memberLabel(identity) {
        var id = String(identity || "").toLowerCase();
        for (var i = 0; i < room.members.length; ++i) {
            var m = room.members[i];
            if (m && String(m.identity || "").toLowerCase() === id)
                return m.self ? qsTr("you") : (m.alias && String(m.alias).length > 0) ? String(m.alias) : id.slice(0, 10) + "…";
        }
        return id.slice(0, 10) + "…";
    }
    // The Ethereum address `identity` last shared into the room ("" = none) — shown so you
    // can see where the split will pay; the module reads the same share from the log itself.
    function sharedAddressOf(identity) {
        // an author is compared as hex, with or without "0x"
        var bare = function (s) { return String(s || "").toLowerCase().replace(/^0x/, ""); };
        var id = bare(identity), out = "";
        for (var i = 0; i < room.messages.length; ++i) {
            var msg = room.messages[i];
            if (!msg || bare(msg.author) !== id) continue;
            var o = null;
            try { o = JSON.parse(msg.body); } catch (e) { o = null; }
            if (!o || String(o.kind || "") !== "address-share" || String(o.asset || "ETH") !== "ETH") continue;
            var a = String(o.address || "").toLowerCase();
            if (/^0x[0-9a-f]{40}$/.test(a) && !/^0x0{40}$/.test(a)) out = a;
        }
        return out;
    }
    // An address-request's answers (exo-8e2): the address-share cards posted after it (its
    // position `index` in the thread) of the kind it asks for — BTC on its chain, or an
    // Ethereum address — each with who shared it, as each member disclosed it (inv 9).
    function addressAnswers(index, req) {
        var out = [];
        var asset = String((req && req.asset) || "ETH");
        var chain = String((req && req.chain) || "");
        for (var j = index + 1; j < room.messages.length; ++j) {
            var m = room.messages[j];
            if (!m) continue;
            var o = null;
            try { o = JSON.parse(m.body); } catch (e) { o = null; }
            if (!o || String(o.kind || "") !== "address-share" || String(o.asset || "ETH") !== asset) continue;
            if (chain.length > 0 && String(o.chain || "").length > 0 && String(o.chain) !== chain) continue;
            var addr = String(o.address || "");
            if (addr.length === 0) continue;
            out.push({ who: String(m.author || "").toLowerCase().replace(/^0x/, ""), self: !!m.self,
                       name: m.self ? qsTr("you") : room.memberLabel(String(m.author || "")), address: addr });
        }
        return out;
    }
    // The Monero address a member last shared for `chain` (an address-share card of asset
    // XMR on that chain), exactly as written — a Monero address is case-sensitive. The
    // module reads the same share from the log, and their own client checks it is theirs.
    function sharedMoneroAddressOf(identity, chain) {
        var bare = function (s) { return String(s || "").toLowerCase().replace(/^0x/, ""); };
        var id = bare(identity), out = "";
        for (var i = 0; i < room.messages.length; ++i) {
            var msg = room.messages[i];
            if (!msg || bare(msg.author) !== id) continue;
            var o = null;
            try { o = JSON.parse(msg.body); } catch (e) { o = null; }
            if (o && String(o.kind || "") === "address-share" && String(o.asset || "") === "XMR"
                && String(o.chain || "") === String(chain) && String(o.address || "").length > 0) out = String(o.address);
        }
        return out;
    }
    function sharedLezAddressOf(identity) {
        // the LEZ key node a member last shared (asset LEZ, exo-dcc.33): what a private
        // payment sent to them is paid at; the module holds it to the zone
        var bare = function (s) { return String(s || "").toLowerCase().replace(/^0x/, ""); };
        var id = bare(identity), out = "";
        for (var i = 0; i < room.messages.length; ++i) {
            var msg = room.messages[i];
            if (!msg || bare(msg.author) !== id) continue;
            var o = null;
            try { o = JSON.parse(msg.body); } catch (e) { o = null; }
            if (o && String(o.kind || "") === "address-share" && String(o.asset || "") === "LEZ"
                && String(o.address || "").length > 0) out = String(o.address);
        }
        return out;
    }
    function sharedBtcAddressOf(identity) {
        // the Bitcoin address a member last shared (the address-share card's asset BTC)
        var bare = function (s) { return String(s || "").toLowerCase().replace(/^0x/, ""); };
        var id = bare(identity), out = "";
        for (var i = 0; i < room.messages.length; ++i) {
            var msg = room.messages[i];
            if (!msg || bare(msg.author) !== id) continue;
            var o = null;
            try { o = JSON.parse(msg.body); } catch (e) { o = null; }
            if (o && String(o.kind || "") === "address-share" && String(o.asset || "") === "BTC"
                && String(o.address || "").length > 0) out = String(o.address);
        }
        return out;
    }
    // The rail the next split settles on (the "Settles on" row): its unit and decimals —
    // ETH has 18, the LEZ 9, BTC 8 — and whether it is the private split (exo-a90.9) or a
    // Bitcoin one (exo-d17: in satoshis, each payer from their own key, no token, and only
    // whoever fronted it proposes — the room's shared addresses are Ethereum ones).
    readonly property bool splitPrivate: room.policyKind === "lez-split"
    readonly property bool splitBitcoin: room.policyKind === "btc-split"
    // A Monero request (exo-dcc.5, ADR-018): in XMR, 12 decimals. Its payTo is a fresh
    // subaddress the proposer's OWN open wallet makes when it is proposed — never typed —
    // and each person pays from any Monero wallet with a monero: link. No token, no
    // other currency, never netted, and only whoever is owed proposes it here.
    readonly property bool splitMonero: room.policyKind === "monero-split"
    onSplitMoneroChanged: if (room.splitMonero) room.splitFiat = false
    // the Monero chain the next request names: the policy's, else stagenet (ADR-018)
    readonly property string splitMoneroChain: {
        var a = room.policyAccount, pol = String((room.policy && room.policy.policy) || "");
        if (a.indexOf("monero:") === 0) return a;
        var at = pol.indexOf("@");
        if (at > 0 && pol.slice(at + 1).indexOf("monero:") === 0) return pol.slice(at + 1);
        return "monero:76ee3cc98646292206cd3e86f74d88b4";
    }
    function moneroChainLabel(chain) {
        var c = String(chain || "");
        return c === "monero:418015bb9ae982a1975da7d79277c270" ? qsTr("Monero mainnet")
             : c === "monero:48ca7cd3c8de5b6a4d53d2861fbdaedc" ? qsTr("Monero testnet")
             : c === "monero:76ee3cc98646292206cd3e86f74d88b4" ? qsTr("Monero stagenet") : c;
    }
    // "Request a payment" (exo-dcc.5): a split with ONE person who pays and you not in it.
    property bool splitRequest: false
    property string splitPayer: ""           // who pays, when more than one could
    onSplitRequestChanged: room.splitCreditorShares = !room.splitRequest
    // whether the creditor's own share is in the total: never in a request
    readonly property bool splitCreditorIn: room.splitCreditorShares && !room.splitRequest && !room.splitSend
    // An Ethereum split may be paid in a token (exo-5ab): the address typed, and what the
    // token says about itself once looked up — its decimals and symbol, display only.
    property string splitToken: ""
    readonly property var splitTokenInfo: {
        if (room.splitPrivate || room.splitBitcoin || room.splitMonero || room.splitToken.length === 0 || !room.backend) return null;
        var j = {};
        try { j = JSON.parse(String(room.backend.tokenInfoJson || "{}")); } catch (e) { return null; }
        return (j && !j.error && String(j.token || "") === room.splitToken.toLowerCase()) ? j : null;
    }
    readonly property int splitDecimals: room.splitPrivate ? 9 : room.splitBitcoin ? 8 : room.splitMonero ? 12
                                       : room.splitTokenInfo ? Number(room.splitTokenInfo.decimals) : 18
    readonly property string splitUnit: room.splitPrivate ? "LEZ" : room.splitBitcoin ? "BTC" : room.splitMonero ? "XMR"
                                      : room.splitTokenInfo ? (String(room.splitTokenInfo.symbol || "") || qsTr("units"))
                                      : "ETH"
    // Settle up across assets and chains (exo-a90.17): paid in this rail's asset; every other
    // asset the room owes in, priced at the rate typed here — the proposer's recorded quote.
    property bool acrossOpen: false
    property bool acrossPending: false      // proposed; the box closes only once it is accepted
    property var acrossRates: ({})          // "chain|asset" → the typed rate, per ONE unit
    // A refusal keeps the box and its rates; success closes it (exo-a90.17).
    property double splitResultAt: 0
    // A Monero wallet refusal is over once Monero Wallet answered that the wallet it named
    // is open — after the refusal (exo-dcc.20, seen on display): its words and its Open
    // Monero Wallet give way to that answer and "Try again".
    readonly property bool moneroRefusalResolved: {
        var r = room.splitResult || {}, w = room.moneroWallet || {};
        return String(r.request || "") === "monero.wallet.unlock"
               && String(w.intent || "") === "monero.wallet.unlock" && String(w.state || "") === "open"
               && Number(w.at || 0) >= room.splitResultAt;
    }
    onSplitResultChanged: {
        room.splitResultAt = Date.now();
        room.moneroStateAt = Date.now();     // a newer answer: an older wallet note is stale (exo-dcc.20)
        if (!room.acrossPending || !room.splitResult || room.splitResult.op !== "settle-up") return;
        room.acrossPending = false;
        if (!room.splitResult.error) { room.acrossOpen = false; room.composing = false; }
    }
    // a no-address refusal answered: the member named has since shared an address of that kind
    readonly property bool noAddressAnswered: {
        var r = room.splitResult || {};
        if (String(r.error || "") !== "no-address") return false;
        var who = String(r.who || "");
        return String(r.chain || "").indexOf("bip122:") === 0 ? room.sharedBtcAddressOf(who).length > 0
                                                               : room.sharedAddressOf(who).length > 0;
    }
    readonly property var openAssets: {
        try { return JSON.parse(backend ? String(backend.openAssetsJson || "{}") : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property string acrossPayAsset: room.splitBitcoin ? "BTC"
                                           : room.splitTokenInfo ? String(room.splitTokenInfo.asset) : "ETH"
    readonly property var acrossOthers: {
        var out = [];
        var a = (room.openAssets && room.openAssets.assets) || [];
        for (var i = 0; i < a.length; ++i)
            if (!(String(a[i].chain) === String(room.openAssets.payChain || "")
                  && String(a[i].asset) === room.acrossPayAsset)) out.push(a[i]);
        return out;
    }
    readonly property var acrossPriced: {
        var out = [];
        for (var i = 0; i < room.acrossOthers.length; ++i) {
            var o = room.acrossOthers[i];
            var r = String(room.acrossRates[o.chain + "|" + o.asset] || "").trim();
            if (r.length > 0) out.push({chain: String(o.chain), asset: String(o.asset), rate: r});
        }
        return out;
    }
    // a token typed but not (yet) readable: the split cannot be composed in it
    readonly property bool splitTokenPending: !room.splitPrivate && !room.splitBitcoin && !room.splitMonero && room.splitToken.length > 0
                                              && room.splitTokenInfo === null
    function ethToWei(eth, decimals) {
        var dec = (decimals === undefined) ? room.splitDecimals : decimals;
        var s = String(eth || "").trim();
        if (!new RegExp("^[0-9]+(\\.[0-9]{0," + dec + "})?$").test(s)) return "";
        var parts = s.split(".");
        var frac = (parts.length > 1 ? parts[1] : "");
        while (frac.length < dec) frac += "0";
        var w = String(parts[0] + frac).replace(/^0+/, "");
        return w.length > 0 ? w : "0";
    }
    function weiToEth(wei, decimals) {
        var dec = (decimals === undefined) ? room.splitDecimals : decimals;
        var s = String(wei || "0").replace(/^0+/, "");
        if (s.length === 0) return "0";
        while (s.length <= dec) s = "0" + s;
        var whole = s.slice(0, s.length - dec), frac = s.slice(s.length - dec).replace(/0+$/, "");
        return frac.length > 0 ? whole + "." + frac : whole;
    }
    // A canonical decimal string ÷ a small integer: [quotient, remainder] (long division).
    function divSmall(dec, n) {
        var q = "", r = 0, s = String(dec || "0");
        for (var i = 0; i < s.length; ++i) {
            var cur = r * 10 + Number(s.charAt(i));
            q += String(Math.floor(cur / n));
            r = cur % n;
        }
        q = q.replace(/^0+/, "");
        return [q.length > 0 ? q : "0", r];
    }
    // A canonical decimal string + a small integer.
    function addSmall(dec, k) {
        var s = String(dec || "0"), out = "", carry = k;
        for (var i = s.length - 1; i >= 0; --i) {
            var d = Number(s.charAt(i)) + carry;
            out = String(d % 10) + out;
            carry = Math.floor(d / 10);
        }
        while (carry > 0) { out = String(carry % 10) + out; carry = Math.floor(carry / 10); }
        return out.replace(/^0+/, "") || "0";
    }
    // Who owes in the next split: every member but whoever fronted it, unless left out.
    function splitDebtors() {
        var out = [];
        if (room.splitSend) return room.myIdentity.length > 0 ? [room.myIdentity] : [];   // you pay it
        if (room.splitRequest) {
            // one person: the one picked, else the only other member
            var others = [];
            for (var k = 0; k < room.members.length; ++k)
                if (room.members[k] && !room.members[k].self) others.push(String(room.members[k].identity || ""));
            if (room.splitPayer.length > 0 && others.indexOf(room.splitPayer) >= 0) return [room.splitPayer];
            return others.length === 1 ? others : [];
        }
        var cred = room.splitFor.toLowerCase();
        for (var i = 0; i < room.members.length; ++i) {
            var m = room.members[i];
            if (!m) continue;
            var id = String(m.identity || "");
            if (cred.length === 0 ? m.self : id.toLowerCase() === cred) continue;
            if (!room.splitOut[id]) out.push(id);
        }
        return out;
    }
    function splitToggle(identity) {
        var o = Object.assign({}, room.splitOut);
        if (o[identity]) delete o[identity]; else o[identity] = true;
        room.splitOut = o;
    }
    // What each debtor owes and what stays yours, rounded down the way the module
    // rounds (evenShares): {each, mine} in wei, or null when there is nothing to split.
    // A bill in another currency (exo-3a4): the total typed in that currency, the rate
    // this member quotes (the asset per ONE unit of it) and where the rate came from. The
    // module converts exactly and records the quote with the proposal (invariant 10); the
    // preview converts the same way, by string arithmetic — never a float.
    property bool splitFiat: false
    property string splitFiatCurrency: "EUR"
    property string splitFiatRate: ""
    property string splitFiatSource: ""
    // a Monero request's confirmation depth: the payee's wallet counts a payment once it is
    // this deep (1-720, 10 by default). Agreed in the request (stasher.news feedback, 2026-10).
    property string splitXmrDepth: "10"
    readonly property bool splitXmrDepthOk: /^[1-9][0-9]{0,2}$/.test(String(room.splitXmrDepth).trim())
                                            && Number(String(room.splitXmrDepth).trim()) <= 720
    function fiatDecimals(cur) {
        if (["JPY", "KRW", "VND", "CLP", "ISK", "UGX", "PYG", "RWF", "XAF", "XOF", "KMF", "GNF", "VUV", "XPF", "DJF"].indexOf(cur) >= 0) return 0;
        if (["BHD", "KWD", "OMR", "JOD", "TND", "LYD", "IQD"].indexOf(cur) >= 0) return 3;
        return 2;
    }
    // two canonical decimal strings multiplied (schoolbook, exact)
    function mulDec(a, b) {
        a = String(a); b = String(b);
        var res = [];
        for (var k = 0; k < a.length + b.length; ++k) res.push(0);
        for (var i = a.length - 1; i >= 0; --i)
            for (var j = b.length - 1; j >= 0; --j) {
                var p = Number(a.charAt(i)) * Number(b.charAt(j)) + res[i + j + 1];
                res[i + j + 1] = p % 10;
                res[i + j] += Math.floor(p / 10);
            }
        return res.join("").replace(/^0+/, "") || "0";
    }
    // the bill converted into the asset's base units at the typed rate ("" = not yet valid)
    function fiatTotal(amount) {
        var cur = String(room.splitFiatCurrency || "").trim().toUpperCase();
        if (!/^[A-Z]{3}$/.test(cur)) return "";
        var fd = room.fiatDecimals(cur);
        var f = room.ethToWei(amount, fd), r = room.ethToWei(room.splitFiatRate, room.splitDecimals);
        if (f.length === 0 || r.length === 0 || f === "0" || r === "0") return "";
        var p = room.mulDec(f, r);
        var t = fd > 0 ? p.slice(0, Math.max(0, p.length - fd)) : p;
        return t.replace(/^0+/, "") || "0";
    }
    function splitTotalOf(totalText) { return room.splitFiat ? room.fiatTotal(totalText) : room.ethToWei(totalText); }
    function splitPreview(totalEth) {
        var total = room.splitTotalOf(totalEth);
        var n = room.splitDebtors().length;
        if (total.length === 0 || total === "0" || n === 0) return null;
        var parts = n + (room.splitCreditorIn ? 1 : 0);
        var qr = room.divSmall(total, parts);
        return { each: qr[0], mine: room.addSmall(room.splitCreditorIn ? qr[0] : "0", qr[1]), total: total, n: n };
    }
    function proposeSplit(totalEth, memo) {
        if (!room.backend) return;
        var total = room.splitTotalOf(totalEth);
        var who = room.splitDebtors();
        if (total.length === 0 || who.length === 0) return;
        if (room.splitTokenPending) return;
        if (room.splitFor.length > 0 && room.splitForAddress.length === 0) return;
        if (room.splitSend && room.splitFor.length === 0) return;   // a send names who it goes to
        var spec = { parties: who, creditorShares: room.splitCreditorIn };
        // a send: the whole amount is your one share, paid to them (exo-dcc.32)
        if (room.splitSend) spec = { shares: [{ who: who[0], amount: total }] };
        if (room.splitFor.length > 0) spec.creditor = room.splitFor;   // on their behalf (exo-770)
        if (room.splitMonero) {
            // the depth is part of what everyone agrees to; 10 is the default and is left unsaid
            if (!room.splitXmrDepthOk) return;
            var depth = String(room.splitXmrDepth).trim();
            if (depth !== "10") spec.confirmations = depth;
        }
        if (room.splitTokenInfo) spec.asset = String(room.splitTokenInfo.asset);   // exo-5ab
        if (room.splitFiat) {
            if (String(room.splitFiatSource).trim().length === 0) return;   // a quote names its source
            spec.fiat = { currency: String(room.splitFiatCurrency).trim().toUpperCase(), amount: String(totalEth).trim(),
                          rate: String(room.splitFiatRate).trim(), source: String(room.splitFiatSource).trim() };
        }
        // chain "" = the chain your configured RPC serves — or, under the Monero kind,
        // stagenet (ADR-018); it is written into the split, so everyone reviews it before
        // agreeing. A Monero payTo is minted by your own open wallet, never typed here.
        room.backend.proposeSplit("", total, JSON.stringify(spec), String(memo || ""));
        room.composing = false;
    }

    // A statement the room ratifies (a second effect type). It canonicalizes under
    // any driver whose materialization is the base serialization — the threshold
    // driver — producing a signed group endorsement rather than a chain transfer.
    function proposeStatement(text) {
        if (!room.backend || String(text).length === 0)
            return;
        room.backend.proposeInRoom(JSON.stringify({
            effect: "statement", text: String(text)
        }));
        room.composing = false;
    }

    // A generic module action (P-D4): coordinate calling module.method(args). The
    // policy for THIS proposal is the invoke driver (k-of-n over the room roster) — the
    // action itself lives in the effect, so the same propose/contribute/fold path
    // coordinates it, and coordinate_execute runs it once the room endorses it. argsText
    // is a JSON array; a blank or unparseable value falls back to []. Idempotent id:
    // the same call composes the same content-addressed intent.
    function proposeAction(action, argsText, counterparty, chain) {
        if (!room.backend || !action) return;
        var args = [];
        var raw = String(argsText || "").trim();
        if (raw.length > 0) {
            try {
                var parsed = JSON.parse(raw);
                if (Array.isArray(parsed)) args = parsed;
            } catch (e) { args = []; }   // never send fiction — empty on a bad parse
        }
        // the invoke driver governs this proposal; each card keeps its own policy.
        room.backend.setPolicy("invoke");
        var effect = {
            effect: "invoke",
            module: String(action.module || ""),
            method: String(action.method || ""),
            args: args
        };
        // Mode B — a coordinated transfer (exo-45e): naming which arg holds the recipient
        // (counterparty) and the chain makes the invoke manifest declare a counterparty
        // address slot the room asks the recipient to fill (coordinate_share_material), plus
        // the proposer's lez-account requirement for a lez:* chain. Omitted → a plain invoke.
        var cp = String(counterparty || "").trim();
        if (cp.length > 0) {
            effect.counterparty = cp;
            var ch = String(chain || "").trim();
            if (ch.length > 0) effect.chain = ch;
        }
        room.backend.proposeInRoom(JSON.stringify(effect));
        room.chosenAction = null;
        room.composing = false;
    }

    // Esc in a room closes what is on top of the conversation: the details drawer, else the
    // proposal panel (exo-720.12, U-10). A popup (Invite, ⋯, the picker) closes itself first.
    Shortcut {
        sequences: [StandardKey.Cancel]
        enabled: room.visible && (room.mapOpen || room.detailsShown || room.composing)
        onActivated: room.mapOpen ? (room.mapOpen = false) : room.detailsShown ? room.closeDetails() : (room.composing = false)
    }
    // the same, for a host where the Shortcut does not fire (see Main.qml's Ctrl+K)
    Keys.onEscapePressed: function (event) {
        if (room.mapOpen) { room.mapOpen = false; event.accepted = true; }
        else if (room.detailsShown) { room.closeDetails(); event.accepted = true; }
        else if (room.composing) { room.composing = false; event.accepted = true; }
        else event.accepted = false;
    }

    // ── the room's layout (exo-720.7, exo-720.8) ──────────────────────────
    // The conversation owns the screen: the header, the pinned proposal, the thread, the
    // join requests, the composer, the scope line. Room details is a drawer: beside the
    // thread when the room is wide enough to keep the thread at 640 px or more, over it
    // when not.
    readonly property bool detailsDocked: room.width - 360 >= 640
    readonly property bool detailsShown: room.joined && room.detailsOpen

    Item {
        id: mainColumn
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: room.detailsShown && room.detailsDocked ? details.left : parent.right

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            RoomHeader { room: roomItem }
            RoomPinned { room: roomItem }
            RoomThread { room: roomItem }

            // opening (exo-ba0): the module is joining; the first time it also starts the
            // node, which takes longer, and the line says so after a few seconds
            Item {
                objectName: "roomOpening"
                visible: room.opening
                Layout.fillWidth: true
                Layout.fillHeight: true
                Column {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 2 * Theme.spacing.xlarge, 420)
                    spacing: Theme.spacing.small
                    Loading { anchors.horizontalCenter: parent.horizontalCenter; running: room.opening }
                    LogosText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("Opening the room…")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.body
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        objectName: "roomOpeningSlow"
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        visible: room.openingSlow
                        text: qsTr("Connecting to the network. The first time takes a little longer.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                    }
                }
            }

            // someone asks to join: said where the conversation is, with Admit (U3)
            Repeater {
                model: room.joined ? room.visibleRequests : []
                delegate: InlineNotice {
                    required property var modelData
                    readonly property string who: String(modelData.alias || "").length > 0 ? String(modelData.alias)
                        : (String(modelData.identity || "").slice(0, 6) + "…" + String(modelData.identity || "").slice(-4))
                    objectName: "roomJoinRequest"
                    Layout.leftMargin: Theme.spacing.xlarge
                    Layout.rightMargin: Theme.spacing.xlarge
                    Layout.bottomMargin: Theme.spacing.small
                    tone: "info"
                    title: qsTr("%1 asks to join").arg(who)
                    text: qsTr("Admitting re-keys the room forward: they read from here on, never the messages before.")
                    ActionButton {
                        objectName: "roomJoinAdmit"
                        text: qsTr("Admit")
                        variant: LogosButton.Variant.Primary
                        onClicked: room.admitMember(String(modelData.identity || ""))
                    }
                    ActionButton {
                        text: qsTr("Not now")
                        quiet: true
                        onClicked: room.dismissRequest(String(modelData.identity || ""))
                    }
                }
            }

            InlineNotice {
                id: nameNotice
                objectName: "roomNameMember"
                readonly property string identity: room.unnamedMember ? String(room.unnamedMember.identity || "") : ""
                visible: room.joined && room.unnamedMember !== null
                Layout.fillWidth: true
                Layout.leftMargin: Theme.spacing.xlarge
                Layout.rightMargin: Theme.spacing.xlarge
                Layout.bottomMargin: Theme.spacing.small
                tone: "info"
                title: qsTr("Someone new is here. Who is it?")
                text: qsTr("Give them a name only you see. Their chat id is %1.")
                      .arg(nameNotice.identity.slice(0, 6) + "…" + nameNotice.identity.slice(-4))
                LogosTextField {
                    id: nameField
                    objectName: "roomNameField"
                    width: 160
                    placeholderText: qsTr("Their name")
                    Keys.onReturnPressed: if (nameSave.enabled) nameSave.clicked()
                }
                ActionButton {
                    id: nameSave
                    objectName: "roomNameSave"
                    text: qsTr("Save")
                    variant: LogosButton.Variant.Primary
                    enabled: nameField.text.trim().length > 0
                    onClicked: { room.nameMember(nameNotice.identity, nameField.text); nameField.text = ""; }
                }
                ActionButton {
                    objectName: "roomNameSkip"
                    text: qsTr("Not now")
                    quiet: true
                    onClicked: room.skipNaming(nameNotice.identity)
                }
            }

            RoomComposer {
                id: composerPanel
                room: roomItem
                Layout.leftMargin: Theme.spacing.xlarge
                Layout.rightMargin: Theme.spacing.xlarge
                Layout.topMargin: Theme.spacing.small
            }

            // the scope line (U-1): who can read this room, always on screen in it
            RowLayout {
                objectName: "roomScopeLine"
                visible: room.joined
                Layout.fillWidth: true
                Layout.leftMargin: Theme.spacing.xlarge
                Layout.rightMargin: Theme.spacing.xlarge
                Layout.topMargin: Theme.spacing.small
                Layout.bottomMargin: Theme.spacing.medium
                spacing: Theme.spacing.small
                LogosIcon {
                    Layout.preferredWidth: 14
                    Layout.preferredHeight: 14
                    source: MusterStyle.icon("lock")
                    color: MusterStyle.settled
                }
                LogosText {
                    text: room.scopeLine
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.caption
                }
                LogosText {
                    objectName: "roomScopeWhoSees"
                    text: qsTr("Who can see what")
                    color: whoHover.hovered ? Theme.palette.text : Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    font.underline: true
                    HoverHandler { id: whoHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: room.openDetails("privacy") }
                }
                Item { Layout.fillWidth: true }
            }
        }
    }

    // over the thread, a tap outside the drawer closes it
    Rectangle {
        visible: room.detailsShown && !room.detailsDocked
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        z: 4
        TapHandler { onTapped: room.closeDetails() }
    }

    // Room details (RoomDetails.qml)
    RoomDetails {
        id: details
        room: roomItem
        visible: room.detailsShown
        width: 360
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        z: 5
    }

    // The room map (RoomMap.qml), over everything in the room while it is open
    RoomMap {
        id: roomMap
        visible: room.joined && room.mapOpen
        anchors.fill: parent
        z: 6
        // fed only while open: a closed map computes nothing (its folds and layout are
        // per graph, and the graph refreshes every few seconds while the room is open)
        graph: room.mapOpen ? room.graph : ({})
        intents: room.mapOpen ? room.intents : []
        members: room.mapOpen ? room.members : []
        onCloseRequested: room.mapOpen = false
        onSeen: function (count) {
            var m = {};
            try { m = JSON.parse(roomPrefs.mapSeen); } catch (e) { m = {}; }
            m[room.topic] = count;
            roomPrefs.mapSeen = JSON.stringify(m);
        }
        onOpenCard: function (intentId) { room.mapOpen = false; room.jumpRequested(intentId); }
    }
    // the map is a fold of the log: refreshed while it is open, on the room's slow cadence
    Timer {
        interval: 2000
        running: room.joined && room.mapOpen
        repeat: true
        onTriggered: if (room.backend) room.backend.loadGraph("")
    }

    // Live refresh while a room is open. Delivery is polled (inbound arrives on the
    // module's own thread and is drained on read), so without a tick a request to
    // join, a peer's message, or a folded contribution from another host would only
    // appear on the next manual action. This tick IS the poll driver — each read
    // drains inbound first — so it paces felt latency together with the transport's
    // catchup period (module/src/transport/delivery.nim, MUSTER_CATCHUP_MS). Keep the
    // two in step: 1s ≈ chat cadence; the reads are cheap.
    Timer {
        interval: 1000
        running: room.joined
        repeat: true
        onTriggered: {
            if (!room.backend) return;
            room.backend.loadPending();
            room.backend.loadMembers();
            room.backend.loadMessages();
            room.backend.loadIntents();
            // voice_status is read by Main's appVoicePoll every second, room or none: a
            // recording shows whoever started it, since with the access policy off any module
            // loaded beside Muster can turn the microphone on (docs/design/voice-notes.md §13)
        }
    }

    // While the microphone starts or records, or a note plays, voice_status is read four
    // times a second, for the time, the level and the place (voice-notes.md §8). A draft
    // only held, which can wait for hours, and idle are read on Main's 1 s tick (PR 340's
    // review). voice_status also drives the module's voice pump, as fileshare_files drives
    // FileShare's.
    Timer {
        objectName: "voicePoll"
        interval: 250
        running: room.joined && (room.voiceState === "starting" || room.voiceState === "recording"
                                 || room.voicePlaying !== null)
        repeat: true
        onTriggered: if (room.backend) room.backend.loadVoice()
    }

    // Accounts other members (or the LEZ create / FROST ceremony pumps) disclose, on a slow
    // tick: listing them re-checks each EVM account against the chain, so not every second
    // (exo-59c: they used to appear only after re-entering the room).
    Timer {
        interval: 10000
        running: room.joined
        repeat: true
        onTriggered: if (room.backend) room.backend.loadAccounts()
    }

    // Connectivity on a slower cadence than the message tick: once a Safe proposal has
    // introduced the RPC, its probe makes a blocking eth_chainId call (short timeout),
    // so probing it every second would stutter the room. Every 5s is plenty to keep the
    // indicators honest. A room without such a proposal never probes the RPC at all.
    Timer {
        interval: 5000
        running: room.joined
        repeat: true
        onTriggered: {
            if (!room.backend) return;
            room.backend.loadConnectivity();
            room.backend.loadFlow();   // a pure fold — who could see what, refreshed with the slow tick
            room.backend.loadSecurityLevels();   // the active null-ladder level (exo-1ec.5), a pure fold
        }
    }
}
