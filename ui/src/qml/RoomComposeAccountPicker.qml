import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The composer's account picker (exo-720.3, moved verbatim out of RoomComposer.qml;
// exo-a50.1.3): FROM which disclosed account an account-bound kind acts. `room` is the
// Room, as before the move.
// FROM which account (exo-a50.1.3): an account-bound kind (Safe, Attest) acts
// from an account a member disclosed into this room. One chip per account the
// kind can use; none → say so and point at the room's Accounts panel. A refused
// choice (no-account / choose-account) is shown, never silently replaced.
ColumnLayout {
    required property var room

    Layout.fillWidth: true
    spacing: Theme.spacing.tiny
    visible: room.composeType !== "action" && room.kindNeedsAccount(room.policyKind)
             || (room.policyError && room.policyError.error !== undefined)

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.small
        visible: room.kindNeedsAccount(room.policyKind)
        LogosText {
            textFormat: Text.PlainText
            text: qsTr("From")
            color: Theme.palette.textTertiary
            font.family: MusterStyle.mono
            font.pixelSize: MusterStyle.caption
        }
        Repeater {
            model: room.accountsForKind(room.policyKind)
            delegate: ActionButton {
                required property var modelData
                objectName: "roomAccount_" + String(modelData.id)
                Layout.preferredWidth: 170
                text: modelData.label ? String(modelData.label)
                      : String(modelData.address).slice(0, 8) + "…" + String(modelData.address).slice(-4)
                variant: room.policyAccount === String(modelData.id)
                         ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                onClicked: if (room.backend) room.backend.setPolicy(room.policyKind + "@" + String(modelData.id))
            }
        }
        Item { Layout.fillWidth: true }
    }
    LogosText {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: room.policyError && room.policyError.error !== undefined
        text: {
            var e = room.policyError || {};
            if (e.error === "no-account")
                return qsTr("No one has disclosed an account this can act from. Disclose one under Accounts, beside the room.");
            if (e.error === "choose-account")
                return qsTr("Several accounts are disclosed. Choose which one this acts from.");
            // a split settles on the chain YOUR node serves, read — never assumed (exo-a90)
            var words = room.chainErrorWords(String(e.error || ""), e.detail);
            if (words.length > 0) return words;
            return e.error ? String(e.error) : "";
        }
        color: Theme.palette.warning
        font.pixelSize: MusterStyle.caption
        wrapMode: Text.WordWrap
    }
}
