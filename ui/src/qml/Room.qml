import QtQuick
import QtQuick.Layouts

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

    readonly property string topic: backend ? backend.roomTopic : ""
    // What this instance knows the room as (Main's session-only title), shown instead of
    // the topic, which names nothing (exo-661.7 / exo-59c). Empty → the topic.
    property string roomTitle: ""
    readonly property bool joined: room.topic.length > 0

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
    readonly property var members: {
        try { return JSON.parse(backend ? backend.membersJson : "[]"); }
        catch (e) { return []; }
    }
    // This instance's own encryption identity (the roster row flagged self) — the id
    // a decline is keyed by, so the card knows "you declined".
    readonly property string myIdentity: {
        var arr = room.members;
        for (var i = 0; i < arr.length; ++i)
            if (arr[i] && arr[i].self) return String(arr[i].identity || "");
        return "";
    }
    // Join-requests not yet admitted: [{ identity, bindsOwner }]. The scope panel
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
    // Install what a proposal needs (exo-dcc.10): a card or the proposal form asks
    // Basecamp's Package Manager to open on a package; the shell raises the request
    // (packages.install / packages.show) and hands every answer back in packageRequests,
    // one entry per package: {state: asking|open|unavailable|failed|cancelled|error, …}.
    signal packageInstallRequested(string pkg)
    signal packageShowRequested(string pkg)
    property var packageRequests: ({})
    function packageReq(pkg) {
        var m = room.packageRequests;
        return (pkg && m && m[pkg]) ? m[pkg] : null;
    }

    readonly property var intents: {
        try { return JSON.parse(backend ? backend.intentsJson : "[]"); }
        catch (e) { return []; }
    }
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
    onPolicyKindChanged: if (composing) refreshRoomAccount()
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
    readonly property bool composeBlocked: room.composeBlockers.length > 0
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
        if (valid.length > 0 && valid.indexOf(room.policyKind) < 0)
            room.backend.setPolicy(valid[0]);
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
             : kind === "policy" ? qsTr("Proposed a new policy for the room")
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

    // This account's own address (from settings/identity) — what an address-share
    // answers a priming request with, so it's YOUR address, not a demo one.
    readonly property string myAddress: {
        try {
            var s = JSON.parse(backend ? backend.settingsJson : "{}");
            return (s && s.identity && s.identity.address) ? String(s.identity.address) : "";
        } catch (e) { return ""; }
    }

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
                      : st === "collecting" ? "collecting" : "proposed";
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
        // a split (exo-a90): its own body on the card — who owes what, and where each stands
        var isSplit = effKind === "split";
        // a settle-up (exo-3c6): several splits netted — its own body: the net payments
        var isSettleUp = effKind === "settle-up";
        return {
            kind: "intent-propose",
            split: (isSplit && it && it.split) ? it.split : null,
            settleUp: (isSettleUp && it && it.settleUp) ? it.settleUp : null,
            parts: (isSplit && it && Array.isArray(it.parts)) ? it.parts : [],
            // who proposed it, by their signed claim (exo-770); [] = unattributed
            proposedBy: (it && Array.isArray(it.proposedBy)) ? it.proposedBy : [],
            label: isSettleUp ? qsTr("Settle up") : isSplit ? qsTr("Split")
                 : isGovernance ? qsTr("Add policy")
                 : isLez ? qsTr("LEZ multisig")
                 : isInvoke ? qsTr("Action")
                 : isStatement ? qsTr("Statement") : qsTr("Payment"),
            // an invoke intent's target, rendered by the card as "call module.method(…)".
            action: isInvoke ? (String(eff.module || "") + "." + String(eff.method || "")) : "",
            actionArgs: invokeArgs,
            // a statement the room ratifies, or a governance decision — the card shows
            // the text instead of amount → destination.
            statement: isGovernance
                     ? qsTr("Grant the room the “%1” policy").arg(String(eff.kind || ""))
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
            heading: isSettleUp ? qsTr("Proposed to settle up") : isSplit ? qsTr("Proposed a split")
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
    readonly property string splitFor: (room.splitPrivate || room.splitBitcoin) ? "" : room.splitCreditor
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
    // An Ethereum split may be paid in a token (exo-5ab): the address typed, and what the
    // token says about itself once looked up — its decimals and symbol, display only.
    property string splitToken: ""
    readonly property var splitTokenInfo: {
        if (room.splitPrivate || room.splitBitcoin || room.splitToken.length === 0 || !room.backend) return null;
        var j = {};
        try { j = JSON.parse(String(room.backend.tokenInfoJson || "{}")); } catch (e) { return null; }
        return (j && !j.error && String(j.token || "") === room.splitToken.toLowerCase()) ? j : null;
    }
    readonly property int splitDecimals: room.splitPrivate ? 9 : room.splitBitcoin ? 8
                                       : room.splitTokenInfo ? Number(room.splitTokenInfo.decimals) : 18
    readonly property string splitUnit: room.splitPrivate ? "LEZ" : room.splitBitcoin ? "BTC"
                                      : room.splitTokenInfo ? (String(room.splitTokenInfo.symbol || "") || qsTr("units"))
                                      : "ETH"
    // Settle up across assets and chains (exo-a90.17): paid in this rail's asset; every other
    // asset the room owes in, priced at the rate typed here — the proposer's recorded quote.
    property bool acrossOpen: false
    property bool acrossPending: false      // proposed; the box closes only once it is accepted
    property var acrossRates: ({})          // "chain|asset" → the typed rate, per ONE unit
    // A refusal keeps the box and its rates; success closes it (exo-a90.17).
    onSplitResultChanged: {
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
    readonly property bool splitTokenPending: !room.splitPrivate && !room.splitBitcoin && room.splitToken.length > 0
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
        var parts = n + (room.splitCreditorShares ? 1 : 0);
        var qr = room.divSmall(total, parts);
        return { each: qr[0], mine: room.addSmall(room.splitCreditorShares ? qr[0] : "0", qr[1]), total: total, n: n };
    }
    function proposeSplit(totalEth, memo) {
        if (!room.backend) return;
        var total = room.splitTotalOf(totalEth);
        var who = room.splitDebtors();
        if (total.length === 0 || who.length === 0) return;
        if (room.splitTokenPending) return;
        if (room.splitFor.length > 0 && room.sharedAddressOf(room.splitFor).length === 0) return;
        var spec = { parties: who, creditorShares: room.splitCreditorShares };
        if (room.splitFor.length > 0) spec.creditor = room.splitFor;   // on their behalf (exo-770)
        if (room.splitTokenInfo) spec.asset = String(room.splitTokenInfo.asset);   // exo-5ab
        if (room.splitFiat) {
            if (String(room.splitFiatSource).trim().length === 0) return;   // a quote names its source
            spec.fiat = { currency: String(room.splitFiatCurrency).trim().toUpperCase(), amount: String(totalEth).trim(),
                          rate: String(room.splitFiatRate).trim(), source: String(room.splitFiatSource).trim() };
        }
        // chain "" = the chain your configured RPC serves; it is written into the split,
        // so everyone reviews it before agreeing.
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

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.large
        spacing: Theme.spacing.medium

        // Left: the conversation (header, join, proposals, thread, composer).
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.spacing.medium

        // ── header ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosText {
                Layout.fillWidth: true
                text: room.joined ? qsTr("Room · %1").arg(room.roomTitle.length > 0 ? room.roomTitle : room.topic)
                                  : qsTr("Join a room")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightBold
                elide: Text.ElideRight
            }

            LogosText {
                objectName: "roomMembersLabel"
                visible: room.joined
                text: qsTr("%1 in the room").arg(room.members.length)
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }

        // ── join (until a room is joined) ─────────────────────────────────
        RowLayout {
            visible: !room.joined
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosTextField {
                id: topicField
                objectName: "roomTopicField"
                Layout.fillWidth: true
                placeholderText: qsTr("topic, e.g. muster.demo.room")
            }

            LogosButton {
                objectName: "joinRoomButton"
                text: qsTr("Join")
                enabled: topicField.text.length > 0
                onClicked: if (room.backend) room.backend.joinRoom(topicField.text)
            }
        }

        // ── the conversation ──────────────────────────────────────────────
        // One timeline. Chat and cards interleave in the order they were sent —
        // proposals are cards IN the conversation, not a side list. A message whose
        // body is an `intent-ref` card resolves to the live proposal from the
        // verified fold (state + verify + provenance), rendered inline with its own
        // approve affordance; address-share / receipt cards render in place; anything
        // else is plain text.
        Rectangle {
            visible: room.joined
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.borderSubtle

            ListView {
                id: thread
                objectName: "messageThread"
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                clip: true
                spacing: Theme.spacing.small
                model: room.messages
                onCountChanged: positionViewAtEnd()

                delegate: Item {
                    id: msg
                    // Both are REQUIRED: once a delegate declares any required property,
                    // Qt 6 stops injecting context properties, so `modelData` must be
                    // declared too or it reads as undefined (which silently blanks every
                    // card — parsedCard parse fails → all rows fall through to empty
                    // chat text). `index` drives the duplicate-ref collapse below.
                    required property int index
                    required property var modelData
                    width: thread.width
                    // A duplicate ref collapses to nothing — re-proposing the same
                    // effect (same content-addressed id) posts a second ref to the
                    // one intent; the intent is one thing, so show it once.
                    implicitHeight: msg.isDupRef ? 0 : rowCol.implicitHeight

                    // A body that parses to an object with a `kind` is a typed card.
                    // `intent-ref` points at a proposal in the verified fold; other
                    // kinds (address-share / receipt) are peer data rendered in place;
                    // anything else is plain chat text.
                    readonly property var parsedCard: {
                        try {
                            var o = JSON.parse(modelData.body);
                            return (o && (o.kind || o.type)) ? o : null;
                        } catch (e) { return null; }
                    }
                    readonly property bool isIntentRef:
                        msg.parsedCard && String(msg.parsedCard.kind || "") === "intent-ref"
                    readonly property var liveIntent:
                        msg.isIntentRef ? room.intentById(msg.parsedCard.intentId) : null

                    // Who authored this line, by name: "you" for our own, the contact
                    // alias when we've named them, else a short id — never raw 64-byte
                    // hex in the timeline (the module resolves alias/self on each message).
                    readonly property string authorName: {
                        if (modelData.self) return qsTr("you");
                        var a = String(modelData.alias || "");
                        if (a.length > 0) return a;
                        return String(modelData.author || "?").substring(0, 10);
                    }

                    // True when an EARLIER message already referenced this intent —
                    // so only the first ref to an intent renders its card.
                    readonly property bool isDupRef: {
                        if (!msg.isIntentRef) return false;
                        var id = String(msg.parsedCard.intentId || "");
                        var msgs = room.messages;
                        for (var i = 0; i < msg.index && i < msgs.length; ++i) {
                            try {
                                var o = JSON.parse(msgs[i].body);
                                if (o && String(o.kind || "") === "intent-ref"
                                     && String(o.intentId || "") === id)
                                    return true;
                            } catch (e) {}
                        }
                        return false;
                    }

                    // reveal the signature field for THIS inline proposal.
                    property bool approving: false
                    // reveal the outside-signer panel (PSBT) for THIS inline proposal.
                    property bool outsideOpen: false

                    ColumnLayout {
                        id: rowCol
                        width: parent.width
                        visible: !msg.isDupRef
                        spacing: Theme.spacing.tiny

                        // ── a proposal, inline (live state from the verified fold) ──
                        MusterCard {
                            visible: msg.isIntentRef && msg.liveIntent !== null
                            Layout.fillWidth: true
                            card: msg.liveIntent ? room.intentToCard(msg.liveIntent) : ({})
                            // Primary: sign in-app with YOUR own identity — no paste. An
                            // empty signature tells the module to endorse the re-derived
                            // materialization with the keystore (Ed25519 for a room-native
                            // driver where you are a member; secp for a Safe you own).
                            onApprove: {
                                if (room.backend && msg.liveIntent)
                                    room.backend.contributeInRoom(String(msg.liveIntent.id || ""), "", "");
                            }
                            onNeeds: if (room.backend && msg.liveIntent) {
                                room.backend.loadReadiness(String(msg.liveIntent.id || ""));
                                room.backend.loadOffers(String(msg.liveIntent.id || ""));
                            }
                            onDeny: if (room.backend && msg.liveIntent) room.backend.declineInRoom(String(msg.liveIntent.id || ""))
                            onDownloadAudit: if (room.backend && msg.liveIntent) room.backend.downloadAudit(String(msg.liveIntent.id || ""))
                            auditStatus: msg.liveIntent ? room.auditStatusFor(String(msg.liveIntent.id || "")) : ""
                            // Share one of my holdings to fill a slot (the "From you" picker, K6):
                            // the module publishes only the chosen PUBLIC face (s1).
                            onShareMaterial: function(requirement, pub) {
                                if (room.backend && msg.liveIntent)
                                    room.backend.shareMaterial(String(msg.liveIntent.id || ""), requirement, pub);
                            }
                            // a split (exo-a90): pay MY share (derived by the module from the
                            // agreed split), or — as the creditor — mark a share received
                            // outside muster. Payments the creditor's own RPC shows are
                            // confirmed on the intents tick without a click.
                            onSettlePart: if (room.backend && msg.liveIntent)
                                              room.backend.settlePart(String(msg.liveIntent.id || ""))
                            onConfirmPart: function(part) {
                                if (room.backend && msg.liveIntent)
                                    room.backend.confirmPart(String(msg.liveIntent.id || ""), part, "");
                            }
                            onRenewSplit: if (room.backend && msg.liveIntent)
                                              room.backend.renewSplit(String(msg.liveIntent.id || ""))
                            splitNote: (room.splitResult && room.splitResult.id && msg.liveIntent
                                        && String(room.splitResult.id) === String(msg.liveIntent.id || "")
                                        && room.splitResult.op !== "propose")
                                       ? (room.splitResult.error
                                          ? (String(room.splitResult.error) === "paying"
                                             ? qsTr("Your earlier payment of this share has not landed yet. Muster will not send another while it might; it shows as paid once it lands.")
                                             : qsTr("⚠ %1").arg(String(room.splitResult.error) + (room.splitResult.detail ? ": " + String(room.splitResult.detail) : "")))
                                          : room.splitResult.op === "pay"
                                          ? (room.myPartSettled(msg.liveIntent) ? ""
                                             : String(room.splitResult.pending || "") === "pending"
                                             // a private payment proves in the background: no
                                             // reference exists until the zone answers
                                             ? qsTr("Sending %1 %2 privately — your wallet is proving the transfer, which takes a few minutes; it shows as paid once it lands.")
                                                .arg(room.weiToEth(String(room.splitResult.amount || "0"),
                                                                   Number(((msg.liveIntent && msg.liveIntent.split) || {}).decimals || 18)))
                                                .arg(String(((msg.liveIntent && msg.liveIntent.split) || {}).asset || "ETH"))
                                             : qsTr("Sent %1 %2 from your wallet (%3) — it shows as paid once it settles.")
                                                .arg(room.weiToEth(String(room.splitResult.amount || "0"),
                                                                   Number(((msg.liveIntent && msg.liveIntent.split) || {}).decimals || 18)))
                                                .arg(String(((msg.liveIntent && msg.liveIntent.split) || {}).asset || "ETH"))
                                                .arg(String(room.splitResult.pending || "").slice(0, 12) + "…"))
                                          : room.splitResult.op === "renew"
                                          ? qsTr("Renewal proposed — it appears below; everyone who still owes a share agrees to it again.")
                                          : qsTr("Marked received."))
                                       : ""
                            onOpenSettings: room.settingsRequested()
                            // install what's missing (exo-dcc.10): the shell asks Package
                            // Manager; the answers come back down; readiness is re-read
                            // (not the offers) until the module runs
                            packageRequests: room.packageRequests
                            onInstallPackage: function (pkg) { room.packageInstallRequested(pkg); }
                            onShowPackage: function (pkg) { room.packageShowRequested(pkg); }
                            onRecheckReadiness: if (room.backend && msg.liveIntent)
                                                    room.backend.loadReadiness(String(msg.liveIntent.id || ""))
                        }

                        // Advanced: paste a signature produced elsewhere (a Safe owner on
                        // another device, or a member signing off-app). Hidden behind a
                        // toggle — one-click in-app Approve above is the primary path.
                        LogosButton {
                            objectName: "roomApprovePasteToggle"
                            // a split is agreed with the debtor's room key — there is no
                            // outside signature to paste (exo-a90)
                            visible: msg.isIntentRef && msg.liveIntent !== null && !msg.approving
                                     && !msg.liveIntent.split && !msg.liveIntent.settleUp
                            Layout.leftMargin: Theme.spacing.medium
                            text: qsTr("Paste a signature instead")
                            variant: LogosButton.Variant.Secondary
                            onClicked: msg.approving = true
                        }

                        ColumnLayout {
                            visible: msg.isIntentRef && msg.liveIntent !== null && msg.approving
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("Paste a signature produced elsewhere over the re-derived "
                                         + "materialization. It counts only if it comes from a signer this "
                                         + "intent's policy recognizes (a Safe owner, or a room member).")
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.badgeText
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small

                                LogosTextField {
                                    id: sigField
                                    objectName: "roomApproveSig"
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("signature (hex)")
                                    font.family: Theme.typography.mono
                                }

                                // Enter adds the signature (paste, then Enter).
                                Connections {
                                    target: sigField.textInput
                                    function onAccepted() {
                                        if (sigField.text.length > 0 && room.backend && msg.liveIntent)
                                            room.backend.contributeInRoom(String(msg.liveIntent.id || ""), sigField.text, "");
                                        sigField.text = "";
                                        msg.approving = false;
                                    }
                                }

                                LogosButton {
                                    objectName: "roomApproveSubmit"
                                    text: qsTr("Add")
                                    enabled: sigField.text.length > 0
                                    onClicked: {
                                        if (room.backend && msg.liveIntent)
                                            room.backend.contributeInRoom(String(msg.liveIntent.id || ""), sigField.text, "");
                                        sigField.text = "";
                                        msg.approving = false;
                                    }
                                }
                            }
                        }

                        // Signers outside muster (exo-a50.2.6, seam S8) — always surfaced:
                        // a Bitcoin intent exports as a PSBT a hardware signer, Sparrow or
                        // Bitcoin Core signs; what comes back is verified by the driver like
                        // an in-app approval, counts, and is shown as signed outside muster.
                        LogosButton {
                            objectName: "roomOutsideToggle"
                            visible: msg.isIntentRef && msg.liveIntent !== null && room.isBtcIntent(msg.liveIntent)
                                     && !msg.outsideOpen
                            Layout.leftMargin: Theme.spacing.medium
                            text: qsTr("Sign outside muster (PSBT)")
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                msg.outsideOpen = true;
                                if (room.backend) room.backend.exportOutside(String(msg.liveIntent.id || ""));
                            }
                        }

                        ColumnLayout {
                            id: outsideBox
                            visible: msg.isIntentRef && msg.liveIntent !== null && room.isBtcIntent(msg.liveIntent)
                                     && msg.outsideOpen
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            readonly property string iid: String((msg.liveIntent && msg.liveIntent.id) || "")
                            // the export and import results, only when they name THIS intent
                            readonly property var exp: (room.outsideExport && String(room.outsideExport.intentId || "") === outsideBox.iid)
                                                       ? room.outsideExport : null
                            readonly property var imp: (room.outsideImport && String(room.outsideImport.intentId || "") === outsideBox.iid)
                                                       ? room.outsideImport : null

                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("Give this PSBT to a signer outside muster (a hardware signer, Sparrow, "
                                         + "Bitcoin Core). Paste back what it returns: each signature is checked like "
                                         + "an in-app one, counts toward the threshold, and is shown as signed outside "
                                         + "muster — it commits to the transaction, nothing more.")
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.badgeText
                            }

                            LogosText {
                                visible: !!(outsideBox.exp && outsideBox.exp.error)
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("⚠ No PSBT — %1").arg(String((outsideBox.exp && outsideBox.exp.error) || ""))
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.badgeText
                            }

                            Rectangle {
                                visible: !!(outsideBox.exp && outsideBox.exp.encoded)
                                Layout.fillWidth: true
                                implicitHeight: Math.min(96, psbtOut.contentHeight + 2 * Theme.spacing.small)
                                radius: Theme.spacing.radiusSmall
                                color: Theme.palette.surfaceRaised
                                border.width: 1
                                border.color: Theme.palette.borderSubtle
                                clip: true
                                TextEdit {
                                    id: psbtOut
                                    objectName: "roomOutsidePsbt"
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacing.small
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: TextEdit.WrapAnywhere
                                    text: String((outsideBox.exp && outsideBox.exp.encoded) || "")
                                    color: Theme.palette.textSecondary
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosButton {
                                    objectName: "roomOutsideCopy"
                                    visible: !!(outsideBox.exp && outsideBox.exp.encoded)
                                    text: qsTr("Copy PSBT")
                                    variant: LogosButton.Variant.Secondary
                                    onClicked: { psbtOut.selectAll(); psbtOut.copy(); psbtOut.deselect(); }
                                }
                                LogosTextField {
                                    id: psbtIn
                                    objectName: "roomOutsideImport"
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("the signed PSBT (base64)")
                                    font.family: Theme.typography.mono
                                }
                                LogosButton {
                                    objectName: "roomOutsideImportSubmit"
                                    text: qsTr("Import")
                                    enabled: psbtIn.text.length > 0
                                    onClicked: {
                                        if (room.backend) room.backend.importOutside(outsideBox.iid, psbtIn.text);
                                        psbtIn.text = "";
                                    }
                                }
                                LogosButton {
                                    text: qsTr("Close")
                                    variant: LogosButton.Variant.Secondary
                                    onClicked: msg.outsideOpen = false
                                }
                            }

                            LogosText {
                                objectName: "roomOutsideImportResult"
                                visible: outsideBox.imp !== null
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: {
                                    var r = outsideBox.imp || ({});
                                    if (r.error) {
                                        var why = String(r.error);
                                        if (why === "not-this-spend") why = qsTr("that PSBT is for a different spend — nothing was added");
                                        else if (why === "no-signatures") why = qsTr("it carries no signature by one of the account's keys");
                                        else if (why === "not-readable") why = qsTr("that is not a PSBT");
                                        return qsTr("⚠ %1").arg(why);
                                    }
                                    var n = (r.imported || []).length;
                                    var had = (r.already || []).length;
                                    return qsTr("✓ %n signature(s) added — signed outside muster, counted.", "", n)
                                           + (had > 0 ? " " + qsTr("%n already in the room.", "", had) : "")
                                           + "  " + qsTr("State: %1").arg(String(r.state || ""));
                                }
                                color: (outsideBox.imp && outsideBox.imp.error) ? Theme.palette.warning : Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }

                        // ready (executable) — settle it on-chain FROM the room. For an
                        // intent whose family settles on a chain (a Safe, Bitcoin, the LEZ
                        // multisig, FROST — its profile's `settlement`), Settle runs
                        // coordinate_submit, which assembles the settlement from the log;
                        // for a room family (threshold, attest) nothing settles on-chain,
                        // so it says so. The outcome is reported honestly from the module —
                        // never a false "landed".
                        ColumnLayout {
                            id: readyBox
                            // Show once the intent is ready AND keep showing through
                            // submitted/settling/final — and whenever a submit outcome
                            // names this intent — so the Settle result (✓ settled, or an
                            // ⚠ error/revert) stays on screen instead of vanishing the
                            // instant Settle moves the state off "executable".
                            visible: msg.isIntentRef && msg.liveIntent !== null
                                     && (["executable", "submitted", "settling", "final"]
                                            .indexOf(String((msg.liveIntent && msg.liveIntent.state) || "")) >= 0
                                         || (room.roomSubmit
                                             && String(room.roomSubmit.id || "")
                                                === String((msg.liveIntent && msg.liveIntent.id) || ""))
                                         || (room.executeResult
                                             && String(room.executeResult.id || "")
                                                === String((msg.liveIntent && msg.liveIntent.id) || "")))
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            readonly property string rail: String((msg.liveIntent && msg.liveIntent.rail) || "safe")
                            readonly property string st: String((msg.liveIntent && msg.liveIntent.state) || "")
                            // Whether this intent settles on a chain at all: its family's
                            // settlement, from the driver profile (evm / bitcoin / lez …, or
                            // "none" for a room family) — never a guess from the rail. Every
                            // family that settles goes through coordinate_submit.
                            readonly property bool settles: String(((msg.liveIntent && msg.liveIntent.profile) || {}).settlement || "none") !== "none"
                            // an invoke intent settles by RUNNING the action (coordinate_execute),
                            // not by an on-chain Safe settle — the policy tells them apart.
                            readonly property bool isInvoke:
                                String((msg.liveIntent && msg.liveIntent.policy) || "") === "invoke"
                            // a split settles in PARTS — each person pays their own share — so
                            // there is nothing for one member to submit (exo-a90)
                            // settled in parts: a split, or a settle-up (exo-3c6) — never "Settle on-chain"
                            readonly property bool isSplit: !!(msg.liveIntent && (msg.liveIntent.split || msg.liveIntent.settleUp))
                            readonly property int partsDone: {
                                var ps = (msg.liveIntent && msg.liveIntent.parts) || [];
                                var n = 0;
                                for (var i = 0; i < ps.length; ++i) if (ps[i].confirmed) ++n;
                                return n;
                            }
                            // the submit outcome, only when it names THIS intent
                            readonly property var outcome: (room.roomSubmit
                                && String(room.roomSubmit.id || "") === String((msg.liveIntent && msg.liveIntent.id) || ""))
                                ? room.roomSubmit : null
                            // the invoke-execute outcome, only when it names THIS intent
                            readonly property var execOutcome: (room.executeResult
                                && String(room.executeResult.id || "") === String((msg.liveIntent && msg.liveIntent.id) || ""))
                                ? room.executeResult : null

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosText {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    // Track the folded state so the line doesn't keep
                                    // saying "Ready" after the intent has been settled.
                                    text: readyBox.isSplit
                                          ? (readyBox.st === "final"
                                             ? qsTr("✓ Settled — every share confirmed by who it was owed to.")
                                             // past its expiry nothing more is paid under it (exo-a90.15/16)
                                             : (msg.liveIntent && ((msg.liveIntent.split && msg.liveIntent.split.expired)
                                                                   || (msg.liveIntent.settleUp && msg.liveIntent.settleUp.expired)))
                                             ? qsTr("Expired — nothing more is paid under it.")
                                             : readyBox.st === "executable"
                                             ? qsTr("✓ Agreed — each person now pays their own share.")
                                             : qsTr("Settling — %1 of %2 shares confirmed.")
                                                   .arg(readyBox.partsDone)
                                                   .arg(((msg.liveIntent && msg.liveIntent.parts) || []).length))
                                          : readyBox.isInvoke
                                          ? (readyBox.st === "final"
                                             ? qsTr("✓ Ran — the action executed.")
                                             : readyBox.st === "submitted"
                                             ? qsTr("Running the action…")
                                             : qsTr("✓ Ready — endorsed. Run the action."))
                                          : !readyBox.settles
                                          ? qsTr("✓ Endorsed — a signed group decision. Nothing settles on-chain.")
                                          : readyBox.st === "final"
                                          ? qsTr("✓ Settled on-chain.")
                                          : (readyBox.st === "submitted" || readyBox.st === "settling")
                                          ? qsTr("Submitted — awaiting finality…")
                                          : qsTr("✓ Ready — the approvals are collected.")
                                    color: (readyBox.st === "submitted" || readyBox.st === "settling")
                                           ? Theme.palette.textSecondary : Theme.palette.success
                                    font.pixelSize: Theme.typography.secondaryText
                                    font.weight: Theme.typography.weightMedium
                                }
                                // invoke: run the action FROM the room (coordinate_execute).
                                LogosButton {
                                    objectName: "roomExecuteButton"
                                    visible: readyBox.isInvoke && readyBox.st === "executable"
                                    text: qsTr("Run the action")
                                    onClicked: if (room.backend)
                                                   room.backend.executeInRoom(String((msg.liveIntent && msg.liveIntent.id) || ""));
                                }
                                LogosButton {
                                    objectName: "roomSubmitButton"
                                    // only while it is actually executable — once it is
                                    // submitted/final there is nothing left to settle.
                                    visible: !readyBox.isInvoke && !readyBox.isSplit && readyBox.settles && readyBox.st === "executable"
                                    text: qsTr("Settle on-chain")
                                    onClicked: if (room.backend)
                                                   room.backend.submitInRoom(String((msg.liveIntent && msg.liveIntent.id) || ""));
                                }
                            }

                            // honest outcome line (submitted/final/failed, or an error)
                            LogosText {
                                visible: readyBox.outcome !== null
                                Layout.fillWidth: true
                                wrapMode: Text.WrapAnywhere
                                text: {
                                    var o = readyBox.outcome || ({});
                                    if (o.error !== undefined) {
                                        var err = String(o.error);
                                        // spell out the cases the module reports so the
                                        // reader sees *why*, not just a slug.
                                        if (err === "insufficient-signatures")
                                            return (readyBox.rail === "safe"
                                                    ? qsTr("⚠ Not enough owner signatures — have %1 of %2. "
                                                           + "The approvers must be real Safe owners.")
                                                    : qsTr("⚠ Not enough signatures — have %1 of %2."))
                                                   .arg(String(o.have)).arg(String(o.need));
                                        if (err === "rpc-unreachable")
                                            return qsTr("⚠ Couldn't reach the chain (RPC). Is your node running? — %1")
                                                   .arg(String(o.detail || ""));
                                        if (err === "not-executable")
                                            return qsTr("⚠ Not ready to settle — state is \"%1\".")
                                                   .arg(String(o.state || ""));
                                        if (err === "not-onchain")
                                            return qsTr("This endorsement settles nothing on-chain — %1")
                                                   .arg(String(o.detail || ""));
                                        return qsTr("⚠ ") + err + (o.detail ? " — " + String(o.detail) : "");
                                    }
                                    var oc = String(o.onchain || "");
                                    var tx = o.txHash ? "  ·  " + String(o.txHash) : "";
                                    return (oc === "final" ? qsTr("✓ Settled on-chain (final)")
                                          : oc === "failed" ? (readyBox.rail === "safe"
                                                               ? qsTr("⚠ On-chain execution reverted — the Safe rejected it")
                                                               : qsTr("⚠ The chain rejected it"))
                                          : qsTr("Submitted — awaiting finality")) + tx;
                                }
                                color: {
                                    var o = readyBox.outcome || ({});
                                    return (o.error !== undefined || String(o.onchain || "") === "failed")
                                           ? Theme.palette.warning : Theme.palette.textSecondary;
                                }
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }

                            // honest invoke-execute outcome (executed/detail, or an error).
                            // The core never reports a false success — a gated or failed
                            // call is an error here, not a silent "ran".
                            LogosText {
                                visible: readyBox.execOutcome !== null
                                Layout.fillWidth: true
                                wrapMode: Text.WrapAnywhere
                                text: {
                                    var o = readyBox.execOutcome || ({});
                                    if (o.error !== undefined) {
                                        var err = String(o.error);
                                        if (err === "not-invoke")
                                            return qsTr("⚠ Not an action intent — nothing to run.");
                                        if (err === "not-executable")
                                            return qsTr("⚠ Not ready to run — state is \"%1\".")
                                                   .arg(String(o.state || ""));
                                        if (err === "not-allowed")
                                            return qsTr("⚠ Blocked by the gate — %1.%2 is not on the invoke "
                                                     + "allowlist, or the target's capability policy denied it.")
                                                   .arg(String(o.module || "")).arg(String(o.method || ""));
                                        return qsTr("⚠ ") + err + (o.detail ? " — " + String(o.detail) : "");
                                    }
                                    if (o.executed === false)
                                        return qsTr("⚠ The action did not run%1").arg(o.detail ? " — " + String(o.detail) : "");
                                    return o.executed
                                         ? qsTr("✓ Action ran%1").arg(o.detail ? "  ·  " + String(o.detail) : "")
                                         : qsTr("Running…");
                                }
                                color: {
                                    var o = readyBox.execOutcome || ({});
                                    return (o.error !== undefined) ? Theme.palette.warning
                                                                   : Theme.palette.textSecondary;
                                }
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }

                        // a ref the fold hasn't caught up to yet — a quiet placeholder,
                        // never an invented card.
                        LogosText {
                            visible: msg.isIntentRef && msg.liveIntent === null
                            Layout.fillWidth: true
                            text: qsTr("· a proposal")
                            color: Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }

                        // ── other typed cards (address-share / receipt) ────────────
                        MusterCard {
                            visible: msg.parsedCard !== null && !msg.isIntentRef
                            Layout.fillWidth: true
                            card: msg.parsedCard || ({})
                            // an address-request knows who answered it, and whom it asked (exo-8e2)
                            answers: (msg.parsedCard && String(msg.parsedCard.kind || "") === "address-request")
                                     ? room.addressAnswers(msg.index, msg.parsedCard) : []
                            readerIdentity: room.myIdentity
                            postedByMe: !!(msg.modelData && msg.modelData.self)
                            askedOfName: (msg.parsedCard && msg.parsedCard["for"])
                                         ? room.memberLabel(String(msg.parsedCard["for"])) : ""
                            onShareAddress: {
                                // a Bitcoin address is my own key's on that network: the module
                                // knows it, not this view (exo-a90.17)
                                if (room.backend && String((msg.parsedCard || {}).asset || "ETH") === "BTC") {
                                    room.backend.shareAddress(String((msg.parsedCard || {}).chain || ""));
                                    return;
                                }
                                if (room.backend)
                                    room.backend.postMessage(JSON.stringify({
                                        kind: "address-share", asset: "ETH",
                                        address: room.myAddress.length > 0 ? room.myAddress
                                                 : "0x0000000000000000000000000000000000000000",
                                        form: 1
                                    }));
                            }
                            // A peer disclosed an address in answer to the ask — drop it
                            // straight into the payment recipient and open the composer, so
                            // it's used as shared, never retyped.
                            onUseAddress: function(addr) {
                                room.composeType = "payment";
                                room.composing = true;
                                proposeTo.text = addr;
                            }
                        }

                        // ── plain chat text ────────────────────────────────────────
                        ColumnLayout {
                            visible: msg.parsedCard === null
                            Layout.fillWidth: true
                            spacing: 2

                            LogosText {
                                text: msg.authorName
                                      + (modelData.ts ? "  ·  " + modelData.ts : "")
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                            LogosText {
                                Layout.fillWidth: true
                                text: String(modelData.body || "")
                                color: Theme.palette.text
                                font.pixelSize: Theme.typography.secondaryText
                                wrapMode: Text.WrapAnywhere
                            }
                        }
                    }
                }
            }
        }

        // ── composer: chat + propose ──────────────────────────────────────
        // A proposal originates in the conversation the same way a message does —
        // the "+" opens the effect fields, and proposing posts it inline as a card.
        // Its fields fill the column but never widen it: long placeholders and rows of
        // kind buttons used to push the right-hand column past the window's edge when the
        // composer opened (exo-a90.19, seen on a display).
        ColumnLayout {
            visible: room.joined
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            spacing: Theme.spacing.small

            // proposal compose, revealed by "+".
            ColumnLayout {
                visible: room.composing
                Layout.fillWidth: true
                spacing: Theme.spacing.tiny

                LogosText {
                    text: room.composeType === "statement" ? qsTr("Propose a statement")
                        : room.composeType === "action" ? qsTr("Propose an action")
                        : room.composeType === "split" ? (room.splitFor.length > 0
                                                          ? qsTr("Split a bill %1 paid").arg(room.memberLabel(room.splitFor))
                                                          : qsTr("Split a bill you paid"))
                        : qsTr("Propose a payment")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightBold
                }

                // ── kind: the effect type (the ACTION is pluggable) ───────────
                // A payment (a transfer) or a statement the room ratifies — the same
                // propose/contribute/fold path coordinates either.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        text: qsTr("Kind")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    LogosButton {
                        objectName: "roomKindPayment"
                        Layout.preferredWidth: 110
                        text: qsTr("Payment")
                        variant: room.composeType === "payment"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: room.composeType = "payment"
                    }

                    LogosButton {
                        objectName: "roomKindStatement"
                        Layout.preferredWidth: 120
                        text: qsTr("Statement")
                        variant: room.composeType === "statement"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: room.composeType = "statement"
                    }

                    // a generic module action (P-D4): coordinate calling a loaded
                    // module's method — the room endorses it, the core invokes it.
                    LogosButton {
                        objectName: "roomKindAction"
                        Layout.preferredWidth: 110
                        text: qsTr("Action")
                        variant: room.composeType === "action"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: room.composeType = "action"
                    }

                    // a split (exo-a90): you fronted a bill; each person named pays you back
                    // their own share from their own wallet — no shared account.
                    LogosButton {
                        objectName: "roomKindSplit"
                        Layout.preferredWidth: 90
                        text: qsTr("Split")
                        variant: room.composeType === "split"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: room.composeType = "split"
                    }

                    Item { Layout.fillWidth: true }
                }

                // ── policy picker: THIS proposal's driver (invariant 6) ───────
                // Policy binds to the intent, not the room — so this picks the driver
                // for the NEXT thing you propose; a card already collecting keeps its
                // own. The same propose/contribute/fold runs under either. Safe =
                // EIP-712 / secp owners; Threshold = k-of-n Ed25519 endorsement.
                RowLayout {
                    // an action carries its own driver (invoke) — no policy choice to make.
                    visible: room.composeType !== "action"
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        text: room.composeType === "payment" ? qsTr("Settles via")
                            : room.composeType === "split" ? qsTr("Settles on")
                            : qsTr("Endorse with")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    // One button per kind that serves this proposal, from the module's one
                    // kind list (exo-a50.1.2). An admitted kind is selectable; one the room
                    // has not admitted (e.g. "unanimous", n-of-n) is offered as a governance
                    // proposal to add it — driver-as-proposal (invariant 6). objectName
                    // keeps the roomPolicy<Kind> names the UI harness clicks.
                    // each button as wide as its name ("Split privately (LEZ)", "Bitcoin
                    // (P2WSH)"…), wrapping onto a second line rather than truncating a name
                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                    Repeater {
                        model: room.policiesForKind(room.composeType)
                        delegate: LogosButton {
                            required property var modelData
                            readonly property var info: room.kindInfo(modelData)
                            readonly property string label: info && info.label ? String(info.label) : String(modelData)
                            objectName: "roomPolicy" + String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                            text: room.hasDriver(modelData) ? label : qsTr("＋ Propose %1").arg(label.toLowerCase())
                            variant: room.policyKind === modelData
                                     ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                            onClicked: {
                                if (!room.backend) return;
                                if (room.hasDriver(modelData))
                                    room.backend.setPolicy(modelData);
                                else   // propose admitting it — the room approves, then it appears
                                    room.backend.proposeInRoom(JSON.stringify({ effect: "add-driver", kind: modelData }));
                            }
                        }
                    }
                    }

                    LogosText {
                        text: room.policy && room.policy.threshold !== undefined
                              ? qsTr("%1 needed").arg(room.policy.threshold) : ""
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                }

                // What the selected kind needs from your own modules and does not have yet
                // (exo-dcc.10), each with "Install …" where installing would help: Muster
                // asks Basecamp's Package Manager, and you confirm the install there. The
                // kind stays on the list above. Propose waits only when a need of your own
                // part is definitely missing; a need Muster cannot judge only warns.
                ColumnLayout {
                    objectName: "composeNeeds"
                    visible: room.composeType !== "action" && room.composeNeeds.length > 0
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny

                    Repeater {
                        model: room.composeType !== "action" ? room.composeNeeds : []
                        delegate: ColumnLayout {
                            id: composeNeed
                            required property var modelData
                            readonly property string pkg: room.needPkg(composeNeed.modelData)
                            readonly property var req: room.packageReq(composeNeed.pkg)
                            readonly property string note: room.installNote(composeNeed.pkg, composeNeed.modelData)
                            readonly property bool installable: room.needCanInstall(composeNeed.modelData)
                            Layout.fillWidth: true
                            spacing: 2

                            LogosText {
                                objectName: "composeNeed_" + String(composeNeed.modelData.name || "")
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: room.composeNeedLine(composeNeed.modelData)
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.badgeText
                            }
                            // no Install button (installed but not running, starting,
                            // failed, or nothing to install): the module's own remedy
                            LogosText {
                                visible: !composeNeed.installable && String(composeNeed.modelData.remedy || "").length > 0
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("To fix: ") + String(composeNeed.modelData.remedy || "")
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.badgeText
                            }
                            RowLayout {
                                visible: composeNeed.installable || !!(composeNeed.req && composeNeed.req.state === "failed")
                                spacing: Theme.spacing.small
                                LogosButton {
                                    objectName: "composeNeedInstall_" + String(composeNeed.modelData.name || "")
                                    visible: composeNeed.installable
                                    enabled: !(composeNeed.req && composeNeed.req.state === "asking")
                                    text: qsTr("Install %1").arg(String(composeNeed.modelData.install || ""))
                                    variant: LogosButton.Variant.Secondary
                                    onClicked: room.askInstall(composeNeed.modelData)
                                }
                                // not in any enabled catalogue: show it in Package Manager
                                LogosButton {
                                    objectName: "composeInstallShow_" + composeNeed.pkg
                                    visible: !!(composeNeed.req && composeNeed.req.state === "failed")
                                    text: qsTr("Open Package Manager")
                                    variant: LogosButton.Variant.Secondary
                                    onClicked: room.packageShowRequested(composeNeed.pkg)
                                }
                            }
                            LogosText {
                                objectName: "composeInstallStatus_" + composeNeed.pkg
                                visible: composeNeed.note.length > 0
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: composeNeed.note
                                color: (composeNeed.req && (composeNeed.req.state === "open" || composeNeed.req.state === "asking"))
                                       ? Theme.palette.textSecondary : Theme.palette.warning
                                font.pixelSize: Theme.typography.badgeText
                            }
                            LogosText {
                                visible: !!(composeNeed.req && composeNeed.req.state === "failed" && composeNeed.req.showError)
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                // "failed": Package Manager opened, but found no such package
                                text: String((composeNeed.req && composeNeed.req.showError) || "") === "failed"
                                      ? qsTr("Package Manager opened, but could not find %1. Check its catalogues.").arg(composeNeed.pkg)
                                      : qsTr("Package Manager could not be opened (%1). Open it from Basecamp.")
                                        .arg(String((composeNeed.req && composeNeed.req.showError) || ""))
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                    }

                    // why Propose is off — or, when Muster cannot tell, that it is not
                    LogosText {
                        objectName: "composeNeedsGate"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: room.composeBlocked
                              ? qsTr("Propose is off until %1 runs here.")
                                    .arg(room.composeBlockers.map(function (n) { return String(n.name || ""); }).join(", "))
                              : qsTr("You can still propose.")
                        color: room.composeBlocked ? Theme.palette.warning : Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }

                // FROM which account (exo-a50.1.3): an account-bound kind (Safe, Attest) acts
                // from an account a member disclosed into this room. One chip per account the
                // kind can use; none → say so and point at the room's Accounts panel. A refused
                // choice (no-account / choose-account) is shown, never silently replaced.
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    visible: room.composeType !== "action" && room.kindNeedsAccount(room.policyKind)
                             || (room.policyError && room.policyError.error !== undefined)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        visible: room.kindNeedsAccount(room.policyKind)
                        LogosText {
                            text: qsTr("From")
                            color: Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        Repeater {
                            model: room.accountsForKind(room.policyKind)
                            delegate: LogosButton {
                                required property var modelData
                                objectName: "roomAccount_" + String(modelData.id)
                                Layout.preferredWidth: 170
                                text: modelData.label ? String(modelData.label)
                                      : String(modelData.address).slice(0, 8) + "…" + String(modelData.address).slice(-4)
                                variant: room.policyAccount === String(modelData.id)
                                         ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                                onClicked: if (room.backend) room.backend.setPolicy(room.policyKind + "@" + String(modelData.id))
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: room.policyError && room.policyError.error !== undefined
                        text: {
                            var e = room.policyError || {};
                            if (e.error === "no-account")
                                return qsTr("No one has disclosed an account this can act from. Disclose one under Accounts, beside the room.");
                            if (e.error === "choose-account")
                                return qsTr("Several accounts are disclosed. Choose which one this acts from.");
                            // a split settles on the chain YOUR RPC serves, read — never assumed (exo-a90)
                            if (e.error === "no-rpc")
                                return qsTr("A split settles on the chain your RPC serves, and it did not answer — check Settings → RPC. %1")
                                       .arg(String(e.detail || ""));
                            return e.error ? String(e.error) : "";
                        }
                        color: Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                        wrapMode: Text.WordWrap
                    }
                }

                // attest: WHAT identity backs your attestation. An EIP-191 attestation
                // is a personal_sign with your secp256k1 AUTHORIZATION key — the same
                // key that signs Safe transactions, NOT the encryption identity that
                // names you in the room. Recognized signers are the Safe owners, so this
                // says plainly whether your attestation will count (else it's silently
                // rejected). The same disclosure the Safe composer makes, for Attest.
                Rectangle {
                    objectName: "roomAttestContext"
                    visible: room.policyKind === "eip191"
                    Layout.fillWidth: true
                    implicitHeight: attestCtx.implicitHeight + 2 * Theme.spacing.small
                    radius: Theme.spacing.radiusSmall
                    color: Theme.palette.surfaceRaised
                    border.width: 1
                    border.color: (room.roomAccount && room.roomAccount.isSigner)
                                  ? Theme.palette.success : Theme.palette.warning

                    ColumnLayout {
                        id: attestCtx
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacing.small
                        anchors.rightMargin: Theme.spacing.small
                        spacing: 2

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("You attest with your secp256k1 authorization key — the "
                                     + "same key that signs Safe transactions, not your room "
                                     + "encryption identity.")
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: qsTr("signing as %1")
                                  .arg(String((room.roomAccount && room.roomAccount.actingAs) || "…"))
                            color: Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                            elide: Text.ElideMiddle
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: {
                                if (!room.roomAccount || room.roomAccount.isSigner === undefined)
                                    return qsTr("checking whether your key is a recognized attester…");
                                return room.roomAccount.isSigner
                                     ? qsTr("✓ a recognized attester (a Safe owner) — your attestation counts")
                                     : qsTr("⚠ not a recognized attester — your attestation won't count. "
                                          + "Recognized signers: %1.")
                                       .arg(String(room.roomAccount.signerSet || "the Safe owners"));
                            }
                            color: (room.roomAccount && room.roomAccount.isSigner)
                                   ? Theme.palette.success : Theme.palette.warning
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                    }
                }

                // payment: the sending context — WHAT you're sending (the Safe's own
                // balance, so you send from real holdings, not a blind number) and WHO
                // you act as (surfaced here at propose time — ask-then-disclose — with
                // an owner check so you know before proposing whether your approval will
                // count on-chain). Only for the Safe policy; a statement settles nothing.
                Rectangle {
                    objectName: "roomSendContext"
                    visible: room.composeType === "payment" && room.policyKind === "safe"
                    Layout.fillWidth: true
                    implicitHeight: sendCtx.implicitHeight + 2 * Theme.spacing.small
                    radius: Theme.spacing.radiusSmall
                    color: Theme.palette.surfaceRaised
                    border.width: 1
                    border.color: Theme.palette.borderSubtle

                    ColumnLayout {
                        id: sendCtx
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacing.small
                        anchors.rightMargin: Theme.spacing.small
                        spacing: 2

                        // WHAT can be sent: the asset + the Safe's live balance (or an
                        // honest error — never a false zero).
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                text: qsTr("Sending")
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                font.weight: Theme.typography.weightMedium
                            }
                            LogosText {
                                Layout.fillWidth: true
                                text: {
                                    if (!room.roomAsset) return qsTr("checking the Safe…");
                                    if (room.roomAsset.error) return qsTr("⚠ balance unavailable — %1").arg(String(room.roomAsset.error));
                                    return qsTr("%1  ·  %2 available  (%3 wei)")
                                           .arg(String(room.roomAsset.symbol || "ETH"))
                                           .arg(String(room.roomAsset.display || "?"))
                                           .arg(String(room.roomAsset.raw || "0"));
                                }
                                color: (room.roomAsset && room.roomAsset.error) ? Theme.palette.warning : Theme.palette.textSecondary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                wrapMode: Text.WrapAnywhere
                            }
                        }

                        // from the Safe (the room's account — whose funds move)
                        LogosText {
                            Layout.fillWidth: true
                            text: qsTr("from Safe %1").arg(String((room.roomAccount && room.roomAccount.account) || "…"))
                            color: Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                            elide: Text.ElideMiddle
                        }

                        // WHO you act as — the disclosure, made explicit here, with the
                        // owner check that turns the old "insufficient-signatures"
                        // surprise into a warning you see before you propose.
                        LogosText {
                            Layout.fillWidth: true
                            text: {
                                var a = String((room.roomAccount && room.roomAccount.actingAs) || "");
                                if (a.length === 0) return qsTr("acting as: (loading…)");
                                var isOwner = room.roomAccount && room.roomAccount.isOwner;
                                return qsTr("you act as %1  ·  %2")
                                       .arg(a)
                                       .arg(isOwner ? qsTr("✓ a Safe owner — your approval counts")
                                                    : qsTr("⚠ not a Safe owner — your approval won't count on-chain"));
                            }
                            color: (room.roomAccount && room.roomAccount.isOwner) ? Theme.palette.success : Theme.palette.warning
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                            wrapMode: Text.WrapAnywhere
                        }

                        // soft guard: typing more than the Safe holds would revert
                        // on-chain — say so before the propose, not after the settle.
                        LogosText {
                            Layout.fillWidth: true
                            visible: room.overSends(proposeValue.text)
                            text: qsTr("⚠ more than the Safe holds — Propose is off until the amount fits")
                            color: Theme.palette.warning
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // ── action: pick a module method the room will coordinate ──────
                // The menu is coordinate_available_actions — only the actions your
                // loaded modules expose (allowlist + MUSTER_INVOKE_MODULES, never a
                // blind scan). Picking one composes an invoke intent; the room endorses
                // it k-of-n and the core invokes it (the driver never does, invariant 3).
                ColumnLayout {
                    visible: room.composeType === "action"
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny

                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: room.availableActions.length > 0
                              ? qsTr("What your modules let the room do:")
                              : qsTr("No coordinatable actions — set MUSTER_INVOKE_MODULES "
                                   + "or the invoke allowlist to expose a module's methods.")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // one selectable row per available action.
                    Repeater {
                        model: room.availableActions

                        delegate: Rectangle {
                            id: actionRow
                            required property var modelData
                            readonly property bool chosen: room.chosenAction
                                && String(room.chosenAction.module || "") === String(modelData.module || "")
                                && String(room.chosenAction.method || "") === String(modelData.method || "")
                            Layout.fillWidth: true
                            implicitHeight: actionLbl.implicitHeight + Theme.spacing.small
                            radius: Theme.spacing.radiusSmall
                            color: actionRow.chosen ? Theme.palette.surfaceRaised : "transparent"
                            border.width: 1
                            border.color: actionRow.chosen ? Theme.palette.textSecondary
                                                           : Theme.palette.borderSubtle

                            LogosText {
                                id: actionLbl
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.spacing.small
                                anchors.rightMargin: Theme.spacing.small
                                wrapMode: Text.WordWrap
                                text: {
                                    var sig = String(actionRow.modelData.signature
                                                     || actionRow.modelData.method || "");
                                    var mod = String(actionRow.modelData.module || "");
                                    var mark = actionRow.modelData.allowed
                                             ? qsTr("  ·  ✓ runs now")
                                             : qsTr("  ·  needs opt-in to run");
                                    return mod + "." + sig + mark;
                                }
                                color: Theme.palette.text
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: room.chosenAction = actionRow.modelData
                            }
                        }
                    }

                    // args for the chosen action — a JSON array, exactly what the effect
                    // carries. Kept honest: the raw args the module.method will receive.
                    LogosTextField {
                        id: proposeArgs
                        objectName: "roomProposeArgs"
                        visible: room.chosenAction !== null
                        Layout.fillWidth: true
                        placeholderText: qsTr("args as a JSON array, e.g. [\"/room\",\"hello\"]")
                        font.family: Theme.typography.mono
                    }

                    // Mode B (exo-45e): mark this action as a COORDINATED TRANSFER, where the
                    // recipient supplies their own address rather than the proposer guessing
                    // it. Naming which arg is the recipient (+ the chain) makes the proposal
                    // declare a counterparty slot the room asks the recipient to fill; for a
                    // lez:* chain it also declares the proposer's LEZ-account requirement. Left
                    // off, the action proposes as a plain invoke — nothing changes.
                    LogosButton {
                        objectName: "roomModeBToggle"
                        visible: room.chosenAction !== null
                        Layout.fillWidth: true
                        text: room.modeB
                            ? qsTr("✓ Coordinated transfer — recipient shares their address")
                            : qsTr("Make it a coordinated transfer (ask the recipient)")
                        variant: room.modeB ? LogosButton.Variant.Secondary
                                            : LogosButton.Variant.Tertiary
                        onClicked: room.modeB = !room.modeB
                    }
                    ColumnLayout {
                        visible: room.chosenAction !== null && room.modeB
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosTextField {
                            id: proposeCounterparty
                            objectName: "roomProposeCounterparty"
                            Layout.fillWidth: true
                            // which arg name holds the recipient — the effect field the shared
                            // address lands in (e.g. "to"). The room then asks the recipient.
                            placeholderText: qsTr("recipient arg name (e.g. to)")
                            text: "to"
                            font.family: Theme.typography.mono
                        }
                        LogosTextField {
                            id: proposeChain
                            objectName: "roomProposeChain"
                            Layout.fillWidth: true
                            placeholderText: qsTr("chain (e.g. lez:testnet)")
                            font.family: Theme.typography.mono
                        }
                    }
                }

                // ── split (exo-a90): the total, who paid, who's in, and what each owes ──
                // Whoever paid is the creditor: you, paid at your own address, or someone
                // else, paid at the address they shared (exo-770). Every person named — the
                // creditor too — must agree before anyone pays. Amounts are ETH here and
                // exact wei on the card (string arithmetic — no floats).
                ColumnLayout {
                    visible: room.composeType === "split"
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: splitTotal
                            objectName: "roomSplitTotal"
                            visible: !room.acrossOpen     // a settle-up has no total of its own
                            Layout.preferredWidth: 160
                            placeholderText: qsTr("total (%1)").arg(room.splitFiat ? String(room.splitFiatCurrency).toUpperCase()
                                                                                     : room.splitUnit)
                            font.family: Theme.typography.mono
                        }
                        LogosTextField {
                            id: splitMemo
                            objectName: "roomSplitMemo"
                            Layout.fillWidth: true
                            placeholderText: qsTr("what for (only the room sees this)")
                        }
                    }

                    // pay in a token instead of ETH (exo-5ab): the token's own answer — its
                    // symbol and decimals — shown beside its address, because a token names itself
                    // a bill in another currency (exo-3a4): the total above is then in that
                    // currency, and the rate is YOUR quote — recorded with the proposal
                    LogosButton {
                        objectName: "roomSplitFiat"
                        visible: !room.acrossOpen
                        Layout.preferredWidth: 320   // the label whole, never "…curre…"
                        text: room.splitFiat ? qsTr("✓ The bill is in another currency") : qsTr("The bill is in another currency")
                        variant: room.splitFiat ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: room.splitFiat = !room.splitFiat
                    }
                    RowLayout {
                        visible: room.splitFiat && !room.acrossOpen
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            objectName: "roomSplitFiatCurrency"
                            Layout.preferredWidth: 70
                            text: room.splitFiatCurrency
                            placeholderText: qsTr("EUR")
                            onTextChanged: room.splitFiatCurrency = String(text).trim().toUpperCase()
                        }
                        LogosTextField {
                            objectName: "roomSplitFiatRate"
                            Layout.preferredWidth: 200
                            placeholderText: qsTr("1 %1 = ? %2").arg(room.splitFiatCurrency || "EUR").arg(room.splitUnit)
                            font.family: Theme.typography.mono
                            onTextChanged: room.splitFiatRate = String(text).trim()
                        }
                        LogosTextField {
                            objectName: "roomSplitFiatSource"
                            Layout.fillWidth: true
                            placeholderText: qsTr("where the rate is from (everyone will see it)")
                            onTextChanged: room.splitFiatSource = String(text)
                        }
                    }
                    LogosText {
                        objectName: "roomSplitFiatNote"
                        visible: room.splitFiat && !room.acrossOpen
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        wrapMode: Text.WordWrap
                        readonly property string conv: room.fiatTotal(splitTotal.text)
                        text: conv.length > 0
                              ? qsTr("%1 %2 at 1 %2 = %3 %4 comes to %5 %4. The rate is your quote: it is recorded with the proposal, and everyone agreeing trusts it.")
                                    .arg(splitTotal.text).arg(room.splitFiatCurrency).arg(room.splitFiatRate)
                                    .arg(room.splitUnit).arg(room.weiToEth(conv))
                              : qsTr("⚠ Type the bill in %1 (at most %2 decimals), and the rate as %3 per 1 %1.")
                                    .arg(room.splitFiatCurrency || "EUR").arg(room.fiatDecimals(room.splitFiatCurrency))
                                    .arg(room.splitUnit)
                        color: conv.length > 0 && String(room.splitFiatSource).trim().length > 0
                               ? Theme.palette.textSecondary : Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }

                    LogosTextField {
                        objectName: "roomSplitToken"
                        visible: !room.splitPrivate && !room.splitBitcoin
                        Layout.fillWidth: true
                        placeholderText: qsTr("pay in a token instead of ETH: its address (0x…), or leave empty")
                        font.family: Theme.typography.mono
                        onTextChanged: {
                            var t = String(text).trim().toLowerCase();
                            room.splitToken = /^0x[0-9a-f]{40}$/.test(t) ? t : (t.length > 0 ? t : "");
                            if (/^0x[0-9a-f]{40}$/.test(t) && room.backend) room.backend.lookupToken("", t);
                        }
                    }
                    LogosText {
                        visible: !room.splitPrivate && !room.splitBitcoin && room.splitToken.length > 0
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        wrapMode: Text.WordWrap
                        text: room.splitTokenInfo
                              ? qsTr("%1 — the token at %2 says so; %3 decimals. A token names itself: check the address.")
                                    .arg(room.splitUnit)
                                    .arg(room.splitToken.slice(0, 8) + "…" + room.splitToken.slice(-6))
                                    .arg(room.splitDecimals)
                              : !/^0x[0-9a-f]{40}$/.test(room.splitToken)
                              ? qsTr("⚠ A token is named by its address: 0x and 40 hex characters.")
                              : qsTr("⚠ Your RPC could not read that token (no decimals()) — is it on this chain?")
                        color: room.splitTokenInfo ? Theme.palette.textSecondary : Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // settle up instead (exo-3c6): net the room's agreed, unpaid shares on this rail
                    // into fewer payments — every party agrees before anything is paid
                    LogosButton {
                        objectName: "roomSettleUp"
                        visible: !room.splitPrivate && !room.acrossOpen
                        enabled: !room.composeBlocked     // exo-dcc.10, as Propose
                        Layout.preferredWidth: 320
                        text: qsTr("Settle up the room's open splits instead")
                        variant: LogosButton.Variant.Secondary
                        onClicked: {
                            if (!room.backend) return;
                            room.backend.proposeSettleUp("", room.splitTokenInfo ? String(room.splitTokenInfo.asset) : "",
                                                         String(splitMemo.text || ""));
                            room.composing = false;
                        }
                    }

                    // across assets and chains (exo-a90.17): the shares owed in other assets
                    // or on other chains too, each at the rate YOU give — everyone agrees to it
                    LogosButton {
                        objectName: "roomSettleUpAcrossOpen"
                        visible: !room.splitPrivate && !room.acrossOpen
                        Layout.preferredWidth: 320
                        text: qsTr("Settle up across assets and chains…")
                        variant: LogosButton.Variant.Secondary
                        onClicked: {
                            room.acrossRates = ({});
                            acrossSource.text = "";
                            room.acrossPending = false;
                            room.acrossOpen = true;
                            if (room.backend) room.backend.loadOpenAssets();
                        }
                    }
                    ColumnLayout {
                        objectName: "roomSettleUpAcrossBox"
                        visible: !room.splitPrivate && room.acrossOpen
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny
                        LogosText {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0
                            wrapMode: Text.WordWrap
                            text: qsTr("Paid in %1. Give a rate for each other asset the room owes in: the shares in it are converted at your rate, rounded down. Everyone the shares name must agree, and agreeing means trusting your rates.")
                                  .arg(room.splitUnit)
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.badgeText
                        }
                        Repeater {
                            // only while open: closing destroys the fields, so what they show is
                            // always what acrossRates holds
                            model: room.acrossOpen ? room.acrossOthers : []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosText {
                                    // wraps: a chain id is long, and the row never widens the column
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 0
                                    wrapMode: Text.Wrap
                                    text: qsTr("1 %1 on %2 (%3) =").arg(String(modelData.symbol || modelData.asset))
                                          .arg(String(modelData.chainLabel || modelData.chain))
                                          .arg(Number(modelData.parts) === 1 ? qsTr("1 share") : qsTr("%1 shares").arg(modelData.parts))
                                    color: Theme.palette.text
                                    font.pixelSize: Theme.typography.secondaryText
                                }
                                LogosTextField {
                                    objectName: "roomAcrossRate_" + String(modelData.asset).replace(/[^A-Za-z0-9]/g, "").slice(0, 16)
                                    Layout.preferredWidth: 140
                                    placeholderText: qsTr("rate")
                                    onTextChanged: {
                                        var r = Object.assign({}, room.acrossRates);
                                        r[String(modelData.chain) + "|" + String(modelData.asset)] = String(text);
                                        room.acrossRates = r;
                                    }
                                }
                                LogosText {
                                    text: room.splitUnit
                                    color: Theme.palette.textSecondary
                                    font.pixelSize: Theme.typography.secondaryText
                                }
                            }
                        }
                        LogosText {
                            visible: room.acrossOthers.length === 0
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("The room owes in no other asset and on no other chain right now.")
                            color: Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosTextField {
                            id: acrossSource
                            objectName: "roomAcrossSource"
                            visible: room.acrossOthers.length > 0
                            Layout.fillWidth: true
                            placeholderText: qsTr("where these rates come from (everyone sees this)")
                        }
                        RowLayout {
                            spacing: Theme.spacing.small
                            LogosButton {
                                objectName: "roomSettleUpAcross"
                                text: qsTr("Propose the settle-up")
                                enabled: !room.composeBlocked && room.acrossPriced.length > 0
                                         && String(acrossSource.text || "").trim().length > 0
                                onClicked: {
                                    if (!room.backend) return;
                                    var rates = room.acrossPriced.map(function (r) {
                                        return {chain: r.chain, asset: r.asset, rate: r.rate,
                                                source: String(acrossSource.text || "").trim()};
                                    });
                                    room.acrossPending = true;
                                    room.backend.proposeSettleUpAcross("", room.acrossPayAsset === "ETH" || room.acrossPayAsset === "BTC"
                                                                           ? "" : room.acrossPayAsset,
                                                                       JSON.stringify(rates), String(splitMemo.text || ""));
                                }
                            }
                            LogosButton {
                                objectName: "roomSettleUpAcrossCancel"
                                text: qsTr("Cancel")
                                variant: LogosButton.Variant.Secondary
                                onClicked: { room.acrossOpen = false; room.acrossPending = false; }
                            }
                        }
                    }

                    // who fronted it (exo-770): you, or someone else — then it is paid at the
                    // address they shared, and nobody pays until they agree it is theirs
                    LogosText {
                        visible: !room.splitPrivate && !room.splitBitcoin && room.members.length > 1 && !room.acrossOpen
                        text: qsTr("Who paid the bill?")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                    Flow {
                        visible: !room.splitPrivate && !room.splitBitcoin && room.members.length > 1 && !room.acrossOpen
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny
                        Repeater {
                            model: room.members.filter(function (m) { return !!m; })
                            delegate: LogosButton {
                                required property var modelData
                                readonly property string ident: modelData.self ? "" : String(modelData.identity || "")
                                objectName: "roomSplitPaidBy_" + (modelData.self ? "me" : ident.slice(0, 8))
                                text: modelData.self ? qsTr("I did") : room.memberLabel(ident)
                                variant: room.splitCreditor === ident ? LogosButton.Variant.Primary
                                                                     : LogosButton.Variant.Secondary
                                onClicked: { room.splitCreditor = ident; room.splitOut = ({}); }
                            }
                        }
                    }
                    LogosText {
                        objectName: "roomSplitPaidTo"
                        visible: room.splitFor.length > 0 && !room.acrossOpen
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        wrapMode: Text.WordWrap
                        readonly property string addr: room.sharedAddressOf(room.splitFor)
                        text: addr.length > 0
                              ? qsTr("Paid to %1, the address %2 shared. Nobody pays until %2 agrees it is theirs.")
                                    .arg(addr).arg(room.memberLabel(room.splitFor))
                              : qsTr("⚠ %1 hasn't shared an address in this room: ask them to share one (the Pay composer's “Ask the room”), then split it for them.")
                                    .arg(room.memberLabel(room.splitFor))
                        color: addr.length > 0 ? Theme.palette.textSecondary : Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }

                    LogosText {
                        visible: !room.acrossOpen
                        text: room.members.length > 1
                              ? (room.splitFor.length > 0
                                 ? qsTr("Who owes %1 a share — tap to leave someone out:").arg(room.memberLabel(room.splitFor))
                                 : qsTr("Who owes you a share — tap to leave someone out:"))
                              : qsTr("Nobody here owes you yet: invite and admit the people who shared it, then split.")
                        color: room.members.length > 1 ? Theme.palette.textTertiary : Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }

                    Flow {
                        visible: !room.acrossOpen
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny
                        Repeater {
                            // everyone but whoever fronted it — you among them when it was someone else
                            model: room.members.filter(function (m) {
                                return m && (room.splitFor.length === 0 ? !m.self
                                             : String(m.identity || "").toLowerCase() !== room.splitFor.toLowerCase());
                            })
                            delegate: LogosButton {
                                required property var modelData
                                readonly property string ident: String(modelData.identity || "")
                                objectName: "roomSplitWho_" + ident.slice(0, 8)
                                text: modelData.self ? qsTr("You")
                                      : (modelData.alias && String(modelData.alias).length > 0)
                                      ? String(modelData.alias) : ident.slice(0, 10) + "…"
                                variant: room.splitOut[ident]
                                         ? LogosButton.Variant.Secondary : LogosButton.Variant.Primary
                                onClicked: room.splitToggle(ident)
                            }
                        }
                        LogosButton {
                            objectName: "roomSplitMine"
                            text: room.splitFor.length > 0
                                  ? (room.splitCreditorShares ? qsTr("✓ %1 is in it too").arg(room.memberLabel(room.splitFor))
                                                              : qsTr("%1 is not in it").arg(room.memberLabel(room.splitFor)))
                                  : room.splitCreditorShares ? qsTr("✓ I'm in it too") : qsTr("I'm not in it (chip in)")
                            variant: room.splitCreditorShares ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                            onClicked: room.splitCreditorShares = !room.splitCreditorShares
                        }
                    }

                    LogosText {
                        objectName: "roomSplitPreview"
                        readonly property var pv: room.splitPreview(splitTotal.text)
                        visible: splitTotal.text.length > 0 && !room.acrossOpen
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0   // wrap within the column; never widen it
                        wrapMode: Text.WordWrap
                        text: room.splitTotalOf(splitTotal.text).length === 0
                              ? (room.splitFiat ? qsTr("⚠ The bill and the rate are needed to work out each share (see above).")
                                 : qsTr("⚠ Type the total in %1, e.g. 1.2 (at most %2 decimals).").arg(room.splitUnit).arg(room.splitDecimals))
                              : pv === null ? qsTr("Leave at least one person in.")
                              : room.splitDust(pv)
                              ? qsTr("⚠ Each share would be %1 sat — below Bitcoin's 546-sat dust limit, so it could never be paid.").arg(pv.each)
                              : room.splitFor.length > 0
                              ? (pv.n === 1
                                 ? qsTr("1 person owes %4 %1 %3; %4's own share is %2 %3 (it absorbs any rounding). They pay from their own wallet — the payment is public on the chain.")
                                       .arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit)
                                       .arg(room.memberLabel(room.splitFor))
                                 : qsTr("%1 people owe %5 %2 %4 each; %5's own share is %3 %4 (it absorbs any rounding). Each pays from their own wallet — every payment is public on the chain.")
                                       .arg(pv.n).arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit)
                                       .arg(room.memberLabel(room.splitFor)))
                              : room.splitPrivate
                              ? (pv.n === 1
                                 ? qsTr("1 person owes you about %1 LEZ. They pay privately from their own wallet: the chain learns only that a private transfer happened, and your own scan finds the note by its amount.")
                                       .arg(room.weiToEth(pv.each))
                                 : qsTr("%1 people owe you about %2 LEZ each — every share a few base units apart, so your scan can tell whose payment arrived without the chain naming anyone; your own share absorbs the rest. Each pays privately from their own wallet: the chain learns only that private transfers happened.")
                                       .arg(pv.n).arg(room.weiToEth(pv.each)))
                              : (pv.n === 1
                                 ? qsTr("1 person owes you %1 %3; your own share is %2 %3 (it absorbs any rounding). They pay from their own wallet — the payment is public on the chain.")
                                       .arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit)
                                 : qsTr("%1 people owe you %2 %4 each; your own share is %3 %4 (it absorbs any rounding). Each pays from their own wallet — every payment is public on the chain.")
                                       .arg(pv.n).arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit))
                              // a Bitcoin share in the unit it is paid and confirmed in: exact satoshis
                              + (room.splitBitcoin && pv !== null && !room.splitDust(pv)
                                 ? qsTr(" Each share is exactly %1 sat.").arg(pv.each) : "")
                        color: (pv === null || room.splitDust(pv))
                               ? Theme.palette.warning : Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }

                // payment: recipient (+ amount below). You can type it, or ask the room —
                // the counterparty answers with their own address (ask-then-disclose), so
                // the demo shows the Safe's recipient being DISCLOSED, not pre-known.
                RowLayout {
                    visible: room.composeType === "payment"
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosTextField {
                        id: proposeTo
                        objectName: "roomProposeTo"
                        Layout.fillWidth: true
                        placeholderText: room.isLezPolicy ? qsTr("recipient token holding (base58 or hex)")
                                       : room.isBtcPolicy ? qsTr("recipient Bitcoin address (bc1… / tb1… / bcrt1…)")
                                       : qsTr("recipient (0x…)")
                        font.family: Theme.typography.mono
                    }

                    // Post an address-request card into the thread. A room member (the
                    // counterparty) answers it with "Share an address", disclosing their
                    // own address; "Use as recipient" on that card fills this field.
                    LogosButton {
                        objectName: "roomAskAddress"
                        // No one to ask until someone else is in the room — and a request
                        // posted while you're alone can't reach a later joiner anyway (the
                        // room re-keys when they're admitted, F-16), so it's disabled until
                        // the roster has someone else. Admitting a member re-sends any
                        // outstanding ask into their epoch (see onAdmit below).
                        enabled: room.members.length >= 2
                        text: room.members.length >= 2 ? qsTr("Ask the room")
                                                       : qsTr("Ask the room (no one else yet)")
                        variant: LogosButton.Variant.Secondary
                        onClicked: {
                            if (!room.backend) return;
                            room.backend.postMessage(JSON.stringify({
                                kind: "address-request",
                                intent: "pay",
                                purpose: proposeValue.text.length > 0
                                    ? qsTr("Pay %1 wei").arg(proposeValue.text)
                                    : qsTr("Pay someone from the room")
                            }));
                        }
                    }
                }

                // statement: the text the room ratifies.
                LogosTextField {
                    id: proposeText
                    objectName: "roomProposeText"
                    visible: room.composeType === "statement"
                    Layout.fillWidth: true
                    placeholderText: qsTr("what the room ratifies…")
                }

                // Not enough people to act on a proposal yet — say so, and that Propose
                // is off until the room fills. You compose it now; you submit it once the
                // people it takes to agree are here (so it isn't sealed away from them).
                LogosText {
                    objectName: "roomProposeGate"
                    visible: !room.enoughToPropose
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("Waiting for the room to fill — a proposal needs at least %1 "
                             + "people here to act on it. Invite someone and admit them, "
                             + "then Propose. (%2 here now.)")
                          .arg(room.requiredToPropose).arg(room.members.length)
                    color: Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                }

                RowLayout {
                    // the across box has its own Propose and Cancel (exo-a90.17)
                    visible: !(room.composeType === "split" && room.acrossOpen)
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosTextField {
                        id: proposeValue
                        objectName: "roomProposeValue"
                        visible: room.composeType === "payment"
                        Layout.fillWidth: true
                        // wei — the Safe transfers this exact value; the balance above is
                        // shown in ETH and in wei so the unit you type against is explicit.
                        // A Bitcoin payment is in satoshis.
                        placeholderText: room.isBtcPolicy ? qsTr("amount (sat)")
                                       : room.isLezPolicy ? qsTr("amount (token units)") : qsTr("amount (wei)")
                        font.family: Theme.typography.mono
                        // Any run of digits: amounts are arbitrary precision (wei exceeds
                        // 32 bits: 0.001 ETH is 10^15). IntValidator capped input at
                        // 2147483647 (exo-4da).
                        validator: RegularExpressionValidator { regularExpression: /[0-9]*/ }
                    }

                    // a Bitcoin payment's fee rate: sat/vB over an upper bound of its
                    // signed size, paid out of the account's own coins
                    LogosTextField {
                        id: proposeFeeRate
                        objectName: "roomProposeFeeRate"
                        visible: room.composeType === "payment" && room.isBtcPolicy
                        Layout.preferredWidth: 150
                        placeholderText: qsTr("fee (sat/vB)")
                        text: "2"
                        font.family: Theme.typography.mono
                        validator: IntValidator { bottom: 1 }
                    }

                    // keep the buttons right-aligned when the amount field is hidden.
                    Item { visible: room.composeType !== "payment"; Layout.fillWidth: true }

                    LogosButton {
                        objectName: "roomProposeSubmit"
                        text: qsTr("Propose")
                        // a payment needs a recipient AND an amount within the Safe's known
                        // balance — can't over-send (exo-bf9); the ⚠ above says why it's off.
                        // AND the room must have enough people to act on it (see the hint):
                        // don't submit a proposal into a room that can't yet agree to it.
                        // AND no module your own part needs is definitely missing (exo-dcc.10;
                        // the line under the kind picker says which).
                        enabled: !room.composeBlocked && (
                                 room.composeType === "split" ? room.splitPreview(splitTotal.text) !== null && !room.splitTokenPending
                                                                && !room.splitDust(room.splitPreview(splitTotal.text))
                                                                && (!room.splitFiat || String(room.splitFiatSource).trim().length > 0)
                                                                && (room.splitFor.length === 0 || room.sharedAddressOf(room.splitFor).length > 0)
                               : room.enoughToPropose && (
                                 room.composeType === "statement" ? proposeText.text.length > 0
                               : room.composeType === "action" ? room.chosenAction !== null
                               : room.isBtcPolicy ? proposeTo.text.length > 0 && proposeValue.text.length > 0
                               : room.isLezPolicy ? proposeTo.text.length > 0 && proposeValue.text.length > 0
                               : proposeTo.text.length > 0 && !room.overSends(proposeValue.text)))
                        onClicked: {
                            if (room.composeType === "split") {
                                room.proposeSplit(splitTotal.text, splitMemo.text);
                                splitTotal.text = "";
                                splitMemo.text = "";
                            } else if (room.composeType === "statement") {
                                room.proposeStatement(proposeText.text);
                                proposeText.text = "";
                            } else if (room.composeType === "action") {
                                // Mode B passes the counterparty arg + chain (exo-45e); off,
                                // they're empty and it proposes as a plain invoke.
                                room.proposeAction(room.chosenAction, proposeArgs.text,
                                    room.modeB ? proposeCounterparty.text : "",
                                    room.modeB ? proposeChain.text : "");
                                proposeArgs.text = "";
                                proposeChain.text = "";
                            } else if (room.isLezPolicy) {
                                // the proposer's own Propose, sent now; the card appears
                                // once a block includes it
                                if (room.backend) room.backend.proposeLezTransfer(proposeTo.text, proposeValue.text);
                                proposeTo.text = "";
                                proposeValue.text = "";
                                room.composing = false;
                            } else if (room.isBtcPolicy) {
                                // coins read from your node, change back to the account
                                if (room.backend)
                                    room.backend.proposeBtcSpend(proposeTo.text, proposeValue.text,
                                                                 proposeFeeRate.text.length > 0 ? proposeFeeRate.text : "1");
                                proposeTo.text = "";
                                proposeValue.text = "";
                                room.composing = false;
                            } else {
                                room.proposeFrom(proposeTo.text, proposeValue.text);
                                proposeTo.text = "";
                                proposeValue.text = "";
                            }
                        }
                    }

                    LogosButton {
                        objectName: "roomProposeCancel"
                        text: qsTr("Cancel")
                        onClicked: room.composing = false
                    }
                }
            }

            // a split action that did nothing says why — never a silent no-op (exo-a90)
            LogosText {
                objectName: "roomSplitFeedback"
                visible: !!(room.splitResult && room.splitResult.error)
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    var r = room.splitResult || {};
                    var what = r.op === "pay" ? qsTr("Your share was not paid")
                             : r.op === "confirm" ? qsTr("The share was not confirmed")
                             : r.op === "settle-up" ? qsTr("Nothing was settled up")
                             : qsTr("The split was not proposed");
                    if (String(r.error || "") === "no-address")
                        return room.noAddressAnswered
                               ? qsTr("✓ %1 has shared an address on %2 — propose the settle-up again.")
                                     .arg(String(r.name || "")).arg(String(r.chainLabel || r.chain || ""))
                               : qsTr("⚠ %1 — %2 has shared no address on %3 to be paid at. Ask them to share one, then propose again.")
                                     .arg(what).arg(String(r.name || "")).arg(String(r.chainLabel || r.chain || ""));
                    if (String(r.error || "") === "expired-duplicate")
                        return qsTr("⚠ %1 — an identical split expired in this room. Change its note to propose it again, or renew the old one's unpaid shares from its card.").arg(what);
                    return qsTr("⚠ %1 — %2%3").arg(what).arg(String(r.error || ""))
                               .arg(r.detail ? ": " + String(r.detail) : "");
                }
                color: room.noAddressAnswered ? Theme.palette.textSecondary : Theme.palette.warning
                font.pixelSize: Theme.typography.badgeText
            }

            // a settle-up across chains needs an address the recipient shared (exo-a90.17): ask
            LogosButton {
                objectName: "roomAskSettleAddress"
                visible: !!(room.splitResult && String(room.splitResult.error || "") === "no-address") && !room.noAddressAnswered
                Layout.preferredWidth: 320
                text: qsTr("Ask %1 to share an address").arg(String((room.splitResult && room.splitResult.name) || ""))
                variant: LogosButton.Variant.Secondary
                onClicked: {
                    if (!room.backend) return;
                    var ch = String(room.splitResult.chain || "");
                    var label = String(room.splitResult.chainLabel || ch);
                    // asked of one member (exo-8e2): only they are offered "Share", and the
                    // card says when they have answered
                    room.backend.postMessage(JSON.stringify({
                        kind: "address-request", intent: "settle-up",
                        asset: ch.indexOf("bip122:") === 0 ? "BTC" : "ETH", chain: ch, chainLabel: label,
                        "for": String(room.splitResult.who || ""),
                        purpose: qsTr("Settle up across chains: an address on %1").arg(label)
                    }));
                }
            }

            // a Bitcoin payment that could not be proposed says why (no node configured,
            // the node unreachable, not enough in the account) — never a silent no-op
            LogosText {
                objectName: "roomBtcProposeFeedback"
                visible: !!(room.btcPropose && room.btcPropose.error)
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("⚠ The Bitcoin payment was not proposed — %1%2")
                      .arg(String((room.btcPropose && room.btcPropose.error) || ""))
                      .arg(room.btcPropose && room.btcPropose.detail ? ": " + String(room.btcPropose.detail) : "")
                color: Theme.palette.warning
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }

            // a LEZ multisig proposal is sent at once and appears once the chain has it;
            // say which, or why it was not sent (exo-3c9)
            LogosText {
                objectName: "roomLezProposeFeedback"
                visible: !!(room.lezPropose && (room.lezPropose.error || room.lezPropose.pending))
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: room.lezPropose && room.lezPropose.error
                      ? qsTr("⚠ The LEZ proposal was not sent — %1%2")
                            .arg(String(room.lezPropose.error))
                            .arg(room.lezPropose.detail ? ": " + String(room.lezPropose.detail) : "")
                      : qsTr("⏳ Proposal #%1 is on its way to the chain (tx %2…) — it appears here once a block includes it.")
                            .arg(String((room.lezPropose && room.lezPropose.index) || "?"))
                            .arg(String((room.lezPropose && room.lezPropose.tx) || "").slice(0, 12))
                color: room.lezPropose && room.lezPropose.error ? Theme.palette.warning : Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
            RowLayout {
                objectName: "roomLezVaultInit"
                visible: room.policyKind === "lez-multisig" && room.composing
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosTextField {
                    id: lezDefinition
                    objectName: "roomLezDefinition"
                    Layout.fillWidth: true
                    placeholderText: qsTr("token definition account — to set up the vault to hold it")
                    font.family: Theme.typography.mono
                }
                LogosButton {
                    objectName: "roomLezVaultInitPropose"
                    text: qsTr("Propose vault setup")
                    enabled: !room.composeBlocked && room.enoughToPropose && lezDefinition.text.length > 0
                    onClicked: {
                        if (room.backend) room.backend.proposeLezVaultInit(lezDefinition.text);
                        lezDefinition.text = "";
                        room.composing = false;
                    }
                }
            }

            // a vote-locus approval is the member's own chain transaction: sent now, it
            // counts once a block includes it
            LogosText {
                objectName: "roomApprovePending"
                visible: !!(room.contributeResult && String(room.contributeResult.state || "").indexOf("pending") === 0)
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("⏳ Your vote is on its way to the chain — it counts once a block includes it.")
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.badgeText
            }

            // approval feedback — an in-app Approve that didn't count says WHY, right
            // here, instead of silently doing nothing. The common case: your key isn't
            // a recognized signer for the intent's policy (a Safe owner / an attester).
            LogosText {
                objectName: "roomApproveFeedback"
                visible: room.contributeResult && room.contributeResult.ok === false
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    var r = room.contributeResult || ({});
                    var reason = String(r.reason || "");
                    if (reason === "rejected")
                        return qsTr("⚠ Your approval didn't count — your key isn't a recognized "
                                  + "signer for this intent's policy (a Safe owner, or an "
                                  + "attester). Check the signing identity above.");
                    if (reason === "not-joined")
                        return qsTr("⚠ Not in a room — join one first.");
                    if (reason === "unknown-intent")
                        return qsTr("⚠ That proposal isn't in the room's log yet — give it a moment.");
                    // A proposal reaches you as several log entries; its signing context can
                    // arrive a moment after the proposal itself (exo-ca3). Nothing is signed
                    // without it (invariant 2), so say that, and that trying again will do.
                    if (reason === "no-context")
                        return qsTr("⚠ Nothing was signed — this proposal's signing context (the "
                                  + "environment, account and expiry your signature binds to) hasn't "
                                  + "reached you yet. Give it a moment and approve again.");
                    if (reason === "unaccountable-input")
                        return qsTr("⚠ Nothing was signed — an input that reached this proposal's bytes "
                                  + "can't be accounted for. If its log entry is still on the way, "
                                  + "approving again in a moment will work; if not, it can't be signed.");
                    if (reason === "attestation-mismatch")
                        return qsTr("⚠ Your approval wasn't published — the attestation your key made "
                                  + "doesn't verify as the signer the driver recovered, so every member "
                                  + "would reject it. Nothing was sent.");
                    return qsTr("⚠ Approval didn't count — %1").arg(reason);
                }
                color: Theme.palette.warning
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }

            // the message row.
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosButton {
                    objectName: "roomProposeButton"
                    Layout.preferredWidth: 48
                    text: room.composing ? qsTr("×") : qsTr("+")
                    onClicked: room.composing = !room.composing
                }

                LogosTextField {
                    id: composer
                    objectName: "messageComposer"
                    Layout.fillWidth: true
                    placeholderText: qsTr("Say something")
                }

                // Enter sends — the inner TextInput emits accepted on Return.
                Connections {
                    target: composer.textInput
                    function onAccepted() { sendButton.send(); }
                }

                LogosButton {
                    id: sendButton
                    objectName: "sendMessageButton"
                    text: qsTr("Send")
                    enabled: composer.text.length > 0
                    function send() {
                        if (room.backend && composer.text.length > 0) {
                            room.backend.postMessage(composer.text);
                            composer.text = "";
                        }
                    }
                    onClicked: send()
                }
            }
        }
        }

        // Right: the room's meta-state — its history (how it got here) on top, then
        // who can see this (the roster + scope). Both are folds of the same sealed
        // log; the handshake signals go to the module through the backend.
        ColumnLayout {
            visible: room.joined
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            spacing: Theme.spacing.large

            // The connections and accounts block is taller than a window (Safe, Bitcoin,
            // FROST and LEZ multisig sections), and it used to set the whole room's height —
            // pushing the message row and its "+" below the bottom of a normal window
            // (exo-9a4). It scrolls in its own share of the column now, as the history and
            // the scope below it do; its width stays its natural width.
            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 2
                implicitWidth: topCol.implicitWidth
                clip: true
                contentWidth: width
                contentHeight: topCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: topCol
                width: parent.width
                spacing: Theme.spacing.large

            // What the room depends on, and whether it's actually there (invariant 8).
            ConnectionIndicators {
                Layout.fillWidth: true
                status: room.connectivity
            }

            // The accounts members have disclosed into this room (exo-a50.1.3).
            RoomAccounts {
                Layout.fillWidth: true
                accounts: room.roomAccounts
                discloseResult: room.discloseResult
                suggestionAvailable: {
                    try { return JSON.parse(room.backend ? room.backend.accountJson : "{}").available !== false; }
                    catch (e) { return true; }
                }
                defaultChainId: {
                    try { return String(JSON.parse(room.backend ? room.backend.accountJson : "{}").defaultChainId || "31337"); }
                    catch (e) { return "31337"; }
                }
                lezMember: room.lezMember
                lezCreate: room.lezCreate
                frostCeremonies: room.frostCeremonies
                frostCeremony: room.frostCeremony
                onFrostOpenRequested: function (cid, network, t, n) {
                    if (room.backend) room.backend.frostCeremonyOpen(cid, network, t, n);
                }
                onFrostJoinRequested: function (cid) { if (room.backend) room.backend.frostCeremonyJoin(cid); }
                onDiscloseRequested: function (accountJson) { if (room.backend) room.backend.discloseAccount(accountJson); }
                onLezMemberRequested: if (room.backend) room.backend.lezMemberAccount("")
                onLezCreateRequested: function (threshold, members) {
                    if (room.backend) room.backend.lezCreateMultisig(threshold, members);
                }
                onDiscloseSuggested: if (room.backend) room.backend.discloseSuggestedAccount()
            }
            }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.palette.borderSubtle
            }

            // History first — paramount to the education mission: a member sees the
            // decisions that led to the current state, and each update as it lands.
            ActivityFeed {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 1     // share the column with the scope panel
                entries: room.activity
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.palette.borderSubtle
            }

            // Who can see what — the information-flow view folded from the same log
            // (exo-002.5). The store node is always listed (FS-9).
            FlowView {
                objectName: "flowView"
                Layout.fillWidth: true
                flow: room.flow
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.palette.borderSubtle
            }

            ScopePanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 1
                members: room.members
                pending: room.pending
                topic: room.topic
                joinStatus: room.backend ? String(room.backend.joinStatus || "") : ""
                securityLevels: room.securityLevels
                onRequestJoin: if (room.backend) room.backend.requestJoin()
                onAdmit: function(identityHex) {
                    if (!room.backend) return;
                    room.backend.admit(identityHex);
                    // The admit re-keyed the room to a new epoch the joiner now shares.
                    // Anything from before their epoch is unreadable to them (F-16), so
                    // re-send it into the new epoch: an unanswered address request, and any
                    // open proposal (its card) — otherwise a payment proposed before they
                    // joined never reaches them to approve.
                    room.resendOutstandingAsk();
                    room.backend.reannounce();
                }
            }
        }
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
        }
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
