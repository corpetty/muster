import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Put a payment to the room instead of just making it.
//
// Two questions, in the order they matter: how much, and how many people have
// to agree before it can be paid. The recipient is not one of them — it came
// from a card in the thread, same as a direct send, so there is still no
// address bar to paste the wrong thing into.
//
// The threshold picker is the whole reason this dialog exists rather than a
// checkbox on the send dialog. Choosing "2 of 3" is the moment a payment stops
// being a thing one person does and becomes a thing a room does, and it should
// cost a deliberate tap.
LogosDialog {
    id: root

    // The shielded key set to pay, and the peer's label for it.
    property string keysJson: ""
    property string peerLabel: ""
    property string availableBalance: ""
    // Committed members of the room; the honest denominator for a threshold.
    property int memberCount: 1

    signal confirmed(string amount, int threshold)

    title: qsTr("Propose a payment")
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    anchors.centerIn: Overlay.overlay
    width: Math.min(480, (Overlay.overlay ? Overlay.overlay.width : 480) - 2 * Theme.spacing.large)

    leftActions: [
        LogosButton {
            implicitWidth: 96
            implicitHeight: 36
            text: qsTr("Cancel")
            onClicked: root.close()
        }
    ]
    rightActions: [
        LogosButton {
            objectName: "proposeConfirm"
            implicitWidth: 128
            implicitHeight: 36
            text: qsTr("Put it to the room")
            enabled: d.amount() > 0
            onClicked: d.accept()
        }
    ]

    onOpened: {
        amountField.text = "";
        // Everyone, by default: the safest reading of "we agreed" is the one
        // that needs the whole room, and lowering it is the deliberate act.
        d.threshold = Math.max(1, root.memberCount);
        amountField.forceActiveFocus();
    }

    QtObject {
        id: d
        property int threshold: 1

        function amount() {
            const v = parseInt(amountField.text.trim(), 10);
            return isNaN(v) ? 0 : v;
        }
        function accept() {
            if (d.amount() <= 0)
                return;
            root.confirmed(String(d.amount()), d.threshold);
            root.close();
        }
    }

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.peerLabel !== ""
                ? qsTr("To %1's private account.").arg(root.peerLabel)
                : qsTr("To the private account they shared.")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
        }

        LogosText {
            Layout.fillWidth: true
            visible: root.availableBalance !== ""
            text: qsTr("You have %1 private").arg(root.availableBalance)
            color: Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
        }

        LogosTextField {
            id: amountField
            objectName: "proposeAmount"
            Layout.fillWidth: true
            placeholderText: qsTr("amount")
            font.family: Theme.typography.mono
            validator: IntValidator { bottom: 1 }
            Keys.onReturnPressed: function (event) {
                d.accept();
                event.accepted = true;
            }
            Keys.onEnterPressed: function (event) {
                d.accept();
                event.accepted = true;
            }
        }

        LogosText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.tiny
            text: qsTr("HOW MANY MUST AGREE")
            color: Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
            font.weight: Theme.typography.weightMedium
        }

        // One button per possible threshold. A room small enough to coordinate
        // in is small enough to draw, and seeing "1 2 3" beside each other says
        // what a spinner would not: that you are choosing how much agreement
        // this needs, and that 1 is a real choice with a real meaning.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            Repeater {
                model: Math.max(1, root.memberCount)

                delegate: LogosButton {
                    id: pick
                    required property int index
                    readonly property int value: pick.index + 1

                    objectName: "proposeThreshold" + pick.value
                    implicitWidth: 44
                    implicitHeight: 36
                    variant: d.threshold === pick.value
                        ? LogosButton.Variant.Primary
                        : LogosButton.Variant.Secondary
                    text: String(pick.value)
                    onClicked: d.threshold = pick.value
                }
            }

            Item { Layout.fillWidth: true }
        }

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: d.threshold <= 1
                ? qsTr("You alone. Proposing counts as approving, so this is ready as soon "
                     + "as it is made.")
                : qsTr("%1 of %2, counting you — proposing counts as approving.")
                    .arg(d.threshold).arg(Math.max(1, root.memberCount))
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
        }

        // The limit of what a threshold means here. Said at the moment it is
        // chosen, because that is when someone is most likely to assume it
        // means more than it does.
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("Approvals are authenticated — the chat module binds each one to its "
                     + "author, so nobody in the room can forge or replay another's. But the "
                     + "zone does not check them: you pay from your own account, and the "
                     + "chain sees an ordinary shielded transfer.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
        }
    }
}
