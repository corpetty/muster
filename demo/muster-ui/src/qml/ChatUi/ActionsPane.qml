pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The home surface: what there is to do, and who it is with.
//
// This is the app's argument in one list. People come back to do something —
// pay someone, answer a request — so the first thing they see is the doing,
// with the person as the context for it rather than the index into it. A
// conversation list would put that the other way round and make the user do
// the translation from "Bob" to "oh, Bob is waiting on my address".
//
// Rows are grouped by what they want from you: the ones waiting on *you*
// first, because those are the only ones that should pull someone back.
Rectangle {
    id: root

    // Rows from the backend, already sorted: {conversationId, displayName,
    // avatarInitials, avatarRamp, action, state, detail, lastActivityMs}.
    required property var actions
    required property string currentConversationId
    required property bool online

    signal conversationSelected(string conversationId)
    signal newActivityRequested

    readonly property int count: root.actions.length

    implicitWidth: 320
    implicitHeight: 400
    radius: Theme.spacing.radiusXlarge
    color: Theme.palette.backgroundTertiary
    border.width: 1
    border.color: Theme.palette.borderSubtle

    // How many are waiting on the user — the number worth putting in a heading.
    readonly property int needsYouCount: {
        let n = 0;
        for (let i = 0; i < root.actions.length; ++i)
            if (root.actions[i].state === "needs-you")
                n += 1;
        return n;
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.small

        // The heading answers "why am I here" before the list does.
        LogosText {
            Layout.fillWidth: true
            text: root.needsYouCount > 0
                ? qsTr("%n waiting on you", "", root.needsYouCount)
                : qsTr("Nothing waiting on you")
            color: root.needsYouCount > 0 ? Theme.palette.text : Theme.palette.textTertiary
            font.pixelSize: Theme.typography.primaryText
            font.weight: Theme.typography.weightBold
            elide: Text.ElideRight
        }

        LogosButton {
            id: newButton
            objectName: "newMenuButton"
            //: Button that starts something new with someone
            text: qsTr("Start something")
            variant: LogosButton.Variant.Primary
            radius: Theme.spacing.radiusLarge
            font.pixelSize: Theme.typography.primaryText
            leadingIcon.source: Qt.resolvedUrl("icons/plus.png")
            leadingIcon.size: 18
            leadingIcon.color: Theme.palette.backgroundBlack
            enabled: root.online
            onClicked: root.newActivityRequested()
            Layout.fillWidth: true
            Layout.preferredHeight: 40

            // The design system's label is white whatever the fill; on the
            // primary accent that is the pair with the least contrast.
            Binding {
                target: newButton.labelItem
                property: "color"
                value: newButton.enabled ? Theme.palette.backgroundBlack : Theme.palette.textMuted
            }
        }

        ListView {
            id: actionList
            objectName: "actionList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            reuseItems: true
            spacing: Theme.spacing.tiny
            model: root.actions

            ScrollBar.vertical: LogosScrollBar {}

            delegate: ActionDelegate {
                required property var modelData
                width: ListView.view.width
                conversationId: modelData.conversationId
                displayName: modelData.displayName
                avatarInitials: modelData.avatarInitials
                avatarRamp: modelData.avatarRamp
                headline: modelData.action
                rowState: modelData.state
                detail: modelData.detail
                currentConversationId: root.currentConversationId
                onActivated: function (id) {
                    root.conversationSelected(id);
                }
            }

            EmptyState {
                anchors.centerIn: parent
                width: parent.width - 2 * Theme.spacing.medium
                visible: actionList.count === 0
                text: root.online
                    ? qsTr("Nothing on yet. Start something with someone, or share your address so they can reach you.")
                    : qsTr("Waiting for connection...")
            }
        }
    }
}
