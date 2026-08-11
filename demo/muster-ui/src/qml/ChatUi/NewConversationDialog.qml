import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Modal dialog that collects a peer address for a new 1:1 conversation and emits
// it. Open it and connect addressEntered(); its input persists across a close so
// a dismissed dialog reopens with the same draft, and clears only once a
// conversation is created. Standalone: instantiate with no context, open(), and
// read the signal.
LogosDialog {
    id: root

    // Emitted with the trimmed address when the user confirms a non-empty entry.
    signal addressEntered(string address)

    title: qsTr("New DM")
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
            implicitWidth: 96
            implicitHeight: 36
            //: Button that confirms creating the new conversation
            text: qsTr("Create")
            enabled: addressField.text.trim() !== ""
            onClicked: d.accept()
        }
    ]

    onOpened: addressField.forceActiveFocus()

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium

        LogosText {
            text: qsTr("Paste the other user's address:")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        LogosScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 100

            LogosTextArea {
                id: addressField
                objectName: "convAddressField"
                placeholderText: qsTr("peer address (hex)...")
                font.family: Theme.typography.mono
                // Return submits rather than inserting a newline: the address is
                // one logical value, not multi-line prose.
                Keys.onReturnPressed: function (event) {
                    d.accept();
                    event.accepted = true;
                }
                Keys.onEnterPressed: function (event) {
                    d.accept();
                    event.accepted = true;
                }
            }
        }
    }

    QtObject {
        id: d

        // Emit the trimmed address, clear the field, and close. No-op on empty
        // input, so neither Return nor Create can submit a blank address.
        function accept() {
            const address = addressField.text.trim();
            if (address === "")
                return;
            root.addressEntered(address);
            addressField.clear();
            root.close();
        }
    }
}
