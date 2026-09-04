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
        return {
            kind: "intent-propose",
            label: isGovernance ? qsTr("Add policy")
                 : isStatement ? qsTr("Statement") : qsTr("Payment"),
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
    // card. Nonce is 0 for now — the room coordinates but does not yet settle
    // on-chain, so proposals don't contend for a Safe nonce (room-side submit is a
    // later step). A blank/zero amount is allowed; the recipient is required.
    function proposeFrom(toAddr, valueStr) {
        if (!room.backend || String(toAddr).length === 0)
            return;
        var v = parseInt(valueStr, 10);
        if (isNaN(v) || v < 0) v = 0;
        room.backend.proposeInRoom(JSON.stringify({
            to: String(toAddr), value: v, nonce: 0
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
                            onApprove: msg.approving = true
                        }

                        // its approve affordance — the owner signs on their own device.
                        ColumnLayout {
                            visible: msg.isIntentRef && msg.liveIntent !== null && msg.approving
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("Sign the re-derived safeTxHash on your own device and paste "
                                         + "the 65-byte signature. It counts only if it recovers to a configured owner.")
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
                                    placeholderText: qsTr("owner signature (65-byte hex)")
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
                            visible: msg.isIntentRef && msg.liveIntent !== null
                                     && (String((msg.liveIntent && msg.liveIntent.state) || "") === "executable")
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            readonly property string rail: String((msg.liveIntent && msg.liveIntent.rail) || "safe")
                            // the submit outcome, only when it names THIS intent
                            readonly property var outcome: (room.roomSubmit
                                && String(room.roomSubmit.id || "") === String((msg.liveIntent && msg.liveIntent.id) || ""))
                                ? room.roomSubmit : null

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosText {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: readyBox.rail === "safe"
                                          ? qsTr("✓ Ready — the approvals are collected.")
                                          : qsTr("✓ Endorsed — a signed group decision. Nothing settles on-chain.")
                                    color: Theme.palette.success
                                    font.pixelSize: Theme.typography.secondaryText
                                    font.weight: Theme.typography.weightMedium
                                }
                                LogosButton {
                                    objectName: "roomSubmitButton"
                                    visible: readyBox.rail === "safe"
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
                                    if (o.error !== undefined)
                                        return qsTr("⚠ ") + String(o.error)
                                             + (o.detail ? " — " + String(o.detail) : "");
                                    var oc = String(o.onchain || "");
                                    var tx = o.txHash ? "  ·  " + String(o.txHash) : "";
                                    return (oc === "final" ? qsTr("✓ Settled on-chain (final)")
                                          : oc === "failed" ? qsTr("⚠ On-chain execution reverted")
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
                            onPay: { if (room.backend) room.backend.postMessage(JSON.stringify({ kind: "send-receipt", amount: "100", denom: "TKN", rail: "safe", tx: "0xdeadbeef", discloses: { amount: "100", payer: "not disclosed", payee: "0x1111" } })); }
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
                    text: room.composeType === "statement"
                          ? qsTr("Propose a statement") : qsTr("Propose a payment")
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
                        placeholderText: qsTr("amount")
                        font.family: Theme.typography.mono
                        validator: IntValidator { bottom: 0 }
                    }

                    // keep the buttons right-aligned when the amount field is hidden.
                    Item { visible: room.composeType === "statement"; Layout.fillWidth: true }

                    LogosButton {
                        objectName: "roomProposeSubmit"
                        text: qsTr("Propose")
                        enabled: room.composeType === "statement"
                                 ? proposeText.text.length > 0 : proposeTo.text.length > 0
                        onClicked: {
                            if (room.composeType === "statement") {
                                room.proposeStatement(proposeText.text);
                                proposeText.text = "";
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

        // Right: who can see this — the roster, the pending join-requests, and the
        // scope line. The handshake signals go to the module through the backend.
        ScopePanel {
            visible: room.joined
            Layout.preferredWidth: 300
            Layout.fillHeight: true
            members: room.members
            pending: room.pending
            topic: room.topic
            onRequestJoin: if (room.backend) room.backend.requestJoin()
            onAdmit: function(identityHex) { if (room.backend) room.backend.admit(identityHex); }
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
}
