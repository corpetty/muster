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
    readonly property bool joined: room.topic.length > 0

    // Whether the proposal composer is open (the "+" in the message row), and which
    // effect type is being composed: "payment" (a transfer) or "statement" (text the
    // room ratifies). The action is pluggable — the same path coordinates either.
    property bool composing: false
    property string composeType: "payment"

    // When composeType is "action" (a generic module action, P-D4), which action the
    // picker has selected — {module, method, signature, params, allowed} — or null.
    property var chosenAction: null

    // Parsed folds. A parse failure yields [] (absent), never fiction.
    readonly property var messages: {
        try { return JSON.parse(backend ? backend.messagesJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var members: {
        try { return JSON.parse(backend ? backend.membersJson : "[]"); }
        catch (e) { return []; }
    }
    // Join-requests not yet admitted: [{ identity, bindsOwner }]. The scope panel
    // lists these with an Admit action (the membership handshake).
    readonly property var pending: {
        try { return JSON.parse(backend ? backend.pendingJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var intents: {
        try { return JSON.parse(backend ? backend.intentsJson : "[]"); }
        catch (e) { return []; }
    }
    // The room's coordination history (coordinate_activity): a plain-language
    // narrative of every state transition, in causal order, folded from the SAME
    // log the cards come from. The education seam — how the room got here.
    readonly property var activity: {
        try { return JSON.parse(backend ? backend.activityJson : "[]"); }
        catch (e) { return []; }
    }
    // Liveness of the infrastructure the room relies on (connectivity):
    // {rpc:{name,level,endpoint,detail}, delivery:{name,level,detail}}. Invariant 8
    // — the store nodes and RPC are untrusted, user-chosen infra, so their status
    // is shown, never assumed.
    readonly property var connectivity: {
        try { return JSON.parse(backend ? backend.connectivityJson : "{}"); }
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
    // entry — ask-then-disclose.
    onComposingChanged: if (composing) refreshRoomAccount()
    onPolicyKindChanged: if (composing) refreshRoomAccount()
    // The outcome of the last room-side submit (coordinate_submit): {id, state,
    // onchain, txHash} or {id, error, ...}. Matched to a card by its intent id.
    readonly property var roomSubmit: {
        try { return JSON.parse(backend ? backend.roomSubmitJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The driver kinds this room may use (coordinate_drivers) — driver-as-proposal.
    // Grows by approved add-driver proposal; the picker offers only these.
    readonly property var drivers: {
        try { return JSON.parse(backend ? backend.driversJson : "[\"safe\",\"threshold\"]"); }
        catch (e) { return ["safe", "threshold"]; }
    }
    function hasDriver(k) { return (room.drivers || []).indexOf(k) >= 0; }

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
    // Refresh the action menu when the action composer opens — the module queries each
    // candidate module's methods (never a blind scan), so not on the message tick.
    onComposeTypeChanged: if (composing && composeType === "action" && room.backend)
                              room.backend.loadAvailableActions();

    // The COMPOSE DEFAULT policy (driver) for the next thing you propose here, from
    // coordinate_policy. Policy is a property of each intent, not the room — the room
    // is a security/privacy boundary, an intent is a policy boundary — so this only
    // stamps the next proposal; each card keeps the policy it was proposed under.
    readonly property var policy: {
        try { return JSON.parse(backend ? backend.policyJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property string policyKind:
        (room.policy && room.policy.policy) ? String(room.policy.policy) : "safe"

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
    // the card's shorter rail (proposed/collecting/ready/paid). Nothing here is
    // per-viewer — the fold is the room's shared truth — so no proposedByMe /
    // approvedByMe is claimed; the card draws the count, not a personal stake.
    function intentToCard(it) {
        var st = String((it && it.state) || "proposed");
        var cardState = (st === "executable" || st === "submitted") ? "ready"
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
        return {
            kind: "intent-propose",
            label: isGovernance ? qsTr("Add policy")
                 : isInvoke ? qsTr("Action")
                 : isStatement ? qsTr("Statement") : qsTr("Payment"),
            // an invoke intent's target, rendered by the card as "call module.method(…)".
            action: isInvoke ? (String(eff.module || "") + "." + String(eff.method || "")) : "",
            actionArgs: invokeArgs,
            // a statement the room ratifies, or a governance decision — the card shows
            // the text instead of amount → destination.
            statement: isGovernance
                     ? qsTr("Grant the room the “%1” policy").arg(String(eff.kind || ""))
                     : isStatement ? String(eff.text || "") : "",
            amount: (!isStatement && eff.value !== undefined) ? String(eff.value) : "",
            denom: "",
            to: (!isStatement && eff.to !== undefined) ? String(eff.to) : "",
            rail: (it && it.rail) ? String(it.rail) : "safe",
            threshold: Number((it && it.threshold) || 0),
            n: Number((it && it.n) || 0),
            approvals: Number((it && it.approvals) || 0),
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
            policy: (it && it.policy) ? String(it.policy) : ""
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
    function proposeFrom(toAddr, valueStr) {
        if (!room.backend || String(toAddr).length === 0)
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
    function proposeAction(action, argsText) {
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
        room.backend.proposeInRoom(JSON.stringify({
            effect: "invoke",
            module: String(action.module || ""),
            method: String(action.method || ""),
            args: args
        }));
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
                text: room.joined ? qsTr("Room · %1").arg(room.topic) : qsTr("Join a room")
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
                                    room.backend.contributeInRoom(String(msg.liveIntent.id || ""), "");
                            }
                        }

                        // Advanced: paste a signature produced elsewhere (a Safe owner on
                        // another device, or a member signing off-app). Hidden behind a
                        // toggle — one-click in-app Approve above is the primary path.
                        LogosButton {
                            objectName: "roomApprovePasteToggle"
                            visible: msg.isIntentRef && msg.liveIntent !== null && !msg.approving
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
                                            room.backend.contributeInRoom(String(msg.liveIntent.id || ""), sigField.text);
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
                                            room.backend.contributeInRoom(String(msg.liveIntent.id || ""), sigField.text);
                                        sigField.text = "";
                                        msg.approving = false;
                                    }
                                }
                            }
                        }

                        // ready (executable) — settle it on-chain FROM the room. For a
                        // Safe intent, a Submit button assembles the execTransaction
                        // from the folded owner signatures (coordinate_submit); for a
                        // threshold endorsement there is nothing on-chain to settle, so
                        // it says so. The outcome is reported honestly from the module —
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
                            // an invoke intent settles by RUNNING the action (coordinate_execute),
                            // not by an on-chain Safe settle — the policy tells them apart.
                            readonly property bool isInvoke:
                                String((msg.liveIntent && msg.liveIntent.policy) || "") === "invoke"
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
                                    text: readyBox.isInvoke
                                          ? (readyBox.st === "final"
                                             ? qsTr("✓ Ran — the action executed.")
                                             : readyBox.st === "submitted"
                                             ? qsTr("Running the action…")
                                             : qsTr("✓ Ready — endorsed. Run the action."))
                                          : readyBox.rail !== "safe"
                                          ? qsTr("✓ Endorsed — a signed group decision. Nothing settles on-chain.")
                                          : readyBox.st === "final"
                                          ? qsTr("✓ Paid — settled on-chain.")
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
                                    visible: !readyBox.isInvoke && readyBox.rail === "safe" && readyBox.st === "executable"
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
                                            return qsTr("⚠ Not enough owner signatures — have %1 of %2. "
                                                     + "The approvers must be real Safe owners.")
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
                                          : oc === "failed" ? qsTr("⚠ On-chain execution reverted — the Safe rejected it")
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
                            onShareAddress: {
                                if (room.backend)
                                    room.backend.postMessage(JSON.stringify({
                                        kind: "address-share", asset: "ETH",
                                        address: room.myAddress.length > 0 ? room.myAddress
                                                 : "0x0000000000000000000000000000000000000000",
                                        form: 1
                                    }));
                            }
                        }

                        // ── plain chat text ────────────────────────────────────────
                        ColumnLayout {
                            visible: msg.parsedCard === null
                            Layout.fillWidth: true
                            spacing: 2

                            LogosText {
                                text: String(modelData.author || "?").substring(0, 10)
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
        ColumnLayout {
            visible: room.joined
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            // proposal compose, revealed by "+".
            ColumnLayout {
                visible: room.composing
                Layout.fillWidth: true
                spacing: Theme.spacing.tiny

                LogosText {
                    text: room.composeType === "statement" ? qsTr("Propose a statement")
                        : room.composeType === "action" ? qsTr("Propose an action")
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

                    Item { Layout.fillWidth: true }
                }

                // ── policy picker: THIS proposal's driver (invariant 6) ───────
                // Policy binds to the intent, not the room — so this picks the driver
                // for the NEXT thing you propose; a card already collecting keeps its
                // own. The same propose/contribute/fold runs under either. Safe =
                // EIP-712 / secp owners; Threshold = k-of-n Ed25519 endorsement.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        text: qsTr("Next proposal")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    LogosButton {
                        objectName: "roomPolicySafe"
                        Layout.preferredWidth: 90
                        text: qsTr("Safe")
                        variant: room.policyKind === "safe"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: if (room.backend) room.backend.setPolicy("safe")
                    }

                    LogosButton {
                        objectName: "roomPolicyThreshold"
                        Layout.preferredWidth: 130
                        text: qsTr("Threshold")
                        variant: room.policyKind === "threshold"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: if (room.backend) room.backend.setPolicy("threshold")
                    }

                    // FROST — a 2-round Schnorr-threshold policy (the only driver with
                    // rounds > 1). In the founding set, so it's directly selectable; the
                    // card shows "round R of 2" as it collects.
                    LogosButton {
                        objectName: "roomPolicyFrost"
                        Layout.preferredWidth: 90
                        text: qsTr("FROST")
                        variant: room.policyKind === "frost"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: if (room.backend) room.backend.setPolicy("frost")
                    }

                    // Driver-as-proposal (invariant 6): "unanimous" (n-of-n) is NOT in
                    // the founding set. If the room has admitted it (an approved
                    // add-driver proposal), it's a selectable policy; otherwise this
                    // PROPOSES adding it — a governance intent the group must approve.
                    LogosButton {
                        objectName: "roomPolicyUnanimous"
                        Layout.preferredWidth: 150
                        text: room.hasDriver("unanimous") ? qsTr("Unanimous")
                                                          : qsTr("＋ Propose unanimous")
                        variant: room.policyKind === "unanimous"
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: {
                            if (!room.backend) return;
                            if (room.hasDriver("unanimous"))
                                room.backend.setPolicy("unanimous");
                            else   // propose admitting it — the room approves, then it appears
                                room.backend.proposeInRoom(JSON.stringify({ effect: "add-driver", kind: "unanimous" }));
                        }
                    }

                    Item { Layout.fillWidth: true }

                    LogosText {
                        text: room.policy && room.policy.threshold !== undefined
                              ? qsTr("%1 needed").arg(room.policy.threshold) : ""
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
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
                            visible: {
                                if (!room.roomAsset || room.roomAsset.error) return false;
                                var amt = parseFloat(proposeValue.text || "0");
                                var avail = parseFloat(room.roomAsset.raw || "0");
                                return amt > 0 && amt > avail;
                            }
                            text: qsTr("⚠ more than the Safe holds — this would revert on-chain")
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
                }

                // payment: recipient (+ amount below).
                LogosTextField {
                    id: proposeTo
                    objectName: "roomProposeTo"
                    visible: room.composeType === "payment"
                    Layout.fillWidth: true
                    placeholderText: qsTr("recipient (0x…)")
                    font.family: Theme.typography.mono
                }

                // statement: the text the room ratifies.
                LogosTextField {
                    id: proposeText
                    objectName: "roomProposeText"
                    visible: room.composeType === "statement"
                    Layout.fillWidth: true
                    placeholderText: qsTr("what the room ratifies…")
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosTextField {
                        id: proposeValue
                        objectName: "roomProposeValue"
                        visible: room.composeType === "payment"
                        Layout.fillWidth: true
                        // wei — the Safe transfers this exact value; the balance above is
                        // shown in ETH and in wei so the unit you type against is explicit.
                        placeholderText: qsTr("amount (wei)")
                        font.family: Theme.typography.mono
                        validator: IntValidator { bottom: 0 }
                    }

                    // keep the buttons right-aligned when the amount field is hidden.
                    Item { visible: room.composeType !== "payment"; Layout.fillWidth: true }

                    LogosButton {
                        objectName: "roomProposeSubmit"
                        text: qsTr("Propose")
                        enabled: room.composeType === "statement" ? proposeText.text.length > 0
                               : room.composeType === "action" ? room.chosenAction !== null
                               : proposeTo.text.length > 0
                        onClicked: {
                            if (room.composeType === "statement") {
                                room.proposeStatement(proposeText.text);
                                proposeText.text = "";
                            } else if (room.composeType === "action") {
                                room.proposeAction(room.chosenAction, proposeArgs.text);
                                proposeArgs.text = "";
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

            // What the room depends on, and whether it's actually there (invariant 8).
            ConnectionIndicators {
                Layout.fillWidth: true
                status: room.connectivity
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

            ScopePanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 1
                members: room.members
                pending: room.pending
                topic: room.topic
                onRequestJoin: if (room.backend) room.backend.requestJoin()
                onAdmit: function(identityHex) { if (room.backend) room.backend.admit(identityHex); }
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

    // Connectivity on a slower cadence than the message tick: the RPC probe makes a
    // blocking eth_chainId call (short timeout), so probing it every second would
    // stutter the room. Every 5s is plenty to keep the indicators honest.
    Timer {
        interval: 5000
        running: room.joined
        repeat: true
        onTriggered: if (room.backend) room.backend.loadConnectivity();
    }
}
