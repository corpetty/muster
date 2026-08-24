import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room / conversation surface — the first real product surface of the
// spec-first client. One encrypted channel: join a topic, post messages (plain
// text or, later, typed cards), and see the thread + roster fold from the module
// (coordinate_join / coordinate_post_message / coordinate_messages /
// coordinate_members). Everything the room shows is reduce(log) from the module —
// this view holds no state of its own.
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

    // Post a demo proposal as an intent-propose card (cards are data), so the card
    // vocabulary renders in the thread. Wiring it to the verified
    // coordinate_propose/contribute path (with a signature input) is a follow-up.
    function proposeDemo() {
        if (!room.backend)
            return;
        room.backend.postMessage(JSON.stringify({
            kind: "intent-propose", intentId: "demo", label: "Pay the room",
            amount: "100", denom: "TKN", to: "0x1111111111111111111111111111111111111111",
            rail: "safe", threshold: 2, approvals: 1, approvers: [{ initials: "ME" }],
            state: "collecting", proposedByMe: true, approvedByMe: true
        }));
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.large
        spacing: Theme.spacing.medium

        // Left: the conversation (header, join, thread, composer).
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
                    // typed card; anything else renders as plain text.
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
                        onApprove: { if (room.backend) room.backend.postMessage(JSON.stringify({ kind: "intent-approve" })); }
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
                onClicked: room.proposeDemo()
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
