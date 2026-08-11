import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A structured card inside a message bubble: the ask for an address, the
// shielded address that answers it, and the receipt for the payment that
// followed. Three steps of a transaction, rendered where they were agreed.
//
// `card` is the parsed JSON a peer sent (see src/MusterMessage.h). An unknown
// type never reaches here — MessageDelegate falls back to a plain bubble — so
// this component only has to render what it knows.
ColumnLayout {
    id: root

    required property var card
    // Whether this account sent the message. Actions belong to the receiver:
    // you answer someone else's request, and you pay someone else's address.
    required property bool isMe
    property bool walletReady: false

    signal shareAddressRequested
    signal payRequested(string keysJson, string label)

    spacing: Theme.spacing.small

    readonly property string cardType: root.card ? String(root.card.type) : ""

    // A one-line heading naming the step, in mono — the same "this is data, not
    // chatter" voice the timestamps and addresses use.
    LogosText {
        Layout.fillWidth: true
        text: root.cardType === "address-request" ? qsTr("Asked for an address")
            : root.cardType === "address-share" ? qsTr("Shared a private address")
            : qsTr("Payment sent")
        color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.7)
                         : Theme.palette.textTertiary
        font.family: Theme.typography.mono
        font.pixelSize: Theme.typography.secondaryText
        font.weight: Theme.typography.weightMedium
    }

    // ── address-request ──────────────────────────────────────────────────
    LogosText {
        visible: root.cardType === "address-request"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.isMe ? qsTr("Waiting for them to share an address.")
                        : qsTr("They want somewhere to send funds.")
        color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
        font.pixelSize: Theme.typography.primaryText
    }

    // ── address-share ────────────────────────────────────────────────────
    ColumnLayout {
        visible: root.cardType === "address-share"
        Layout.fillWidth: true
        spacing: Theme.spacing.tiny

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.card && root.card.label ? String(root.card.label) : qsTr("A private account")
            color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
            font.pixelSize: Theme.typography.primaryText
        }

        // The keys themselves are long and no one reads them; what matters is
        // that this is a shielded destination, so say that instead of pasting
        // sixty characters nobody checks.
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 2
            elide: Text.ElideRight
            text: qsTr("shielded · %1").arg(root.card && root.card.keys
                ? String(root.card.keys).replace(/\s+/g, "").slice(0, 48) + "…" : "")
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.6)
                             : Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
        }
    }

    // ── send-receipt ─────────────────────────────────────────────────────
    // The one moment something leaves the room. The prototype changes visual
    // ground exactly here and nowhere else, because this is the only step
    // where the boundary is actually crossed — so the card carries the outside
    // ground inside it, and names what the chain got.
    ColumnLayout {
        visible: root.cardType === "send-receipt"
        Layout.fillWidth: true
        spacing: Theme.spacing.tiny

        LogosText {
            Layout.fillWidth: true
            text: qsTr("%1 %2").arg(root.card ? String(root.card.amount) : "")
                               .arg(root.card ? String(root.card.denom) : "")
            color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
            font.pixelSize: Theme.typography.primaryText
            font.weight: Theme.typography.weightMedium
        }

        // What crossed. Same fields the visibility panel uses at every step, so
        // a reader who has seen them there can compare — and here almost all of
        // them read "not disclosed", which is the point of having paid seven
        // minutes for it.
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 2
            Layout.preferredHeight: crossing.implicitHeight + 2 * Theme.spacing.small
            radius: Theme.spacing.radiusSmall
            color: ChatTheme.outside

            ColumnLayout {
                id: crossing
                anchors.fill: parent
                anchors.margins: Theme.spacing.small
                spacing: 2

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("WHAT LEFT THE ROOM")
                    color: ChatTheme.outsideAccent
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }

                Repeater {
                    model: root.card && root.card.shielded
                        ? [{ k: qsTr("amount"), v: qsTr("not disclosed"), w: true },
                           { k: qsTr("who paid"), v: qsTr("not disclosed"), w: true },
                           { k: qsTr("who was paid"), v: qsTr("not disclosed"), w: true },
                           { k: qsTr("that it happened"), v: qsTr("on the record"), w: false },
                           { k: qsTr("when"), v: qsTr("block timestamp"), w: false }]
                        : [{ k: qsTr("amount"), v: root.card ? String(root.card.amount) : "", w: false },
                           { k: qsTr("who paid"), v: qsTr("on the record"), w: false },
                           { k: qsTr("who was paid"), v: qsTr("on the record"), w: false },
                           { k: qsTr("when"), v: qsTr("block timestamp"), w: false }]

                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosText {
                            text: modelData.k
                            color: "#96A19B"
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }

                        Item { Layout.fillWidth: true }

                        // Withheld is the good outcome, so it takes the accent.
                        LogosText {
                            text: modelData.v
                            color: modelData.w ? ChatTheme.outsideAccent : ChatTheme.outsideInk
                            horizontalAlignment: Text.AlignRight
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                            font.weight: Theme.typography.weightMedium
                        }
                    }
                }
            }
        }

        // The tx id, last and quietest: it is the thing you would take to an
        // explorer, and the least interesting fact on the card.
        LogosText {
            Layout.fillWidth: true
            visible: root.card && root.card.tx
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 1
            elide: Text.ElideRight
            text: root.card && root.card.tx ? String(root.card.tx) : ""
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.5)
                             : Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
        }
    }

    // ── actions ──────────────────────────────────────────────────────────
    // Only ever on a message from the other side: this is the point where the
    // conversation turns into a transaction, and it should take one tap.
    LogosButton {
        objectName: "cardShareAddress"
        visible: root.cardType === "address-request" && !root.isMe
        Layout.fillWidth: true
        text: root.walletReady ? qsTr("Share my address") : qsTr("Open wallet first")
        enabled: root.walletReady
        onClicked: root.shareAddressRequested()
    }

    LogosButton {
        objectName: "cardPay"
        visible: root.cardType === "address-share" && !root.isMe
        Layout.fillWidth: true
        text: root.walletReady ? qsTr("Send LEZ") : qsTr("Open wallet first")
        enabled: root.walletReady
        onClicked: root.payRequested(root.card && root.card.keys ? String(root.card.keys) : "",
                                     root.card && root.card.label ? String(root.card.label) : "")
    }
}
