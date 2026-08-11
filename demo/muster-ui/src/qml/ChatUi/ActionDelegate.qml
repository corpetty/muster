import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// One row of the home surface: what there is to do, then who it is with.
//
// The action is the headline and the name is beneath it, which is the whole
// reordering this app is arguing for. A row that led with "Bob" would make the
// reader translate a name into a task; this way the task is already there and
// the name tells them whose it is.
LogosItemDelegate {
    id: root

    required property string conversationId
    required property string displayName
    required property string avatarInitials
    required property int avatarRamp
    // The headline: "They need an address", "Ready to pay", "Paid".
    // Not `action`: that is a final member of the button base type.
    required property string headline
    // needs-you | waiting | settled | idle.
    // Not `state`: QQuickItem already has one, and shadowing it would break
    // the component silently at load.
    required property string rowState
    // The second line: why this row is in the state it is.
    required property string detail
    property string currentConversationId: ""

    signal activated(string conversationId)

    readonly property bool needsYou: root.rowState === "needs-you"

    // The colour carries the state so the list can be read at a glance without
    // anyone parsing the words: green means done, the accent means it wants
    // you, muted means it is someone else's turn.
    readonly property color stateColor: root.rowState === "needs-you" ? ChatTheme.signal
        : root.rowState === "settled" ? ChatTheme.settled
        : Theme.palette.textTertiary

    width: 200
    implicitHeight: 64
    radius: Theme.spacing.radiusMedium
    leftPadding: Theme.spacing.small
    rightPadding: Theme.spacing.small
    highlighted: root.conversationId === root.currentConversationId
    highlightColor: Theme.palette.surfaceRaised

    Accessible.role: Accessible.ListItem
    Accessible.name: qsTr("%1, with %2").arg(root.headline).arg(root.displayName)
    Accessible.selected: root.highlighted

    onClicked: root.activated(root.conversationId)

    contentItem: RowLayout {
        spacing: Theme.spacing.small

        // A bar rather than a dot: it reads as a state band down the list, and
        // gives the eye a column to scan instead of five separate marks.
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 3
            Layout.preferredHeight: 34
            radius: 1.5
            color: root.stateColor
            opacity: root.rowState === "idle" ? 0.4 : 1.0
        }

        Avatar {
            initials: root.avatarInitials
            ramp: root.avatarRamp
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            LogosText {
                objectName: "actionLabel"
                text: root.headline
                textFormat: Text.PlainText
                color: Theme.palette.text
                // A row waiting on you leans on weight, not colour, so the list
                // still reads as one column.
                font.weight: root.needsYou ? Theme.typography.weightBold
                                           : Theme.typography.weightMedium
                font.pixelSize: Theme.typography.primaryText
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // Who it is with, and why it is in this state — the context for the
            // headline rather than the headline itself.
            LogosText {
                text: root.detail !== ""
                    ? qsTr("%1 · %2").arg(root.displayName).arg(root.detail)
                    : root.displayName
                textFormat: Text.PlainText
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }
}
