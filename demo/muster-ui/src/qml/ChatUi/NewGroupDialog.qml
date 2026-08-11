import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Modal dialog that collects a name and an optional description for a new group
// and emits them. Open it and connect groupDetailsEntered(); its inputs persist
// across a close so a dismissed dialog reopens with the same draft, and clear
// only once a group is created. Standalone: instantiate with no context, open(),
// and read the signal.
LogosDialog {
    id: root

    // Emitted with the trimmed name and description once the user confirms a
    // non-empty name.
    signal groupDetailsEntered(string name, string description)

    // Character caps for the shared group metadata. The name is a short label;
    // the description a sentence or two. Enforced by the counters and the accept
    // guard, not the field itself (LogosTextField exposes no maximumLength).
    readonly property int nameLimit: 64
    readonly property int descriptionLimit: 280

    title: qsTr("New Group")
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
            id: createButton
            implicitWidth: 96
            implicitHeight: 36
            //: Button that confirms creating the new group
            text: qsTr("Create")
            enabled: nameField.text.trim() !== "" && nameField.text.length <= root.nameLimit && descriptionField.text.length <= root.descriptionLimit
            onClicked: d.accept()
        }
    ]

    onOpened: nameField.forceActiveFocus()

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium

        RowLayout {
            Layout.fillWidth: true

            LogosText {
                text: qsTr("Group name")
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                Layout.fillWidth: true
            }
            LogosText {
                text: nameField.text.length + "/" + root.nameLimit
                visible: nameField.text.length > root.nameLimit * 0.75
                color: nameField.text.length > root.nameLimit ? ChatTheme.alarm : Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
            }
        }

        LogosTextField {
            id: nameField
            objectName: "groupNameField"
            Layout.fillWidth: true
            placeholderText: qsTr("e.g. Book Club")

            // Enter confirms rather than moving focus: a valid group needs only
            // the name, and the description is optional.
            Connections {
                target: nameField.textInput
                function onAccepted() {
                    d.accept();
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true

            LogosText {
                text: qsTr("Description (optional)")
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                Layout.fillWidth: true
            }
            LogosText {
                text: descriptionField.text.length + "/" + root.descriptionLimit
                visible: descriptionField.text.length > root.descriptionLimit * 0.75
                color: descriptionField.text.length > root.descriptionLimit ? ChatTheme.alarm : Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
            }
        }

        LogosScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 80

            LogosTextArea {
                id: descriptionField
                objectName: "groupDescriptionField"
                placeholderText: qsTr("What's this group about?")
                // Tab leaves the multi-line field for the actions instead of
                // inserting a tab character.
                KeyNavigation.tab: createButton
                KeyNavigation.backtab: nameField
            }
        }

        LogosText {
            text: qsTr("The name and description can't be changed after the group is created.")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }

    QtObject {
        id: d

        // Emit the trimmed name and description, clear the inputs, and close.
        // No-op unless the name is non-empty and both fields are within their
        // limits, so neither Enter nor Create can create a group from invalid
        // input.
        function accept() {
            const name = nameField.text.trim();
            if (name === "" || nameField.text.length > root.nameLimit || descriptionField.text.length > root.descriptionLimit)
                return;
            root.groupDetailsEntered(name, descriptionField.text.trim());
            nameField.text = "";
            descriptionField.clear();
            root.close();
        }
    }
}
