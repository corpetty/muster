pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The conversations card: the one action that starts a conversation, over the
// keyboard-navigable list of the ones already open. Data in via properties,
// intent out via signals.
Rectangle {
    id: root

    required property var conversationModel
    required property string currentConversationId
    required property bool online

    // Carries the selected row's own data, so a view can render the selection
    // before the backend has switched to it.
    signal conversationSelected(var conversation)
    signal newConversationRequested
    signal newGroupRequested

    // Exposed for the exchange doc-test's inspector hooks.
    property alias count: convList.count

    implicitWidth: 320
    implicitHeight: 400
    radius: Theme.spacing.radiusXlarge
    color: Theme.palette.backgroundTertiary
    border.width: 1
    border.color: Theme.palette.borderSubtle

    QtObject {
        id: d

        // Select the keyboard-focused row, giving it the same effect as a click.
        function activateCurrent() {
            const row = convList.currentItem as ConversationDelegate;
            if (row)
                root.conversationSelected(row.conversation);
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.small

        LogosButton {
            id: newButton
            objectName: "newMenuButton"
            //: Button that opens the menu of conversations one can start
            text: qsTr("New chat")
            variant: LogosButton.Variant.Primary
            radius: Theme.spacing.radiusLarge
            font.pixelSize: Theme.typography.primaryText
            leadingIcon.source: Qt.resolvedUrl("icons/plus.png")
            leadingIcon.size: 18
            leadingIcon.color: Theme.palette.backgroundBlack
            trailingIcon.source: Qt.resolvedUrl("icons/caret-down.png")
            trailingIcon.size: 14
            trailingIcon.color: Theme.palette.backgroundBlack
            enabled: root.online
            onClicked: newMenu.popup(0, newButton.height + Theme.spacing.tiny)
            Layout.fillWidth: true
            Layout.preferredHeight: 40

            // The design system's label is white whatever the fill; on the
            // primary accent that is the pair with the least contrast.
            Binding {
                target: newButton.labelItem
                property: "color"
                value: newButton.enabled ? Theme.palette.backgroundBlack : Theme.palette.textMuted
            }

            LogosMenu {
                id: newMenu
                objectName: "newMenu"

                ChatMenuItem {
                    objectName: "newDmMenuItem"
                    //: Menu entry that starts a new direct message (1:1) conversation
                    text: qsTr("Direct message")
                    //: Says what a direct message is, under its menu entry
                    description: qsTr("One person, by address")
                    iconSource: Qt.resolvedUrl("icons/person.png")
                    onTriggered: root.newConversationRequested()
                }
                ChatMenuItem {
                    objectName: "newGroupMenuItem"
                    //: Menu entry that starts a new group conversation
                    text: qsTr("Group")
                    //: Says what a group is, under its menu entry
                    description: qsTr("Named, with members")
                    iconSource: Qt.resolvedUrl("icons/group.png")
                    onTriggered: root.newGroupRequested()
                }
            }
        }

        ListView {
            id: convList
            objectName: "conversationList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            focus: true
            reuseItems: true
            spacing: Theme.spacing.tiny
            model: root.conversationModel
            currentIndex: -1

            Keys.onReturnPressed: d.activateCurrent()
            Keys.onEnterPressed: d.activateCurrent()

            ScrollBar.vertical: LogosScrollBar {}

            delegate: ConversationDelegate {
                width: ListView.view.width
                currentConversationId: root.currentConversationId
                onActivated: function (conversation) {
                    root.conversationSelected(conversation);
                }
            }

            EmptyState {
                anchors.centerIn: parent
                width: parent.width - 2 * Theme.spacing.medium
                visible: convList.count === 0
                text: root.online ? qsTr("No conversations yet. Use New chat to start one, or share your address so someone can reach you.") : qsTr("Waiting for connection...")
            }
        }
    }
}
