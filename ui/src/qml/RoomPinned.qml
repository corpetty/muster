import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The live proposal, pinned under the header (exo-720.7, FURPS U-3): its state and what it
// does, with a jump to its card. What waits on YOU comes first — the module classes it
// (coordinate_conversations' `needs`, F-18) — else the latest proposal still under way.
// Nothing is pinned when nothing is under way.
Rectangle {
    id: pinned
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    readonly property var live: room.liveProposal
    visible: room.joined && live !== null
    Layout.fillWidth: true
    implicitHeight: visible ? 44 : 0
    color: live && live.needsYou ? MusterStyle.tint(MusterStyle.needs, 0.09) : Theme.palette.backgroundTertiary

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width; height: 1
        color: pinned.live && pinned.live.needsYou ? MusterStyle.tint(MusterStyle.needs, 0.25) : Theme.palette.borderSubtle
    }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacing.xlarge
        anchors.rightMargin: Theme.spacing.medium
        spacing: Theme.spacing.medium
        StatusPill {
            objectName: "roomPinnedState"
            text: pinned.live ? pinned.live.label : ""
            tone: pinned.live && pinned.live.needsYou ? "needs" : "waiting"
        }
        LogosText {
            textFormat: Text.PlainText
            objectName: "roomPinnedText"
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: pinned.live ? pinned.live.text : ""
            color: Theme.palette.text
            font.pixelSize: MusterStyle.body
        }
        ActionButton {
            objectName: "roomPinnedReview"
            compact: true
            text: qsTr("Review")
            variant: pinned.live && pinned.live.needsYou ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
            onClicked: pinned.room.jumpRequested(pinned.live.id)
        }
    }
}
