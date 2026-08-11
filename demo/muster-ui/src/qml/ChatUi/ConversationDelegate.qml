import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A conversation row: an avatar, the name, a preview, a relative last-activity
// label and an unread-count badge. Delegate roles bind by name; set
// currentConversationId and connect activated(). Focus ring when
// keyboard-focused, highlight when current.
LogosItemDelegate {
    id: root

    required property string conversationId
    required property string displayName
    required property bool isGroup
    // Avatar identity, computed by the model from the conversation id.
    required property string avatarInitials
    required property int avatarRamp
    required property int unreadCount
    // Relative last-activity label, formatted by the model.
    required property string lastActivityDisplay
    // Truncated last-message content shown under the name.
    required property string preview
    // The group's shared description, carried so a selection can be rendered
    // from the row itself.
    required property string description
    // The open conversation, so this row highlights when it is the current one.
    property string currentConversationId: ""

    // Carries the row's own data, so a view can render the selection before the
    // backend has switched to it.
    signal activated(var conversation)

    // What this row is, as one value: everything a view needs to draw it as the
    // open conversation.
    readonly property var conversation: ({
            conversationId: root.conversationId,
            displayName: root.displayName,
            description: root.description,
            isGroup: root.isGroup,
            avatarInitials: root.avatarInitials,
            avatarRamp: root.avatarRamp
        })

    readonly property bool unread: root.unreadCount > 0

    // True while this is the ListView's current item and the list has focus.
    readonly property bool keyboardFocused: ListView.isCurrentItem && ListView.view && ListView.view.activeFocus

    width: 200
    implicitHeight: 68
    radius: Theme.spacing.radiusMedium
    leftPadding: Theme.spacing.small
    rightPadding: Theme.spacing.small
    highlighted: conversationId === currentConversationId
    // A raised surface rather than a tint: the row sits on a card, and a
    // translucent highlight would read as the card showing through.
    highlightColor: Theme.palette.surfaceRaised

    Accessible.role: Accessible.ListItem
    Accessible.name: {
        const base = isGroup ? qsTr("Group %1").arg(displayName) : displayName;
        return unreadCount > 0 ? qsTr("%1, %2 unread").arg(base).arg(unreadCount) : base;
    }
    Accessible.selected: highlighted

    onClicked: root.activated(root.conversation)

    contentItem: RowLayout {
        spacing: Theme.spacing.small

        Avatar {
            initials: root.avatarInitials
            ramp: root.avatarRamp
            isGroup: root.isGroup
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            LogosText {
                text: root.displayName
                textFormat: Text.PlainText
                color: Theme.palette.text
                font.pixelSize: Theme.typography.primaryText
                // An unread row leans on weight rather than on colour, so the
                // list still reads as one column of names.
                font.weight: root.unread ? Theme.typography.weightBold : Theme.typography.weightMedium
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            LogosText {
                objectName: "previewLabel"
                //: Placeholder in a conversation row that has no messages yet
                text: root.preview !== "" ? root.preview : qsTr("No messages yet")
                textFormat: Text.PlainText
                color: root.unread ? Theme.palette.textSecondary : Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                font.italic: root.preview === ""
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        // The row's standing facts, stacked so neither pushes the name around.
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            Layout.minimumWidth: 40
            spacing: Theme.spacing.tiny

            LogosText {
                text: root.lastActivityDisplay
                color: root.unread ? ChatTheme.signal : Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
                Layout.alignment: Qt.AlignRight
            }

            // Unread badge: a pill that widens for multi-digit counts, holding
            // its slot when there are none so the timestamps stay in line.
            Rectangle {
                implicitWidth: root.unread ? Math.max(20, badgeText.implicitWidth + 2 * Theme.spacing.small) : 0
                implicitHeight: 20
                radius: height / 2
                color: root.unread ? ChatTheme.signal : "transparent"
                Layout.alignment: Qt.AlignRight

                LogosText {
                    id: badgeText
                    anchors.centerIn: parent
                    visible: root.unread
                    text: root.unreadCount
                    // Dark ink for legible contrast on the light signal fill; the
                    // white text token drops below the readable ratio there.
                    color: Theme.palette.backgroundBlack
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightBold
                }
            }
        }
    }

    // The open conversation's marker, on the row's leading edge so a glance down
    // the list finds it without reading any text.
    Rectangle {
        visible: root.highlighted
        x: 0
        y: Theme.spacing.large
        width: 3
        height: root.height - 2 * Theme.spacing.large
        radius: width / 2
        color: ChatTheme.signal
    }

    // Keyboard focus ring, drawn over the row without disturbing its background.
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        visible: root.keyboardFocused
        border.width: 1
        border.color: Theme.palette.focus
    }
}
