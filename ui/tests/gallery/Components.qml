import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls
import Logos.Icons
import "../../src/qml"

// U1's components, each in its states (exo-720.5): the page the gallery's `components`
// fixture shoots. Not shipped.
Rectangle {
    color: Theme.palette.background

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.xlarge
        spacing: Theme.spacing.large

        SectionHeader { text: "Avatar · from the member's id, lettered by your alias"; count: "8" }
        Row {
            spacing: Theme.spacing.small
            Repeater {
                model: [["cd3930fe", "Alice"], ["34bd8ae3", "Bob"], ["19bde4f7", ""], ["5e10be72", "Ana"],
                        ["c7710a19", "Mira"], ["8a02c3d1", "Devon"], ["f61c2b80", "sol"], ["0d4e77a2", "Carol"]]
                delegate: Avatar { required property var modelData; identity: modelData[0]; name: modelData[1] }
            }
            Avatar { identity: "/muster/1/muster.room.6ac8/proto"; name: "Dinner at Ana's"; room: true }
            Avatar { identity: "cd3930fe"; name: "Alice"; size: 22 }
            Avatar { identity: "34bd8ae3"; name: "Bob"; size: 36 }
        }

        SectionHeader { text: "StatusPill · the tone carries the colour" }
        Row {
            spacing: Theme.spacing.small
            StatusPill { text: "Needs you"; tone: "needs" }
            StatusPill { text: "2 of 3 agreed"; tone: "waiting" }
            StatusPill { text: "Final"; tone: "settled" }
            StatusPill { text: "Blocked"; tone: "refused" }
            StatusPill { text: "3 of 3 confirmations"; tone: "info" }
            StatusPill { text: "seen, 4 of 10"; tone: "warning" }
        }

        SectionHeader { text: "Waits on you"; hot: true; count: "2"
            LogosText { text: "Invite"; color: Theme.palette.primary; font.pixelSize: MusterStyle.caption } }

        SectionHeader { text: "Surface · page, card, popover; out of the room; waits on you" }
        Row {
            spacing: Theme.spacing.medium
            Surface { level: 0; width: 140; height: 64; LogosText { anchors.centerIn: parent; text: "level 0"; color: Theme.palette.textSecondary } }
            Surface { level: 1; width: 140; height: 64; LogosText { anchors.centerIn: parent; text: "level 1"; color: Theme.palette.textSecondary } }
            Surface { level: 2; width: 140; height: 64; LogosText { anchors.centerIn: parent; text: "level 2"; color: Theme.palette.textSecondary } }
            Surface { tone: "out"; width: 140; height: 64; LogosText { anchors.centerIn: parent; text: "left the room"; color: Theme.palette.textSecondary } }
            Surface { tone: "needs"; width: 140; height: 64; LogosText { anchors.centerIn: parent; text: "needs you"; color: Theme.palette.textSecondary } }
        }

        SectionHeader { text: "IconAction · every one labelled (hover shows it)" }
        Row {
            spacing: Theme.spacing.tiny
            IconAction { label: "Room details"; icon: MusterStyle.icon("details-panel") }
            IconAction { label: "Room details (open)"; icon: MusterStyle.icon("details-panel"); checked: true }
            IconAction { label: "More"; icon: LogosIcons.more }
            IconAction { label: "Collapse the sidebar"; icon: MusterStyle.icon("sidebar") }
            IconAction { label: "Propose something"; icon: MusterStyle.icon("plus") }
            IconAction { label: "Send"; icon: MusterStyle.icon("send") }
            Repeater {
                model: ["inbox", "wallet", "people", "book", "gear", "split", "coin", "safe", "bitcoin", "lez", "shield", "lock", "eye", "key", "link", "clock", "info", "check"]
                delegate: IconAction { required property string modelData; label: modelData; icon: MusterStyle.icon(modelData); size: 28 }
            }
        }

        SectionHeader { text: "ActionButton · sized to its words; one Primary per view" }
        Row {
            spacing: Theme.spacing.small
            ActionButton { text: "Agree to my share"; variant: LogosButton.Variant.Primary }
            ActionButton { text: "Invite"; icon.source: MusterStyle.icon("link") }
            ActionButton { text: "Details"; quiet: true }
            ActionButton { text: "Review"; compact: true; variant: LogosButton.Variant.Primary }
            ActionButton { text: "Not now"; compact: true; quiet: true }
            ActionButton { text: "Propose"; enabled: false }
        }

        SectionHeader { text: "InlineNotice · the outcome, the cause, the remedy" }
        InlineNotice {
            Layout.fillWidth: true
            tone: "error"; title: "Nothing was proposed."
            text: "No Ethereum RPC answers for Sepolia, so your client can't build what everyone would sign. Your entries are kept."
            ActionButton { text: "Open Settings" }
        }
        InlineNotice {
            Layout.fillWidth: true
            tone: "info"; title: "Carol asks to join"
            text: "Admitting re-keys the room forward: Carol reads from here on, never the messages above."
            ActionButton { text: "Admit"; variant: LogosButton.Variant.Primary }
            ActionButton { text: "Not now"; quiet: true }
        }
        InlineNotice {
            Layout.fillWidth: true
            tone: "warning"
            text: "Your Ethereum RPC for Sepolia isn't answering. Safe proposals here can't be checked against the chain until it does."
        }

        SectionHeader { text: "EmptyState · and Toast" }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.large
            EmptyState {
                Layout.preferredWidth: 420
                text: "Nothing waits on you. Start something with someone."
                ActionButton { text: "Start something"; variant: LogosButton.Variant.Primary }
            }
            RowLayout {
                spacing: Theme.spacing.small
                LogosText { text: "Only the people in the room can read it."; color: Theme.palette.textTertiary; font.pixelSize: MusterStyle.caption }
                WhyLink { step: "open-room" }
            }
            Loading {}
            Toast { id: toast; Component.onCompleted: { toast.duration = 600000; toast.show("Agreed — your room key signed it") } }
        }

        SectionHeader { text: "CardVoiceNote · complete, playing, arriving, broken (voice-notes.md §7)" }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.large
            CardVoiceNote { Layout.fillWidth: false; Layout.preferredWidth: 300; rowId: "c"; authorName: "Alice"
                voice: ({ v: 1, note: "c", durationMs: 7000, state: "complete" }) }
            CardVoiceNote { Layout.fillWidth: false; Layout.preferredWidth: 300; rowId: "p"; authorName: "you"; playing: true; positionMs: 3000
                voice: ({ v: 1, note: "p", durationMs: 7000, state: "complete" }) }
            CardVoiceNote { Layout.fillWidth: false; Layout.preferredWidth: 300; rowId: "a"; authorName: "Bob"
                voice: ({ v: 1, note: "a", durationMs: 42000, state: "arriving" }) }
            CardVoiceNote { Layout.fillWidth: false; Layout.preferredWidth: 300; rowId: "b"; authorName: "Bob"
                voice: ({ v: 1, note: "b", durationMs: 3000, state: "broken" }) }
        }
        Item { Layout.fillHeight: true }
    }
}
