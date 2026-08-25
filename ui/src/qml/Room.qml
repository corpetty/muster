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
    readonly property var intents: {
        try { return JSON.parse(backend ? backend.intentsJson : "[]"); }
        catch (e) { return []; }
    }

    // The room's coordination policy (its driver), from coordinate_policy. The whole
    // propose/contribute/fold path runs under whichever the room picks.
    readonly property var policy: {
        try { return JSON.parse(backend ? backend.policyJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property string policyKind:
        (room.policy && room.policy.policy) ? String(room.policy.policy) : "safe"

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
        var isStatement = eff && String(eff.effect || "") === "statement";
        return {
            kind: "intent-propose",
            label: isStatement ? qsTr("Statement") : qsTr("Payment"),
            // a statement the room ratifies (a second effect type) — the card shows
            // the text instead of amount → destination.
            statement: isStatement ? String(eff.text || "") : "",
            amount: (!isStatement && eff.value !== undefined) ? String(eff.value) : "",
            denom: "",
            to: (!isStatement && eff.to !== undefined) ? String(eff.to) : "",
            rail: (it && it.rail) ? String(it.rail) : "safe",
            threshold: Number((it && it.threshold) || 0),
            approvals: Number((it && it.approvals) || 0),
            state: cardState,
            // the verify view: the re-derived safeTxHash and the domain it binds to
            txhash: (it && it.txhash) ? String(it.txhash) : "",
            chainId: (it && it.chainId !== undefined) ? Number(it.chainId) : 0,
            safe: (it && it.safe) ? String(it.safe) : "",
            environment: (it && it.environment) ? String(it.environment) : "",
            // the provenance lineage: how this decision's data got here (inv 10)
            provenance: (it && it.provenance) ? it.provenance : []
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
                    width: thread.width
                    implicitHeight: rowCol.implicitHeight

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

                    // reveal the signature field for THIS inline proposal.
                    property bool approving: false

                    ColumnLayout {
                        id: rowCol
                        width: parent.width
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
                            onShareAddress: { if (room.backend) room.backend.postMessage(JSON.stringify({ kind: "address-share", asset: "TKN", address: "0x2222222222222222222222222222222222222222", form: 1 })); }
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

                // ── policy picker: the room's driver (invariant 6) ────────────
                // The same propose/contribute/fold runs under either — the policy is
                // a driver, not hardcoded. Safe = EIP-712 / secp owners; Threshold =
                // k-of-n Ed25519 endorsement.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        text: qsTr("Policy")
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

        // Right: who can see this — the roster and the scope line.
        ScopePanel {
            visible: room.joined
            Layout.preferredWidth: 300
            Layout.fillHeight: true
            members: room.members
            topic: room.topic
        }
    }
}
