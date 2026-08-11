import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Confirm a payment to an address that arrived in the conversation.
//
// The recipient is not typed here — it came from a card the peer sent, which
// is the point: there is no address bar to paste the wrong thing into. All
// this asks for is the amount.
LogosDialog {
    id: root

    // The shielded key set to pay, and the peer's label for it.
    property string keysJson: ""
    property string peerLabel: ""
    property string availableBalance: ""

    signal confirmed(string amount)

    title: qsTr("Send LEZ")
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
            objectName: "sendConfirm"
            implicitWidth: 96
            implicitHeight: 36
            text: qsTr("Send")
            enabled: d.amount() > 0
            onClicked: d.accept()
        }
    ]

    onOpened: {
        amountField.text = "";
        amountField.forceActiveFocus();
    }

    QtObject {
        id: d
        function amount() {
            const v = parseInt(amountField.text.trim(), 10);
            return isNaN(v) ? 0 : v;
        }
        function accept() {
            if (d.amount() <= 0)
                return;
            root.confirmed(String(d.amount()));
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
            objectName: "sendAmount"
            Layout.fillWidth: true
            placeholderText: qsTr("amount")
            font.family: Theme.typography.mono
            // The zone takes whole units; anything else is refused downstream,
            // so it is refused here where it can still be corrected.
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

        // The one claim worth making at the moment of payment, and it is true.
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("Private → private: the amount and both accounts stay off the public "
                     + "record. The zone still learns that a transfer happened, and when.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
        }
    }
}
