import QtQuick
import QtQuick.Layouts

import Logos.Theme

import ChatUi

// A dev harness that renders the ChatUi panes side by side with mock data and no
// host `logos` context, doubling as a visual standalone-instantiability proof.
// Load it with the design system on the import path, e.g.
//   qml -I src/qml -I <app>/lib tests/storybook/Storybook.qml
Rectangle {
    id: story

    width: 1400
    height: 800
    color: Theme.palette.backgroundInset

    // The two catalogues, in the shape ChatBackend publishes them. Enough rows
    // to cover what the wallet views branch on: an empty holding, a blocked
    // one, a claimable one, and a holding with no way out of it.
    readonly property var assetsMock: [
        {id: "lez.private", name: "Private λ", denom: "LEZ", sourceNote: "shielded, in the zone",
         blocked: false, blockedNote: "", balance: "15",
         address: "{\"nullifier_public_key\":\"bdceb96673e2e5311fe4dd1c7fd18260df3339\"}",
         canReceive: true, canClaim: false, claimVerb: "", addressForm: 0, empty: false},
        {id: "lez.public", name: "Public λ", denom: "LEZ", sourceNote: "on the zone's public record",
         blocked: true, blockedNote: "Registering on-chain — about seven minutes.", balance: "0",
         address: "9fbbd82d31d8b1043061c3053728f14539aa3a89e55a764b671e8762e48a9bac",
         canReceive: false, canClaim: false, claimVerb: "", addressForm: 1, empty: true},
        {id: "lez.vault", name: "Vault λ", denom: "LEZ", sourceNote: "held for you, not yet yours to spend",
         blocked: false, blockedNote: "", balance: "40", address: "",
         canReceive: false, canClaim: true, claimVerb: "Claim into private", addressForm: 0,
         empty: false}
    ]
    readonly property var railsMock: [
        {id: "lez.private→private", name: "Private → private",
         promise: "The amount and both accounts stay off the public record.",
         denom: "LEZ", source: "lez.private", sourceName: "Private λ", balance: "15", payTo: 0,
         claimId: "payment.private",
         discloses: {amount: false, payer: false, payee: false, nothing: true, everything: false}},
        {id: "lez.private→public", name: "Private → public",
         promise: "Who you paid is named and the amount is public. That you were the payer is not.",
         denom: "LEZ", source: "lez.private", sourceName: "Private λ", balance: "15", payTo: 1,
         claimId: "payment.deshield",
         discloses: {amount: true, payer: false, payee: true, nothing: false, everything: false}},
        {id: "lez.public→public", name: "Public → public",
         promise: "Everything is on the public record: the amount, your account and theirs.",
         denom: "LEZ", source: "lez.public", sourceName: "Public λ", balance: "0", payTo: 1,
         claimId: "payment.public",
         discloses: {amount: true, payer: true, payee: true, nothing: false, everything: true}}
    ]
    // The slice a muster shows: a holding's own row plus why this room has it.
    readonly property var musterAssetsMock: [
        Object.assign({}, story.assetsMock[0], {why: "You paid from this here"})
    ]

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

            BackBar {
                Layout.fillWidth: true
                label: "Home"
                title: "Design Team"
                waitingCount: 2
            }
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
            MusterWalletStrip {
                Layout.fillWidth: true
                assets: story.musterAssetsMock
                ready: true
            }
        }
        WalletPane {
            Layout.fillWidth: false
            Layout.preferredWidth: 380
            Layout.fillHeight: true
            ready: true
            busy: false
            stage: ""
            statusLabel: "Ready"
            assets: story.assetsMock
            rails: story.railsMock
            receivedElsewhere: true
        }
    }
}
