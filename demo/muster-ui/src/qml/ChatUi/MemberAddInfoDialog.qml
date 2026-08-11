import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// First-time explainer for adding a group member: the commit is asynchronous, so
// a newly invited member can take up to a minute to appear. Open it, and connect
// confirmed() — it carries whether the user ticked "Don't show this again", so the
// caller can persist that and skip the dialog next time. Standalone: instantiate
// with no context, open(), and read the signal.
LogosDialog {
    id: root

    // Emitted when the user confirms the add; `dontShowAgain` is the checkbox state.
    signal confirmed(bool dontShowAgain)

    title: qsTr("Adding a member")
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
            implicitWidth: 130
            implicitHeight: 36
            //: Button that confirms inviting the member into the group
            text: qsTr("Add member")
            onClicked: {
                root.confirmed(dontShowAgain.checked);
                root.close();
            }
        }
    ]

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium

        LogosText {
            //: Explains that a new member shows up only after the group updates
            text: qsTr("Adding a member isn't instant. Membership updates apply on a timer, so a new member can take up to a minute to appear.")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        LogosCheckbox {
            id: dontShowAgain
            text: qsTr("Don't show this again")
        }
    }
}
