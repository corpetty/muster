import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import Logos.Theme
import Logos.Controls

// What the "+" beside the message field opens (exo-720.9, docs/design/ui-modernization.md
// §4 U5): the kinds of thing a room can agree on, one tile each, with what it does. Picking
// one opens its form in the composer panel. Each tile does what the old kind button did,
// and carries its objectName (roomKindPayment … roomKindRequest), so the UI harness's
// "+" → kind → policy → Propose path is the same.
Popup {
    id: picker
    objectName: "roomActionPicker"
    required property var room

    width: Math.min(560, parent ? parent.width : 560)
    padding: Theme.spacing.medium
    background: Surface { level: 2 }

    function pick(kind, request) {
        picker.room.splitSend = false;
        picker.room.splitRequest = request;
        picker.room.composeType = kind;
        picker.room.composing = true;
        picker.close();
    }

    // "Send money" (exo-dcc.32, .33): a split you alone pay, to one member — XMR by default,
    // any rail a split takes from the composer's "Settles on" row
    function pickSend() {
        picker.room.splitRequest = false;
        picker.room.splitSend = true;
        picker.room.composeType = "split";
        picker.room.choosePolicy("monero-split");
        picker.room.composing = true;
        picker.close();
    }
    component Tile: Rectangle {
        id: tile
        property string title: ""
        property string detail: ""
        property string glyph: ""
        property bool current: false
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: tileRow.implicitHeight + 2 * Theme.spacing.medium
        radius: Theme.spacing.radiusLarge
        color: tileHover.hovered ? Theme.palette.surfaceRaised : Theme.palette.backgroundTertiary
        border.width: 1
        border.color: tile.current || tileHover.hovered ? Theme.palette.primary : Theme.palette.borderSubtle
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: tile.title
        Keys.onReturnPressed: tile.clicked()
        RowLayout {
            id: tileRow
            anchors.fill: parent
            anchors.margins: Theme.spacing.medium
            spacing: Theme.spacing.medium
            Rectangle {
                Layout.alignment: Qt.AlignTop
                implicitWidth: 30; implicitHeight: 30
                radius: Theme.spacing.radiusLarge
                color: MusterStyle.needsSoft
                LogosIcon { anchors.centerIn: parent; width: 18; height: 18; source: MusterStyle.icon(tile.glyph); color: MusterStyle.needs }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                LogosText { textFormat: Text.PlainText; text: tile.title; color: Theme.palette.text; font.pixelSize: MusterStyle.body; font.weight: Theme.typography.weightBold }
                LogosText {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: tile.detail
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.caption
                }
            }
        }
        HoverHandler { id: tileHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: tile.clicked() }
    }

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium
        LogosText {
            textFormat: Text.PlainText
            text: qsTr("Propose something")
            color: Theme.palette.text
            font.pixelSize: MusterStyle.body
            font.weight: Theme.typography.weightBold
        }
        LogosText {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("The room sees it the moment you propose it, and nothing happens until the people it takes agree.")
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
        }
        GridLayout {
            Layout.fillWidth: true
            columns: picker.width > 440 ? 2 : 1
            rowSpacing: Theme.spacing.small
            columnSpacing: Theme.spacing.small
            Tile {
                objectName: "roomKindPayment"
                title: qsTr("Payment"); glyph: "safe"
                detail: qsTr("From an account the room shares: a Safe, a Bitcoin or LEZ multisig, a FROST group.")
                current: picker.room.composeType === "payment"
                onClicked: picker.pick("payment", false)
            }
            Tile {
                objectName: "roomKindSplit"
                title: qsTr("Split a bill"); glyph: "split"
                detail: qsTr("You paid; each person named pays you back their share from their own wallet.")
                current: picker.room.composeType === "split" && !picker.room.splitRequest && !picker.room.splitSend
                onClicked: picker.pick("split", false)
            }
            Tile {
                objectName: "roomKindRequest"
                title: qsTr("Request a payment"); glyph: "coin"
                detail: qsTr("Ask one person to pay you. On Monero, your own wallet confirms it.")
                current: picker.room.composeType === "split" && picker.room.splitRequest
                onClicked: picker.pick("split", true)
            }
            Tile {
                objectName: "roomKindSendXmr"
                title: qsTr("Send money"); glyph: "send"
                detail: qsTr("Send XMR, ETH or a token, BTC or LEZ to someone here, at an address they shared. XMR by default.")
                current: picker.room.composeType === "split" && picker.room.splitSend
                onClicked: picker.pickSend()
            }
            Tile {
                objectName: "roomKindStatement"
                title: qsTr("Statement"); glyph: "check"
                detail: qsTr("Something the room agrees to, signed by the people it names.")
                current: picker.room.composeType === "statement"
                onClicked: picker.pick("statement", false)
            }
            // a generic module action (P-D4): the room endorses it, the core invokes it
            Tile {
                objectName: "roomKindAction"
                title: qsTr("Call a module"); glyph: "code"
                detail: qsTr("A method of a module this host runs, called once the room agrees.")
                current: picker.room.composeType === "action"
                onClicked: picker.pick("action", false)
            }
        }
    }
}
