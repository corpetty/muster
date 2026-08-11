import QtQuick
import QtQuick.Layouts

import Logos.Theme

import ChatUi

// A dev harness that renders the ChatUi panes side by side with mock data and no
// host `logos` context, doubling as a visual standalone-instantiability proof.
// Load it with the design system on the import path, e.g.
//   qml -I src/qml -I <app>/lib tests/storybook/Storybook.qml
Rectangle {
    width: 1000
    height: 700
    color: Theme.palette.backgroundInset

    ListModel {
        id: conversationsMock
        ListElement {
            conversationId: "c1"
            displayName: "Alice"
            isGroup: false
            avatarInitials: "c1"
            avatarRamp: 0
            unreadCount: 0
            lastActivityDisplay: "12:34"
            preview: "Sounds good, talk soon"
            description: ""
        }
        ListElement {
            conversationId: "c2"
            displayName: "Design Team"
            isGroup: true
            avatarInitials: "c2"
            avatarRamp: 3
            unreadCount: 128
            lastActivityDisplay: "Yesterday"
            preview: "Bob: pushed the fix, please review"
            description: "Design reviews and theme work"
        }
        ListElement {
            conversationId: "c3"
            displayName: "Bob"
            isGroup: false
            avatarInitials: "c3"
            avatarRamp: 1
            unreadCount: 3
            lastActivityDisplay: "Mon"
            preview: "Did you get a chance to look?"
            description: ""
        }
    }
    ListModel {
        id: messagesMock
        ListElement {
            sender: "Alice"
            avatarInitials: "al"
            avatarRamp: 0
            content: "Hey, did you see the new theme?"
            timeDisplay: "12:34"
            isMe: false
            sameSenderAsPrevious: false
            showDaySeparator: true
            dayLabel: "Today"
        }
        ListElement {
            sender: "Me"
            avatarInitials: "me"
            avatarRamp: 2
            content: "Yes, it looks great"
            timeDisplay: "12:34"
            isMe: true
            sameSenderAsPrevious: false
            showDaySeparator: false
            dayLabel: "Today"
        }
    }
    ListModel {
        id: membersMock
        ListElement {
            address: "0xalice"
            label: "Alice"
            avatarInitials: "al"
            avatarRamp: 0
            isSelf: true
            pending: false
        }
        ListElement {
            address: "0xbob"
            label: "Bob"
            avatarInitials: "bo"
            avatarRamp: 2
            isSelf: false
            pending: false
        }
        ListElement {
            address: "0xcarol"
            label: "Carol"
            avatarInitials: "ca"
            avatarRamp: 4
            isSelf: false
            pending: true
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.medium

        ColumnLayout {
            Layout.fillWidth: false
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            spacing: Theme.spacing.medium

            ConversationsPane {
                Layout.fillWidth: true
                Layout.fillHeight: true
                conversationModel: conversationsMock
                currentConversationId: "c2"
                online: true
            }
            AccountCard {
                Layout.fillWidth: true
                address: "0xdeadbeefcafe0123456789abcdef0123456789abcdef0123456789abcdef"
                label: "0xdeadbe"
                initials: "0x"
                online: true
                statusLabel: "Online"
            }
        }
        MessageThreadPane {
            Layout.fillWidth: true
            Layout.fillHeight: true
            messageModel: messagesMock
            currentIsGroup: true
            title: "Design Team"
            description: "Design reviews and theme work, with a description long enough to prove the header clamps it to one line and elides the rest"
            avatarInitials: "c2"
            avatarRamp: 3
            memberModel: membersMock
            memberCount: 3
            conversationId: "c2"
            hasConversation: true
            online: true
            ready: true
        }
        ColumnLayout {
            Layout.fillWidth: false
            Layout.preferredWidth: 280
            Layout.fillHeight: true
            spacing: Theme.spacing.medium

            DetailsPanel {
                Layout.fillWidth: true
                isGroup: true
                description: "Design reviews and theme work, with a description long enough to prove the panel wraps it"
                conversationId: "8f21c4d9a0b7e63f5c1284da7a90e3b1"
                memberCount: 3
                pendingMemberCount: 1
            }
            MembersPane {
                Layout.fillWidth: true
                Layout.fillHeight: true
                memberModel: membersMock
                memberCount: 3
                online: true
                ready: true
            }
        }
    }
}
