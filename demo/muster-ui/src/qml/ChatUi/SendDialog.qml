import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Confirm a payment to an address that arrived in the conversation.
//
// The recipient is not typed here — it came from a card the peer sent, which
// is the point: there is no address bar to paste the wrong thing into. Two
// questions, then: how much, and on which rail.
//
// The rail used to be implicit, and the dialog carried a fixed sentence about
// private-to-private that was true because there was nothing else it could be.
// Now that there is, the sentence comes from the rail — see RailPicker — so it
// stays true of the payment that is actually about to happen.
LogosDialog {
    id: root

    // The address to pay, its form (Assets::AddressForm — 0 shielded keys,
    // 1 public account id), and the peer's label for it.
    property string toAddress: ""
    property int addressForm: 0
    property string peerLabel: ""
    // The peer's own name for what they shared, and whether this build knows
    // the asset. Shown when it does not, so an unrecognised address reads as
    // theirs rather than as something we have identified.
    property string assetName: ""
    property bool assetKnown: true
    // Every rail this build can pay `addressForm` with, most private first.
    property var rails: []

    signal confirmed(string railId, string amount)

    title: qsTr("Send")
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
            enabled: d.amount() > 0 && picker.selected !== ""
            onClicked: d.accept()
        }
    ]

    onOpened: {
        amountField.text = "";
        // Opens on the most private rail that can pay this address. A default
        // that leaked more than it had to would be a choice made on the user's
        // behalf in the wrong direction.
        picker.selected = root.rails.length > 0 ? String(root.rails[0].id) : "";
        amountField.forceActiveFocus();
    }

    QtObject {
        id: d
        function amount() {
            const v = parseInt(amountField.text.trim(), 10);
            return isNaN(v) ? 0 : v;
        }
        function accept() {
            if (d.amount() <= 0 || picker.selected === "")
                return;
            root.confirmed(picker.selected, String(d.amount()));
            root.close();
        }
    }

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.peerLabel !== ""
                ? qsTr("To %1's %2.").arg(root.peerLabel).arg(root.assetName)
                : qsTr("To the %1 they shared.").arg(root.assetName)
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
        }

        // An address for an asset this build has never heard of. It can still
        // be paid — the form is what a rail needs, not the asset — but the name
        // beside it is theirs and not ours, and saying so is cheaper than
        // implying we recognised it.
        LogosText {
            Layout.fillWidth: true
            visible: !root.assetKnown
            wrapMode: Text.WordWrap
            text: qsTr("This build does not know that asset — \"%1\" is their name for it.")
                .arg(root.assetName)
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
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

        RailPicker {
            id: picker
            objectName: "sendRailPicker"
            Layout.fillWidth: true
            rails: root.rails
        }
    }
}
