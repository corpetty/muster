import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room / conversation surface — the first real product surface of the
// spec-first client. One encrypted channel with two folds off the SAME sealed
// log (state = reduce(log)):
//   • messages — chat text, and address-share / receipt cards (peer data the core
//     never interprets), from coordinate_messages.
//   • proposals — the room's intents, folded and verified by the driver, from
//     coordinate_intents. A proposal card is NOT posted JSON; it is the render of
//     real folded state (effect + threshold + distinct-owner approvals). Proposing
//     goes through coordinate_propose (content-addressed id); approving is an owner
//     signature over the safeTxHash the module re-derives — the client holds no
//     keys, so you paste the signature your own device produced (coordinate_contribute).
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
        return {
            kind: "intent-propose",
            label: qsTr("Payment"),
            amount: eff.value !== undefined ? String(eff.value) : "",
            denom: "",
            to: eff.to !== undefined ? String(eff.to) : "",
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

    // Put a real proposal to the room through the verified path: a sample transfer
    // effect, canonicalized by the module to the EIP-712 safeTxHash and folded as a
    // content-addressed intent. Composing the effect from fields is the next step;
    // the loop it drives (propose → contribute → executable) is already real.
    function proposeSample() {
        if (!room.backend)
            return;
        room.backend.proposeInRoom(JSON.stringify({
            to: "0x1111111111111111111111111111111111111111", value: 100, nonce: 0
        }));
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

        // ── proposals: the room's intents, folded and verified ────────────
        // Each card is the render of real folded state, not posted JSON. Approving
        // reveals a signature field — the owner signs the module's re-derived
        // safeTxHash on their own device; the module verifies it recovers to a
        // configured owner before it counts (coordinate_contribute).
        ColumnLayout {
            visible: room.joined && room.intents.length > 0
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("PROPOSALS")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }

                LogosButton {
                    objectName: "refreshIntentsButton"
                    text: qsTr("Refresh")
                    onClicked: if (room.backend) room.backend.loadIntents()
                }
            }

            Repeater {
                model: room.intents

                delegate: ColumnLayout {
                    id: proposal
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny

                    // Reveal the signature field when this proposal's Approve is
                    // pressed; hidden again once a signature is submitted.
                    property bool approving: false

                    readonly property string intentId: String(proposal.modelData.id || "")

                    MusterCard {
                        Layout.fillWidth: true
                        card: room.intentToCard(proposal.modelData)
                        onApprove: proposal.approving = true
                    }

                    // ── honest approve: paste the owner signature ──────────
                    ColumnLayout {
                        visible: proposal.approving
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
                                    if (room.backend && proposal.intentId.length > 0)
                                        room.backend.contributeInRoom(proposal.intentId, sigField.text);
                                    sigField.text = "";
                                    proposal.approving = false;
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── the thread ────────────────────────────────────────────────────
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
                    width: thread.width
                    implicitHeight: parsedCard ? cardHost.implicitHeight : plainHost.implicitHeight

                    // A message body that parses to an object with a `kind` is a
                    // typed card (address-share / receipt); anything else is plain
                    // text. Intents are NOT here — they come from the proposals fold.
                    readonly property var parsedCard: {
                        try {
                            var o = JSON.parse(modelData.body);
                            return (o && (o.kind || o.type)) ? o : null;
                        } catch (e) { return null; }
                    }

                    MusterCard {
                        id: cardHost
                        width: parent.width
                        visible: parent.parsedCard !== null
                        card: parent.parsedCard || ({})
                        onShareAddress: { if (room.backend) room.backend.postMessage(JSON.stringify({ kind: "address-share", asset: "TKN", address: "0x2222222222222222222222222222222222222222", form: 1 })); }
                        onPay: { if (room.backend) room.backend.postMessage(JSON.stringify({ kind: "send-receipt", amount: "100", denom: "TKN", rail: "safe", tx: "0xdeadbeef", discloses: { amount: "100", payer: "not disclosed", payee: "0x1111" } })); }
                    }

                    ColumnLayout {
                        id: plainHost
                        width: parent.width
                        visible: parent.parsedCard === null
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

        // ── composer ──────────────────────────────────────────────────────
        RowLayout {
            visible: room.joined
            Layout.fillWidth: true
            spacing: Theme.spacing.small

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

            LogosButton {
                objectName: "roomProposeButton"
                text: qsTr("Propose")
                onClicked: room.proposeSample()
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
